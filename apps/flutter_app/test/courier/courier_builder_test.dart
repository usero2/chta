import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cht/chat/cache_policy.dart';
import 'package:cht/chat/chat_attachment.dart';
import 'package:cht/courier/courier_builder.dart';
import 'package:cht/courier/courier_journal.dart';
import 'package:cht/courier/courier_models.dart';
import 'package:cht/courier/sender_jobs.dart';
import 'package:cht/delivery/delivery_envelope.dart';
import 'package:flutter_test/flutter_test.dart';

import '../delivery/delivery_envelope_test.dart' as envelope;
import 'courier_journal_test.dart' show Disk;

class Crypto extends envelope.Crypto {
  bool interrupt = false, active = true;
  int encryptions = 0;
  Map<String, Object?>? sealedMetadata;
  @override
  Future<Map<String, Object?>> deliveryCall(
    String op,
    Map<String, Object?> args,
  ) async {
    if (op == 'newJob') {
      return {
        'state': 'opaque-protected-state:${args['jobId']}',
        'mailbox': 'b' * 64,
        'bucket': 0,
        'receiptChallenge': 'A' * 43,
      };
    }
    if (op == 'encryptPackage') {
      if (interrupt && args['index'] == 1) {
        interrupt = false;
        active = false;
      }
      encryptions++;
      final plain = base64Url.decode(
            base64Url.normalize(args['plaintext'] as String),
          ),
          bytes = Uint8List.fromList([...List.filled(40, 7), ...plain]);
      return {
        'ciphertext': base64UrlEncode(bytes).replaceAll('=', ''),
        'hash': CourierSenderJobs.packageHash(args['index'] as int, bytes),
      };
    }
    if (op == 'sealManifest') {
      sealedMetadata = Map<String, Object?>.from(args['metadata'] as Map);
      return {
        'manifest': {
          'version': 1,
          'jobId': (args['state'] as String).split(':').last,
          'mailbox': 'b' * 64,
          'expiresAt': 86402000,
          'box': 'A' * 128,
        },
        'manifestHash': 'd' * 64,
      };
    }
    return super.deliveryCall(op, args);
  }
}

