import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cht/chat/cache_policy.dart';
import 'package:cht/chat/chat_attachment.dart';
import 'package:cht/courier/courier_journal.dart';
import 'package:cht/courier/courier_models.dart';
import 'package:cht/courier/courier_receiver.dart';
import 'package:cht/courier/courier_service.dart';
import 'package:cht/courier/courier_store.dart';
import 'package:cht/delivery/delivery_envelope.dart';
import 'package:flutter_test/flutter_test.dart';

import '../delivery/delivery_envelope_test.dart' as e;
import '../support/memory_chunk_cache.dart';
import 'courier_journal_test.dart' show Disk;

class Crypto extends e.Crypto {
  late Map<String, Object?> opened;
  int receipts = 0;
  @override
  Future<Map<String, Object?>> deliveryCall(
    String op,
    Map<String, Object?> args,
  ) async {
    if (op == 'openManifest') return opened;
    if (op == 'decryptPackage') {
      final bytes = base64Url.decode(
        base64Url.normalize(args['ciphertext'] as String),
      );
      return {
        'plaintext': base64UrlEncode(bytes.sublist(40)).replaceAll('=', ''),
      };
    }
    if (op == 'signControl') {
      receipts++;
      return {
        'kind': 'receipt',
        'body': args['body'],
        'challenge': args['challenge'],
        'signature': 'valid',
      };
    }
    return super.deliveryCall(op, args);
  }
}

