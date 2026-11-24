import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cht/chat/cache_policy.dart';
import 'package:cht/courier/courier_journal.dart';
import 'package:cht/courier/courier_policy.dart';
import 'package:cht/courier/courier_store.dart';
import 'package:cht/courier/sender_jobs.dart';
import 'package:cht/delivery/delivery_crypto_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

import 'courier_journal_test.dart' show Disk;

const now = 1800000000000, day = 86400000;
final sender = 'did:cht:${'a' * 64}',
    receiver = 'did:cht:${'b' * 64}',
    nodeId = 'c' * 64;
final senderPublic = base64UrlEncode(List.filled(32, 1)).replaceAll('=', ''),
    receiverPublic = base64UrlEncode(List.filled(32, 2)).replaceAll('=', '');
String mailbox(String public, int bucket) => sha256
    .convert(
      utf8.encode(
        'chta courier mailbox v1\u0000${jsonEncode([public, bucket])}',
      ),
    )
    .toString();
final tag = mailbox(receiverPublic, now ~/ day);
final cipher = Uint8List.fromList(List.filled(43, 7));

class Crypto implements DeliveryCryptoBridge {
  @override
  Future<Map<String, Object?>> deliveryCall(
    String op,
    Map<String, Object?> args,
  ) async {
    if (op == 'inspectManifest') {
      final m = Map<String, Object?>.from(args['manifest'] as Map);
      return {
        'manifestHash': 'd' * 64,
        'jobId': m['jobId'],
        'mailbox': m['mailbox'],
        'expiresAt': m['expiresAt'],
      };
    }
    if (op == 'verifyPackage') {
      final bytes = base64Url.decode(
        base64Url.normalize(args['ciphertext'] as String),
      );
      if (CourierSenderJobs.packageHash(args['index'] as int, bytes) !=
          args['hash']) {
        throw StateError('bad hash');
      }
      return {'bytes': bytes.length};
    }
    final c = Map<String, Object?>.from(args['control'] as Map);
    if (op != 'verifyControl' ||
        c['signature'] != 'valid' ||
        c['signerId'] != args['expectedSigner'] ||
        c['challenge'] != args['challenge']) {
      throw StateError('bad signature');
    }
    return c;
  }
}