void main() {
  test(
    'failed job creation reclaims its reservation only after staging recovery',
    () async {
      final crypto = Crypto(),
          disk = Disk(),
          budget = CachePolicy(
            ownerId: 'owner',
            settings: Disk(),
            availableSpace: () async => null,
          );
      await budget.initialize();
      final jobs = CourierSenderJobs(
        journal: CourierJournal(
          ownerId: 'owner',
          namespace: 'courier_send',
          storage: disk,
        ),
        crypto: crypto,
        clock: () => 2000,
      );
      await jobs.initialize();
      final builder = CourierBuilder(
            jobs: jobs,
            crypto: crypto,
            budget: budget,
            clock: () => 2000,
          ),
          e = await DeliveryEnvelope.create(
            crypto,
            scope: 'direct:test',
            messageId: 'original',
            sentAt: 1000,
            kind: 'text',
            payload: {'text': 'hello'},
          );
      disk.failAt = disk.saves + 1;
      await expectLater(
        builder.prepare(
          id: 'a' * 32,
          peerId: 'did:cht:${'b' * 64}',
          envelope: e,
        ),
        throwsStateError,
      );
      expect(jobs.jobs, isEmpty);
      expect(budget.reservedBytes, 0);
      jobs.close();
      budget.dispose();
    },
  );
  test('partial preparation resumes immutable packages and reserves encrypted spool space before writing', () async {
    final crypto = Crypto()..interrupt = true,
        disk = Disk(),
        budget = CachePolicy(
          ownerId: 'owner',
          settings: Disk(),
          availableSpace: () async => null,
        );
    await budget.initialize();
    final jobs = CourierSenderJobs(
      journal: CourierJournal(
        ownerId: 'owner',
        namespace: 'courier_send',
        storage: disk,
      ),
      crypto: crypto,
      clock: () => 2000,
    );
    final builder = CourierBuilder(
      jobs: jobs,
      crypto: crypto,
      budget: budget,
      clock: () => 2000,
    );
    final file = ChatAttachment(
      name: 'test.bin',
      mimeType: 'application/octet-stream',
      bytes: Uint8List(500000),
    );
    final e = await DeliveryEnvelope.create(
      crypto,
      scope: 'direct:test',
      messageId: 'original',
      sentAt: 1000,
      kind: 'file',
      payload: {
        'text': 'caption',
        'file': {
          'name': file.name,
          'mime': file.mimeType,
          'size': file.size,
          'digest': sha256.convert(file.bytes).toString(),
        },
      },
    );
    await expectLater(
      builder.prepare(
        id: 'a' * 32,
        peerId: 'did:cht:${'b' * 64}',
        envelope: e,
        file: file,
        isCurrent: () => crypto.active,
      ),
      throwsStateError,
    );
    expect(jobs.jobs.single.readyCount, 1);
    expect(budget.reservedBytes, greaterThan(file.size));
    crypto.active = true;
    final result = await builder.prepare(
      id: 'a' * 32,
      peerId: 'did:cht:${'b' * 64}',
      envelope: e,
      file: file,
      isCurrent: () => crypto.active,
    );
    expect(result.packageCount, 3);
    expect(result.readyCount, 3);
    expect(result.status, CourierJobStatus.waitingForNodes);
    expect(crypto.encryptions, 4);
    expect(result.messageId, 'original');
    expect(result.sentAt, 1000);
    jobs.close();
    budget.dispose();
  });
  test(
    'group Courier seals an optional signed file offer in its manifest',
    () async {
      final crypto = Crypto(), owner = 'did:cht:${'a' * 64}';
      final budget = CachePolicy(
        ownerId: owner,
        settings: Disk(),
        availableSpace: () async => null,
      );
      final jobs = CourierSenderJobs(
        journal: CourierJournal(
          ownerId: owner,
          namespace: 'courier_send',
          storage: Disk(),
        ),
        crypto: crypto,
        clock: () => 2000,
      );
      addTearDown(jobs.close);
      addTearDown(budget.dispose);
      final builder = CourierBuilder(
        jobs: jobs,
        crypto: crypto,
        budget: budget,
        clock: () => 2000,
      );
      final file = ChatAttachment(
        name: 'draft.pdf',
        mimeType: 'application/pdf',
        bytes: Uint8List.fromList([1, 2, 3]),
      );
      final proof = await DeliveryEnvelope.create(
        crypto,
        scope: 'group:${'c' * 64}:1',
        messageId: 'draft',
        sentAt: 1000,
        kind: 'file',
        payload: {
          'text': 'Draft',
          'groupEvent': '{}',
          'file': {
            'name': 'draft.pdf',
            'mime': 'application/pdf',
            'size': 3,
            'digest': sha256.convert(file.bytes).toString(),
          },
        },
      );
      final peer = 'did:cht:${'b' * 64}';
      await builder.prepare(
        id: 'a' * 32,
        peerId: peer,
        envelope: proof,
        file: file,
        includeOfferHeader: true,
      );
      expect(crypto.sealedMetadata?['offerHeader'], proof.payloadSource);
      await builder.prepare(
        id: 'b' * 32,
        peerId: peer,
        envelope: proof,
        file: file,
      );
      expect(crypto.sealedMetadata, isNot(contains('offerHeader')));
    },
  );
  test(
    'insufficient free disk cannot create a sender job or stage ciphertext',
    () async {
      final crypto = Crypto(),
          budget = CachePolicy(
            ownerId: 'owner',
            settings: Disk(),
            availableSpace: () async => 0,
          );
      await budget.initialize();
      final jobs = CourierSenderJobs(
        journal: CourierJournal(
          ownerId: 'owner',
          namespace: 'courier_send',
          storage: Disk(),
        ),
        crypto: crypto,
        clock: () => 2000,
      );
      final builder = CourierBuilder(
            jobs: jobs,
            crypto: crypto,
            budget: budget,
            clock: () => 2000,
          ),
          e = await DeliveryEnvelope.create(
            crypto,
            scope: 'direct:test',
            messageId: 'original',
            sentAt: 1000,
            kind: 'text',
            payload: {'text': 'hello'},
          );
      await expectLater(
        builder.prepare(
          id: 'a' * 32,
          peerId: 'did:cht:${'b' * 64}',
          envelope: e,
        ),
        throwsA(isA<CachePolicyException>()),
      );
      expect(jobs.jobs, isEmpty);
      expect(crypto.encryptions, 0);
      jobs.close();
      budget.dispose();
    },
  );
}