class Service implements CourierService {
  final pieces = <int, Uint8List>{}, reads = <int>[];
  int? failIndex;
  @override
  Future<CourierStoredPackage> readPackage(
    CourierNode node,
    Map<String, Object?> item, {
    required int bucket,
    required int index,
  }) async {
    reads.add(index);
    if (failIndex == index) {
      failIndex = null;
      throw StateError('Disconnected');
    }
    return CourierStoredPackage(pieces[index]!, {
      'proof': ['e' * 64],
    });
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FailLoadDisk extends Disk {
  bool fail = true;
  @override
  Future<String?> loadGroupBlob(String owner, String key) async {
    if (fail) {
      fail = false;
      throw StateError('Temporary storage failure');
    }
    return super.loadGroupBlob(owner, key);
  }
}

Future<({DeliveryEnvelope envelope, List<CourierOffer> offers, Uint8List file})>
fixture(Crypto crypto, Service service, {int size = 700000}) async {
  final file = Uint8List.fromList(List.generate(size, (i) => i % 251));
  final envelope = await DeliveryEnvelope.create(
    crypto,
    scope: 'direct:test',
    messageId: 'original',
    sentAt: 1000,
    kind: size == 0 ? 'text' : 'file',
    payload: {
      'text': 'caption',
      if (size > 0)
        'file': {
          'name': 'private.bin',
          'mime': 'application/octet-stream',
          'size': size,
          'digest': sha256.convert(file).toString(),
        },
    },
  );
  final payload = CourierPayload(
        envelope,
        file: size == 0
            ? null
            : ChatAttachment.fromOwnedBytes(
                name: 'private.bin',
                mimeType: 'application/octet-stream',
                bytes: file,
              ),
      ),
      parts = await payload.packages().toList(),
      all = BytesBuilder(copy: false);
  for (var i = 0; i < parts.length; i++) {
    service.pieces[i] = Uint8List.fromList([
      ...List.filled(40, 7),
      ...parts[i],
    ]);
    all.add(parts[i]);
  }
  crypto.opened = {
    'state': 'opaque-protected-state',
    'event': envelope.event,
    'metadata': {
      'size': payload.size,
      'contentHash': sha256.convert(all.takeBytes()).toString(),
    },
    'jobId': 'a' * 32,
    'count': parts.length,
    'manifestHash': 'd' * 64,
    'receiptChallenge': 'A' * 43,
    'bucket': 0,
    'merkleRoot': 'e' * 64,
  };
  final offers = [
    for (var n = 0; n < 2; n++)
      CourierOffer(
        CourierNode.verified(
          nodeId: (n == 0 ? 'b' : 'c') * 64,
          ownerId: 'did:cht:${(n == 0 ? 'e' : 'f') * 64}',
          certificate: {},
          routes: ['wss://relay.example.com/cht'],
          expiresAt: 86402000,
          freeBytes: 1073741824,
        ),
        {
          'jobId': 'a' * 32,
          'manifestHash': 'd' * 64,
          'expiresAt': 86402000,
          'manifest': {},
          'available':
              (IndexBitmap(parts.length)..merge(
                    IndexBitmap.fromEncoded(
                      parts.length,
                      base64UrlEncode(
                        Uint8List.fromList([
                          for (
                            var byte = 0;
                            byte < (parts.length + 7) ~/ 8;
                            byte++
                          )
                            [
                              for (var bit = 0; bit < 8; bit++)
                                if (byte * 8 + bit < parts.length &&
                                    (byte * 8 + bit) % 2 == n)
                                  1 << bit,
                            ].fold<int>(0, (a, b) => a | b),
                        ]),
                      ).replaceAll('=', ''),
                    ),
                  ))
                  .encoded,
          'count': parts.length,
          'root': 'e' * 64,
          'from': envelope.authorId,
          'jobKey': '1' * 64,
        },
      ),
  ];
  return (envelope: envelope, offers: offers, file: file);
}

void main() {
  test(
    'a Courier file offer reads zero packages until it is accepted',
    () async {
      final crypto = Crypto(), service = Service();
      final offer = await fixture(crypto, service, size: 17);
      (crypto.opened['metadata'] as Map)['offerHeader'] =
          offer.envelope.payloadSource;
      final budget = CachePolicy(
        ownerId: 'owner',
        settings: Disk(),
        availableSpace: () async => null,
      );
      await budget.initialize();
      var accepted = false, sawOffer = false;
      CourierReceived? committed;
      final cache = MemoryChunkCache();
      final receiver = CourierReceiver(
        ownerId: 'owner',
        crypto: crypto,
        service: service,
        journal: CourierJournal(
          ownerId: 'owner',
          namespace: 'courier_inbox',
          storage: Disk(),
        ),
        cache: cache,
        budget: budget,
        clock: () => 2000,
        authorize: (envelope) async {
          if (envelope.payload['file'] == null) return true;
          sawOffer = true;
          return accepted;
        },
        isDeleted: (_) => false,
        existingReceivedAt: (_) async => committed?.receivedAt,
        commit: (value) async => committed = value,
      );
      expect(await receiver.receive(offer.offers), isNull);
      expect(sawOffer, isTrue);
      expect(service.reads, isEmpty);
      expect(committed, isNull);
      accepted = true;
      expect(await receiver.receive(offer.offers), isNotNull);
      expect(service.reads, isNotEmpty);
      expect(committed?.attachment?.size, offer.file.length);
      budget.dispose();
    },
  );

  test('a concurrent live commit retains its durable receive time in the Courier receipt', () async {
    final crypto = Crypto(),
        service = Service(),
        f = await fixture(crypto, service, size: 0),
        budget = CachePolicy(
          ownerId: 'owner',
          settings: Disk(),
          availableSpace: () async => null,
        );
    await budget.initialize();
    int? received;
    final receiver = CourierReceiver(
      ownerId: 'owner',
      crypto: crypto,
      service: service,
      journal: CourierJournal(
        ownerId: 'owner',
        namespace: 'courier_inbox',
        storage: Disk(),
      ),
      cache: null,
      budget: budget,
      clock: () => 2000,
      authorize: (_) async => true,
      isDeleted: (_) => false,
      existingReceivedAt: (_) async => received,
      commit: (_) async {
        received = 1500;
      },
    );
    final proof = await receiver.receive(f.offers);
    expect((proof!['body'] as Map)['receivedAt'], 1500);
    receiver.close();
    budget.dispose();
  });
  test('confirmed group copies discard their temporary chunk cache while direct history attachments remain', () async {
    for (final referenced in [false, true]) {
      final crypto = Crypto(),
          service = Service(),
          f = await fixture(crypto, service),
          cache = MemoryChunkCache(),
          budget = CachePolicy(
            ownerId: 'owner',
            settings: Disk(),
            availableSpace: () async => null,
          );
      await budget.initialize();
      final receiver = CourierReceiver(
        ownerId: 'owner',
        crypto: crypto,
        service: service,
        journal: CourierJournal(
          ownerId: 'owner',
          namespace: 'courier_inbox',
          storage: Disk(),
        ),
        cache: cache,
        budget: budget,
        clock: () => 2000,
        authorize: (_) async => true,
        isDeleted: (_) => false,
        existingReceivedAt: (_) async => null,
        referencesFile: (_) => referenced,
        commit: (_) async {},
      );
      await receiver.receive(f.offers);
      expect(cache.entries, hasLength(1));
      await receiver.confirmed(f.offers.first.item);
      expect(cache.entries.length, referenced ? 1 : 0);
      receiver.close();
      budget.dispose();
    }
  });
  test('a temporary inbox load failure can retry without replacing the unlocked account', () async {
    final crypto = Crypto(),
        service = Service(),
        f = await fixture(crypto, service, size: 0),
        budget = CachePolicy(
          ownerId: 'owner',
          settings: Disk(),
          availableSpace: () async => null,
        );
    await budget.initialize();
    final receiver = CourierReceiver(
      ownerId: 'owner',
      crypto: crypto,
      service: service,
      journal: CourierJournal(
        ownerId: 'owner',
        namespace: 'courier_inbox',
        storage: FailLoadDisk(),
      ),
      cache: MemoryChunkCache(),
      budget: budget,
      clock: () => 2000,
      authorize: (_) async => true,
      isDeleted: (_) => false,
      existingReceivedAt: (_) async => null,
      commit: (_) async {},
    );
    await expectLater(receiver.receive(f.offers), throwsStateError);
    expect(await receiver.receive(f.offers), isNotNull);
    expect(crypto.receipts, 1);
    receiver.close();
    budget.dispose();
  });
  test('failed abandoned staging cleanup keeps its metadata and quota until deletion succeeds', () async {
    var time = 2000;
    final crypto = Crypto(),
        service = Service(),
        f = await fixture(crypto, service),
        budget = CachePolicy(
          ownerId: 'owner',
          settings: Disk(),
          availableSpace: () async => null,
        ),
        cache = MemoryChunkCache();
    await budget.initialize();
    final receiver = CourierReceiver(
      ownerId: 'owner',
      crypto: crypto,
      service: service,
      journal: CourierJournal(
        ownerId: 'owner',
        namespace: 'courier_inbox',
        storage: Disk(),
      ),
      cache: cache,
      budget: budget,
      clock: () => time,
      authorize: (_) async => true,
      isDeleted: (_) => false,
      existingReceivedAt: (_) async => null,
      referencesFile: (_) => false,
      commit: (_) async {
        fail('Not complete');
      },
    );
    service.failIndex = 2;
    await expectLater(receiver.receive(f.offers), throwsStateError);
    expect(cache.entries, hasLength(1));
    time = 86402001;
    cache.failDelete = true;
    await expectLater(receiver.expire(), throwsStateError);
    expect(budget.reservedBytes, greaterThan(0));
    cache.failDelete = false;
    await receiver.expire();
    expect(cache.entries, isEmpty);
    expect(budget.reservedBytes, 0);
    receiver.close();
    budget.dispose();
  });
  test('file pickup resumes from durable chunks, commits before receipt and never changes the original receive time', () async {
    final crypto = Crypto(),
        service = Service(),
        f = await fixture(crypto, service),
        disk = Disk(),
        cache = MemoryChunkCache(),
        budget = CachePolicy(
          ownerId: 'owner',
          settings: Disk(),
          availableSpace: () async => null,
        );
    await budget.initialize();
    var durable = false, commits = 0;
    int? received;
    CourierReceiver create() => CourierReceiver(
      ownerId: 'owner',
      crypto: crypto,
      service: service,
      journal: CourierJournal(
        ownerId: 'owner',
        namespace: 'courier_inbox',
        storage: disk,
      ),
      cache: cache,
      budget: budget,
      clock: () => 2000,
      authorize: (_) async => true,
      isDeleted: (_) => false,
      existingReceivedAt: (_) async => received,
      commit: (message) async {
        expect(crypto.receipts, 0);
        commits++;
        durable = true;
        received = message.receivedAt;
        expect(message.attachment!.size, f.file.length);
      },
    );
    final first = create();
    service.failIndex = 2;
    await expectLater(first.receive(f.offers), throwsStateError);
    expect(crypto.receipts, 0);
    expect(cache.writes, 1);
    first.close();
    service.reads.clear();
    final next = create();
    final receipt = await next.receive(f.offers);
    expect(durable, isTrue);
    expect(receipt, isNotNull);
    expect(service.reads.first, 1);
    expect(commits, 1);
    expect(received, 2000);
    await next.receive(f.offers);
    expect(commits, 1);
    expect(received, 2000);
    next.close();
    budget.dispose();
  });
  test('whole payload corruption and deleted or unauthorized scopes never issue delivery receipts', () async {
    for (final reason in ['hash', 'deleted', 'membership']) {
      final crypto = Crypto(),
          service = Service(),
          f = await fixture(crypto, service, size: 0),
          budget = CachePolicy(
            ownerId: 'owner',
            settings: Disk(),
            availableSpace: () async => null,
          );
      await budget.initialize();
      if (reason == 'hash') {
        (crypto.opened['metadata'] as Map)['contentHash'] = 'f' * 64;
      }
      final receiver = CourierReceiver(
        ownerId: 'owner',
        crypto: crypto,
        service: service,
        journal: CourierJournal(
          ownerId: 'owner',
          namespace: 'courier_inbox',
          storage: Disk(),
        ),
        cache: MemoryChunkCache(),
        budget: budget,
        clock: () => 2000,
        authorize: (_) async => reason != 'membership',
        isDeleted: (_) => reason == 'deleted',
        existingReceivedAt: (_) async => null,
        commit: (_) async {
          fail('Must not commit');
        },
      );
      if (reason == 'hash') {
        await expectLater(receiver.receive(f.offers), throwsFormatException);
      } else {
        expect(await receiver.receive(f.offers), isNull);
      }
      expect(crypto.receipts, 0);
      receiver.close();
      budget.dispose();
    }
  });
}
