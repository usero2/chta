import 'dart:convert';
import 'dart:typed_data';

import 'package:cht/courier/courier_journal.dart';
import 'package:cht/courier/courier_models.dart';
import 'package:cht/courier/sender_job.dart';
import 'package:cht/courier/sender_jobs.dart';
import 'package:cht/delivery/delivery_crypto_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

import 'courier_journal_test.dart' show Disk;
import 'distribution_test.dart' show node;

const peer =
    'did:cht:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

class Crypto implements DeliveryCryptoBridge {
  @override
  Future<Map<String, Object?>> deliveryCall(
    String op,
    Map<String, Object?> args,
  ) async {
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

CourierSenderJob job() => CourierSenderJob(
  id: 'a' * 32,
  peerId: peer,
  messageId: 'original-message',
  scope: 'direct:test',
  sentAt: 1000,
  expiresAt: 10000,
  packageCount: 2,
  protectedState: 'protected-only',
  mailbox: 'b' * 64,
  mailboxBucket: 0,
  receiptChallenge: base64UrlEncode(List.filled(32, 5)).replaceAll('=', ''),
  event: const {'messageId': 'original-message'},
);
Future<void> prepare(CourierSenderJobs jobs) async {
  await jobs.create(job());
  for (var index = 0; index < 2; index++) {
    final bytes = Uint8List.fromList(List.filled(41, index));
    await jobs.stagePackage('a' * 32, index, bytes);
  }
  await jobs.setManifest(
    'a' * 32,
    {
      'version': 1,
      'jobId': 'a' * 32,
      'mailbox': 'b' * 64,
      'expiresAt': 10000,
      'box': base64UrlEncode(List.filled(128, 7)).replaceAll('=', ''),
    },
    'c' * 64,
    'd' * 64,
  );
}

void main() {
  test('terminal spool cleanup is restart-safe and a cancelled job retains its late-receipt proof', () async {
    final disk = Disk(),
        jobs = CourierSenderJobs(
          journal: CourierJournal(
            ownerId: 'owner',
            namespace: 'courier_send',
            storage: disk,
          ),
          crypto: Crypto(),
          clock: () => 2000,
        );
    await prepare(jobs);
    await jobs.cancel('a' * 32);
    disk.failDelete = true;
    await expectLater(jobs.purge('a' * 32), throwsStateError);
    disk.failDelete = false;
    await jobs.purge('a' * 32);
    expect(jobs.jobs.single.readyCount, 0);
    expect(jobs.jobs.single.receiptChallenge, job().receiptChallenge);
    await jobs.purge('a' * 32, forget: true);
    expect(jobs.jobs, isEmpty);
    final reopened = CourierSenderJobs(
      journal: CourierJournal(
        ownerId: 'owner',
        namespace: 'courier_send',
        storage: disk,
      ),
      crypto: Crypto(),
      clock: () => 2000,
    );
    await reopened.initialize();
    expect(reopened.jobs, isEmpty);
    jobs.close();
    reopened.close();
  });
  test('allocation is durable before dispatch and aliases never satisfy the minimum', () async {
    final disk = Disk(),
        journal = CourierJournal(
          ownerId: 'owner',
          namespace: 'courier_send',
          storage: disk,
        ),
        crypto = Crypto();
    final jobs = CourierSenderJobs(
      journal: journal,
      crypto: crypto,
      clock: () => 2000,
    );
    await jobs.initialize();
    await prepare(jobs);
    await jobs.allocate('a' * 32, [node(1), node(1)]);
    expect(jobs.jobs.single.status, CourierJobStatus.waitingForNodes);
    expect(await jobs.pendingDeposits('a' * 32), isEmpty);
    disk.failAt = disk.saves + 1;
    await expectLater(
      jobs.allocate('a' * 32, [node(1), node(2)]),
      throwsStateError,
    );
    expect(await jobs.pendingDeposits('a' * 32), isEmpty);
    disk.failAt = null;
    await jobs.allocate('a' * 32, [node(1), node(2)]);
    final reopened = CourierSenderJobs(
      journal: CourierJournal(
        ownerId: 'owner',
        namespace: 'courier_send',
        storage: disk,
      ),
      crypto: crypto,
      clock: () => 2000,
    );
    await reopened.initialize();
    final pending = await reopened.pendingDeposits('a' * 32);
    expect(pending.length, 2);
    expect(pending.map((p) => p.nodeId).toSet().length, 2);
    await reopened.journal.commit({}, {'node_${'a' * 32}_${node(1).nodeId}'});
    final damaged = CourierSenderJobs(
      journal: CourierJournal(
        ownerId: 'owner',
        namespace: 'courier_send',
        storage: disk,
      ),
      crypto: crypto,
      clock: () => 2000,
    );
    await damaged.initialize();
    await expectLater(damaged.pendingDeposits('a' * 32), throwsStateError);
  });
  test('storage ACK stays separate from Delivered, pause/cancel persist, a late genuine receipt is recorded', () async {
    final disk = Disk(),
        jobs = CourierSenderJobs(
          journal: CourierJournal(
            ownerId: 'owner',
            namespace: 'courier_send',
            storage: disk,
          ),
          crypto: Crypto(),
          clock: () => 2000,
        );
    await jobs.initialize();
    await prepare(jobs);
    await jobs.allocate('a' * 32, [node(1), node(2)]);
    for (final part in await jobs.pendingDeposits('a' * 32)) {
      await jobs.recordStorageAck(
        'a' * 32,
        nodeId: part.nodeId,
        challenge: job().receiptChallenge,
        control: {
          'kind': 'stored',
          'signature': 'valid',
          'signerId': part.nodeId,
          'challenge': job().receiptChallenge,
          'body': {
            'jobId': 'a' * 32,
            'allocationRevision': jobs.jobs.single.allocationRevision,
            'index': part.index,
            'hash': part.hash,
          },
        },
      );
    }
    expect(jobs.jobs.single.status, CourierJobStatus.stored);
    await jobs.allocate('a' * 32, []);
    expect(
      jobs.jobs.single.status,
      CourierJobStatus.stored,
      reason: 'a temporary discovery loss does not undo durable storage',
    );
    expect(jobs.jobs.single.receivedAt, isNull);
    await jobs.pause('a' * 32);
    expect(await jobs.pendingDeposits('a' * 32), isEmpty);
    await jobs.resume('a' * 32);
    await jobs.cancel('a' * 32);
    final receipt = {
      'kind': 'receipt',
      'signature': 'valid',
      'signerId': peer,
      'challenge': job().receiptChallenge,
      'body': {
        'jobId': 'a' * 32,
        'messageId': 'original-message',
        'manifestHash': 'c' * 64,
        'receivedAt': 1900,
      },
    };
    await expectLater(
      jobs.recordReceipt('a' * 32, {...receipt, 'signature': 'forged'}),
      throwsStateError,
    );
    await jobs.recordReceipt('a' * 32, receipt);
    expect(jobs.jobs.single.status, CourierJobStatus.delivered);
    expect(jobs.jobs.single.receivedAt, 1900);
    expect(jobs.jobs.single.cancelled, isTrue);
    final reopened = CourierSenderJobs(
      journal: CourierJournal(
        ownerId: 'owner',
        namespace: 'courier_send',
        storage: disk,
      ),
      crypto: Crypto(),
      clock: () => 2000,
    );
    await reopened.initialize();
    expect(reopened.jobs.single.receivedAt, 1900);
    expect(await reopened.pendingDeposits('a' * 32), isEmpty);
  });
}