Map<String, Object?> offer({
  String? id,
  int index = 0,
  int count = 2,
  int? expires,
}) => {
  'kind': 'store',
  'signerId': sender,
  'publicKey': senderPublic,
  'signature': 'valid',
  'challenge': 'test-challenge',
  'body': {
    'nodeId': nodeId,
    'jobId': id ?? '1' * 32,
    'mailbox': tag,
    'bucket': now ~/ day,
    'count': count,
    'index': index,
    'cipherBytes': cipher.length,
    'hash': CourierSenderJobs.packageHash(index, cipher),
    'root': 'e' * 64,
    'proof': ['f' * 64],
    'manifestHash': 'd' * 64,
    'manifest': {
      'version': 1,
      'jobId': id ?? '1' * 32,
      'mailbox': tag,
      'expiresAt': expires ?? now + day,
      'box': 'A' * 128,
    },
    'expiresAt': expires ?? now + day,
    'allocationRevision': 1,
  },
};
Map<String, Object?> pickup({
  required String action,
  String? jobKey,
  int? index,
}) => {
  'kind': 'pickup',
  'signerId': receiver,
  'publicKey': receiverPublic,
  'signature': 'valid',
  'challenge': 'pickup-challenge',
  'body': {
    'mailbox': tag,
    'bucket': now ~/ day,
    'action': action,
    'jobKey': ?jobKey,
    'index': ?index,
  },
};
void main() {
  test('receipt pagination and authenticated sender acknowledgement free carrier capacity', () async {
    final budget = CachePolicy(
      ownerId: 'owner',
      settings: Disk(),
      availableSpace: () async => null,
    );
    await budget.initialize();
    final store = CourierStore(
      nodeId: nodeId,
      journal: CourierJournal(
        ownerId: 'owner',
        namespace: 'courier_host',
        storage: Disk(),
      ),
      crypto: Crypto(),
      budget: budget,
      clock: () => now,
    );
    await store.initialize();
    for (final id in ['1' * 32, '2' * 32]) {
      final lease = await store.acceptOffer(
        from: sender,
        control: offer(id: id),
        challenge: 'test-challenge',
      );
      await store.writePart(lease.id!, sender, 0, cipher);
      await store.commitPackage(lease.id!);
      await store.recordReceipt(
        from: receiver,
        control: {
          'kind': 'receipt',
          'signerId': receiver,
          'publicKey': receiverPublic,
          'signature': 'valid',
          'challenge': 'receipt',
          'body': {
            'jobId': id,
            'messageId': id,
            'manifestHash': 'd' * 64,
            'receivedAt': now,
          },
        },
        challenge: 'receipt',
      );
    }
    Map<String, Object?> query(String action, {int cursor = 0}) => {
      'kind': 'pickup',
      'signerId': sender,
      'publicKey': senderPublic,
      'signature': 'valid',
      'challenge': 'pickup',
      'body': {
        'action': action,
        'mailbox': mailbox(senderPublic, now ~/ day),
        'bucket': now ~/ day,
        'cursor': cursor,
      },
    };
    final page = await store.listReceipts(
      from: sender,
      control: query('receipts', cursor: 1),
      challenge: 'pickup',
    );
    expect(page, hasLength(1));
    final control = query('receipt-ack');
    final acknowledgement = control['body'] as Map;
    acknowledgement['jobId'] = (page.single['body'] as Map)['jobId'];
    acknowledgement['manifestHash'] = 'd' * 64;
    acknowledgement['recipientId'] = receiver;
    await expectLater(
      store.acknowledgeReceipt(
        from: receiver,
        control: control,
        challenge: 'pickup',
      ),
      throwsStateError,
    );
    final before = store.reservedBytes;
    await store.acknowledgeReceipt(
      from: sender,
      control: control,
      challenge: 'pickup',
    );
    expect(store.reservedBytes, lessThan(before));
    expect(
      await store.listReceipts(
        from: sender,
        control: query('receipts'),
        challenge: 'pickup',
      ),
      hasLength(1),
    );
    store.close();
    budget.dispose();
  });
  test(
    'per-root bytes and job counts cannot be bypassed using another job ID',
    () async {
      final cost =
          CourierPolicy.metadataBytes +
          CourierPolicy.packageCost(cipher.length);
      for (final byteBound in [true, false]) {
        final budget = CachePolicy(
          ownerId: 'owner',
          settings: Disk(),
          availableSpace: () async => null,
        );
        await budget.initialize();
        final store = CourierStore(
          nodeId: nodeId,
          journal: CourierJournal(
            ownerId: 'owner',
            namespace: 'courier_host',
            storage: Disk(),
          ),
          crypto: Crypto(),
          budget: budget,
          policy: CourierPolicy(
            perDepositorBytes: byteBound ? cost : 256 * 1024 * 1024,
            maxJobsPerDepositor: byteBound ? 128 : 1,
          ),
          clock: () => now,
        );
        await store.initialize();
        await store.acceptOffer(
          from: sender,
          control: offer(),
          challenge: 'test-challenge',
        );
        await expectLater(
          store.acceptOffer(
            from: sender,
            control: offer(id: '2' * 32),
            challenge: 'test-challenge',
          ),
          throwsStateError,
        );
        final other = offer(id: '2' * 32)
          ..['signerId'] = receiver
          ..['publicKey'] = receiverPublic;
        await store.acceptOffer(
          from: receiver,
          control: other,
          challenge: 'test-challenge',
        );
        expect(store.jobCount, 2);
        store.close();
        budget.dispose();
      }
    },
  );
  test(
    'large expiry sweeps stay within protected journal transaction bounds',
    () async {
      var time = now;
      final budget = CachePolicy(
        ownerId: 'owner',
        settings: Disk(),
        availableSpace: () async => null,
      );
      await budget.initialize();
      final store = CourierStore(
        nodeId: nodeId,
        journal: CourierJournal(
          ownerId: 'owner',
          namespace: 'courier_host',
          storage: Disk(),
        ),
        crypto: Crypto(),
        budget: budget,
        clock: () => time,
      );
      await store.initialize();
      for (var i = 1; i <= 100; i++) {
        final lease = await store.acceptOffer(
          from: sender,
          control: offer(id: i.toRadixString(16).padLeft(32, '0')),
          challenge: 'test-challenge',
        );
        await store.writePart(lease.id!, sender, 0, cipher);
        await store.commitPackage(lease.id!);
      }
      time = now + day;
      await store.expire();
      expect(store.jobCount, 100);
      time += day + 1;
      await store.expire();
      expect(store.jobCount, 0);
      expect(store.reservedBytes, CourierPolicy.metadataBytes);
      store.close();
      budget.dispose();
    },
  );
  test('expired tombstones and receipts reclaim only owned copies after retrying failed cleanup', () async {
    var time = now;
    final disk = Disk()..values['owner_history'] = 'keep';
    final budget = CachePolicy(
      ownerId: 'owner',
      settings: Disk(),
      availableSpace: () async => null,
    );
    await budget.initialize();
    final store = CourierStore(
      nodeId: nodeId,
      journal: CourierJournal(
        ownerId: 'owner',
        namespace: 'courier_host',
        storage: disk,
      ),
      crypto: Crypto(),
      budget: budget,
      clock: () => time,
    );
    await store.initialize();
    final baseline = store.reservedBytes;
    final lease = await store.acceptOffer(
      from: sender,
      control: offer(),
      challenge: 'test-challenge',
    );
    await store.writePart(lease.id!, sender, 0, cipher);
    await store.commitPackage(lease.id!);
    final receipt = <String, Object?>{
      'kind': 'receipt',
      'signerId': receiver,
      'publicKey': receiverPublic,
      'signature': 'valid',
      'challenge': 'receipt-secret',
      'body': {
        'jobId': '1' * 32,
        'messageId': '2' * 32,
        'manifestHash': 'd' * 64,
        'receivedAt': now,
      },
    };
    disk.failDelete = true;
    try {
      await store.recordReceipt(
        from: receiver,
        control: receipt,
        challenge: 'receipt-secret',
      );
    } catch (_) {}
    expect(store.reservedBytes, greaterThan(baseline));
    disk.failDelete = false;
    await store.expire();
    final control = <String, Object?>{
      'kind': 'pickup',
      'signerId': sender,
      'publicKey': senderPublic,
      'signature': 'valid',
      'challenge': 'receipts',
      'body': {
        'mailbox': mailbox(senderPublic, now ~/ day),
        'bucket': now ~/ day,
        'action': 'receipts',
      },
    };
    expect(
      await store.listReceipts(
        from: sender,
        control: control,
        challenge: 'receipts',
      ),
      hasLength(1),
    );
    expect(
      await store.listMailbox(
        from: receiver,
        control: pickup(action: 'list'),
        challenge: 'pickup-challenge',
      ),
      isEmpty,
    );
    // A retransmitted proof with a new outer signing time must not consume another slot.
    await store.recordReceipt(
      from: receiver,
      control: {...receipt, 'issuedAt': now + 1},
      challenge: 'receipt-secret',
    );
    expect(
      await store.listReceipts(
        from: sender,
        control: control,
        challenge: 'receipts',
      ),
      hasLength(1),
    );
    time = now + day + 1;
    await store.expire();
    expect(store.jobCount, 0);
    expect(store.reservedBytes, baseline);
    expect(disk.values['owner_history'], 'keep');
    store.close();
    budget.dispose();
  });
  test('byte quotas have exact admission boundaries and requests are bounded while storage stalls', () async {
    final package = CourierPolicy.packageCost(cipher.length),
        metadata = CourierPolicy.metadataBytes;
    for (final delta in [-1, 0]) {
      final disk = Disk(),
          budget = CachePolicy(
            ownerId: 'owner',
            settings: Disk(),
            availableSpace: () async => null,
          );
      await budget.initialize();
      final store = CourierStore(
        nodeId: nodeId,
        journal: CourierJournal(
          ownerId: 'owner',
          namespace: 'courier_host',
          storage: disk,
        ),
        crypto: Crypto(),
        budget: budget,
        policy: CourierPolicy(
          capacityBytes: 2 * metadata + package + delta,
          perDepositorBytes: metadata + package + delta,
          maxRequests: 2,
        ),
        clock: () => now,
      );
      await store.initialize();
      if (delta < 0) {
        await expectLater(
          store.acceptOffer(
            from: sender,
            control: offer(),
            challenge: 'test-challenge',
          ),
          throwsStateError,
        );
      } else {
        final entered = Completer<void>(), release = Completer<void>();
        disk.beforeSave = (_, _) async {
          if (!entered.isCompleted) {
            entered.complete();
            await release.future;
          }
        };
        final first = store.acceptOffer(
          from: sender,
          control: offer(),
          challenge: 'test-challenge',
        );
        await entered.future;
        final second = store.expire();
        await expectLater(store.expire(), throwsStateError);
        release.complete();
        await first;
        await second;
        expect(store.availableBytes, 0);
        await expectLater(
          store.acceptOffer(
            from: sender,
            control: offer(id: '3' * 32),
            challenge: 'test-challenge',
          ),
          throwsStateError,
        );
      }
      store.close();
      budget.dispose();
    }
  });
  test('forged offers and corrupt ciphertext cannot obtain storage acknowledgements', () async {
    final budget = CachePolicy(
      ownerId: 'owner',
      settings: Disk(),
      availableSpace: () async => null,
    );
    await budget.initialize();
    final store = CourierStore(
      nodeId: nodeId,
      journal: CourierJournal(
        ownerId: 'owner',
        namespace: 'courier_host',
        storage: Disk(),
      ),
      crypto: Crypto(),
      budget: budget,
      clock: () => now,
    );
    await store.initialize();
    final forged = offer()..['signature'] = 'forged';
    await expectLater(
      store.acceptOffer(
        from: sender,
        control: forged,
        challenge: 'test-challenge',
      ),
      throwsStateError,
    );
    expect(store.jobCount, 0);
    final lease = await store.acceptOffer(
      from: sender,
      control: offer(),
      challenge: 'test-challenge',
    );
    await expectLater(
      store.writePart(lease.id!, receiver, 0, cipher),
      throwsStateError,
    );
    await store.writePart(lease.id!, sender, 0, Uint8List(cipher.length));
    await expectLater(store.commitPackage(lease.id!), throwsStateError);
    expect(
      await store.listMailbox(
        from: receiver,
        control: pickup(action: 'list'),
        challenge: 'pickup-challenge',
      ),
      isEmpty,
    );
    store.close();
    budget.dispose();
  });
  test('offer requires durable reservation and complete ciphertext before an ACK can be signed', () async {
    final disk = Disk(),
        budget = CachePolicy(
          ownerId: 'owner',
          settings: Disk(),
          availableSpace: () async => null,
        );
    await budget.initialize();
    final store = CourierStore(
      nodeId: nodeId,
      journal: CourierJournal(
        ownerId: 'owner',
        namespace: 'courier_host',
        storage: disk,
      ),
      crypto: Crypto(),
      budget: budget,
      clock: () => now,
    );
    await store.initialize();
    final lease = await store.acceptOffer(
      from: sender,
      control: offer(),
      challenge: 'test-challenge',
    );
    expect(lease.alreadyStored, isFalse);
    await expectLater(store.commitPackage(lease.id!), throwsStateError);
    await store.writePart(lease.id!, sender, 0, cipher);
    disk.failAt = disk.saves + 1;
    await expectLater(store.commitPackage(lease.id!), throwsStateError);
    disk.failAt = null;
    final ack = await store.commitPackage(lease.id!);
    expect(ack['hash'], CourierSenderJobs.packageHash(0, cipher));
    final listed = await store.listMailbox(
      from: receiver,
      control: pickup(action: 'list'),
      challenge: 'pickup-challenge',
    );
    expect(listed.length, 1);
    final bytes = await store.readPackage(
      from: receiver,
      control: pickup(
        action: 'package',
        jobKey: listed.single['jobKey'] as String,
        index: 0,
      ),
      challenge: 'pickup-challenge',
    );
    expect(bytes, cipher);
    await expectLater(
      store.acceptOffer(
        from: sender,
        control: offer(index: 1),
        challenge: 'test-challenge',
      ),
      throwsStateError,
      reason: 'one node never collects the complete set',
    );
    store.close();
    budget.dispose();
  });
  test('restart drops incomplete assemblies, keeps ever-assigned privacy and honours quota/free space', () async {
    final disk = Disk(),
        settings = Disk(),
        budget = CachePolicy(
          ownerId: 'owner',
          settings: settings,
          availableSpace: () async => null,
        );
    await budget.initialize();
    CourierStore create() => CourierStore(
      nodeId: nodeId,
      journal: CourierJournal(
        ownerId: 'owner',
        namespace: 'courier_host',
        storage: disk,
      ),
      crypto: Crypto(),
      budget: budget,
      clock: () => now,
    );
    final first = create();
    await first.initialize();
    await first.acceptOffer(
      from: sender,
      control: offer(),
      challenge: 'test-challenge',
    );
    first.close();
    final next = create();
    await next.initialize();
    expect(next.assemblyCount, 0);
    await expectLater(
      next.acceptOffer(
        from: sender,
        control: offer(index: 1),
        challenge: 'test-challenge',
      ),
      throwsStateError,
    );
    final lease = await next.acceptOffer(
      from: sender,
      control: offer(),
      challenge: 'test-challenge',
    );
    await next.writePart(lease.id!, sender, 0, cipher);
    await next.commitPackage(lease.id!);
    final poor = CachePolicy(
      ownerId: 'owner',
      settings: Disk(),
      availableSpace: () async => 0,
    );
    await poor.initialize();
    final unavailable = CourierStore(
      nodeId: nodeId,
      journal: CourierJournal(
        ownerId: 'owner',
        namespace: 'courier_other',
        storage: Disk(),
      ),
      crypto: Crypto(),
      budget: poor,
      clock: () => now,
    );
    await expectLater(
      unavailable.initialize(),
      throwsA(isA<CachePolicyException>()),
    );
    unavailable.close();
    poor.dispose();
    next.close();
    budget.dispose();
  });
  test('expiry and cancellation remove only Courier copies and reject replay or unauthorized pickup', () async {
    var time = now;
    final disk = Disk()..values['owner_history'] = 'never delete';
    final budget = CachePolicy(
      ownerId: 'owner',
      settings: Disk(),
      availableSpace: () async => null,
    );
    await budget.initialize();
    final store = CourierStore(
      nodeId: nodeId,
      journal: CourierJournal(
        ownerId: 'owner',
        namespace: 'courier_host',
        storage: disk,
      ),
      crypto: Crypto(),
      budget: budget,
      clock: () => time,
    );
    await store.initialize();
    final lease = await store.acceptOffer(
      from: sender,
      control: offer(),
      challenge: 'test-challenge',
    );
    await store.writePart(lease.id!, sender, 0, cipher);
    await store.commitPackage(lease.id!);
    final listed = await store.listMailbox(
      from: receiver,
      control: pickup(action: 'list'),
      challenge: 'pickup-challenge',
    );
    await expectLater(
      store.readPackage(
        from: sender,
        control: pickup(
          action: 'package',
          jobKey: listed.single['jobKey'] as String,
          index: 0,
        ),
        challenge: 'pickup-challenge',
      ),
      throwsStateError,
    );
    await store.cancel(
      from: sender,
      control: {
        'kind': 'cancel',
        'signerId': sender,
        'signature': 'valid',
        'challenge': 'cancel',
        'body': {'jobId': '1' * 32},
      },
      challenge: 'cancel',
    );
    await expectLater(
      store.acceptOffer(
        from: sender,
        control: offer(),
        challenge: 'test-challenge',
      ),
      throwsStateError,
    );
    expect(disk.values['owner_history'], 'never delete');
    time = now + day + 1;
    await store.expire();
    expect(
      await store.listMailbox(
        from: receiver,
        control: pickup(action: 'list'),
        challenge: 'pickup-challenge',
      ),
      isEmpty,
    );
    expect(disk.values['owner_history'], 'never delete');
    store.close();
    budget.dispose();
  });
  test('four assembly and per-depositor byte limits are enforced before concurrent admission', () async {
    final budget = CachePolicy(
      ownerId: 'owner',
      settings: Disk(),
      availableSpace: () async => null,
    );
    await budget.initialize();
    final store = CourierStore(
      nodeId: nodeId,
      journal: CourierJournal(
        ownerId: 'owner',
        namespace: 'courier_host',
        storage: Disk(),
      ),
      crypto: Crypto(),
      budget: budget,
      clock: () => now,
    );
    await store.initialize();
    await Future.wait([
      for (var i = 1; i <= 4; i++)
        store.acceptOffer(
          from: sender,
          control: offer(id: i.toRadixString(16).padLeft(32, '0')),
          challenge: 'test-challenge',
        ),
    ]);
    expect(store.assemblyCount, 4);
    await expectLater(
      store.acceptOffer(
        from: sender,
        control: offer(id: '5' * 32),
        challenge: 'test-challenge',
      ),
      throwsStateError,
    );
    expect(const CourierPolicy().capacityBytes, 1024 * 1024 * 1024);
    expect(const CourierPolicy().perDepositorBytes, 256 * 1024 * 1024);
    store.close();
    budget.dispose();
  });
}
