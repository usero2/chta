import 'dart:async';

import 'package:cht/chat/cache_policy.dart';
import 'package:flutter_test/flutter_test.dart';

import 'room_history_store_test.dart' show Blobs;

void main() {
  test('Courier aggregate reservations grow while partially written and shrink only after cleanup', () async {
    final policy = CachePolicy(
      ownerId: 'owner',
      settings: Blobs(),
      availableSpace: () async => null,
    );
    await policy.initialize();
    await policy.resizeCourierReservation('courier_host_a', 1000, 100);
    await policy.resizeCourierReservation('courier_host_a', 2000, 200);
    expect(policy.entrySize('courier_host_a'), 2000);
    expect(policy.entryWritten('courier_host_a'), 200);
    await expectLater(
      policy.resizeCourierReservation('courier_host_a', 100, 100),
      throwsA(isA<CachePolicyException>()),
    );
    await policy.resizeCourierReservation(
      'courier_host_a',
      100,
      100,
      afterCleanup: true,
    );
    expect(policy.reservedBytes, 100);
    await expectLater(
      policy.resizeCourierReservation('user_file', 100, 0),
      throwsA(isA<CachePolicyException>()),
    );
    policy.dispose();
  });
  for (final operation in [
    'limit',
    'reserve',
    'existing',
    'retain',
    'release',
    'flush',
  ]) {
    test(
      'progress during $operation settings write stays monotonic after restart',
      () async {
        final blobs = _GatedBlobs();
        final live = CachePolicy(
          ownerId: 'owner',
          settings: blobs,
          availableSpace: () async => null,
        );
        await live.initialize();
        await live.reserve('file', 1000);
        live.noteWritten('file', 100);
        await live.flush();
        blobs.entered = Completer<void>();
        blobs.release = Completer<void>();
        if (operation == 'flush') live.noteWritten('file', 200);
        final Future<void> pending = switch (operation) {
          'limit' => live.setLimitGiB(2),
          'reserve' => live.reserve('other', 10),
          'existing' => live.accountExisting('file', 1000, 200),
          'retain' => live.retainCached('file'),
          'flush' => live.flush(),
          _ => live.release('file'),
        };
        await blobs.entered!.future;
        live.noteWritten('file', 500);
        blobs.release!.complete();
        await pending;
        blobs.entered = null;
        blobs.release = null;
        if (operation != 'flush') await live.flush();
        final restored = CachePolicy(
          ownerId: 'owner',
          settings: blobs,
          availableSpace: () async => null,
        );
        await restored.initialize();
        expect(restored.entryWritten('file'), 500);
        expect(restored.entrySize('file'), greaterThanOrEqualTo(500));
        live.dispose();
        restored.dispose();
      },
    );
  }
  test('a transient settings load failure can be retried without replacing the account', () async {
    final blobs = _ReadFailureBlobs()..failRead = true;
    final policy = CachePolicy(
      ownerId: 'owner',
      settings: blobs,
      availableSpace: () async => null,
    );
    await expectLater(
      policy.initialize(),
      throwsA(isA<CachePolicyException>()),
    );
    expect(policy.ready, isFalse);
    blobs.failRead = false;
    await policy.initialize();
    await policy.reserve('recovered', 10);
    expect(policy.ready, isTrue);
    expect(policy.error, isNull);
    expect(policy.reservedBytes, 10);
    policy.dispose();
  });
  test(
    'settings freeze across lock still lets pending cache work settle',
    () async {
      final policy = CachePolicy(
        ownerId: 'owner',
        settings: Blobs(),
        availableSpace: () async => null,
      );
      await policy.initialize();
      await policy.withChangesPaused(() async {
        expect(policy.canChange, isFalse);
        await expectLater(
          policy.setLimitGiB(1),
          throwsA(isA<CachePolicyException>()),
        );
        await policy.reserve('settling_file', 10);
        await policy.complete('settling_file');
        await policy.flush();
      });
      expect(policy.canChange, isTrue);
      expect(policy.reservedBytes, 10);
      policy.dispose();
    },
  );
  test(
    'cache limits and reservations are protected, persistent and owner scoped',
    () async {
      final blobs = Blobs();
      final policy = CachePolicy(
        ownerId: 'owner',
        settings: blobs,
        availableSpace: () async => null,
      );
      await policy.initialize();
      expect(policy.limitBytes, 20 * CachePolicy.gib);
      await policy.setLimitGiB(1);
      await policy.reserve('file_a', 600 * 1024 * 1024);
      await expectLater(
        policy.reserve('file_b', 600 * 1024 * 1024),
        throwsA(isA<CachePolicyException>()),
      );
      await policy.reserve('file_a', 600 * 1024 * 1024);
      expect(policy.reservedBytes, 600 * 1024 * 1024);
      final resumed = CachePolicy(
        ownerId: 'owner',
        settings: blobs,
        availableSpace: () async => null,
      );
      await resumed.initialize();
      expect(resumed.limitBytes, CachePolicy.gib);
      expect(resumed.reservedBytes, policy.reservedBytes);
      final other = CachePolicy(
        ownerId: 'other',
        settings: blobs,
        availableSpace: () async => null,
      );
      await other.initialize();
      expect(other.reservedBytes, 0);
      await expectLater(
        policy.setLimitGiB(0),
        throwsA(isA<CachePolicyException>()),
      );
      await expectLater(
        policy.setLimitGiB(1025),
        throwsA(isA<CachePolicyException>()),
      );
      policy.dispose();
      resumed.dispose();
      other.dispose();
    },
  );
  test(
    'concurrent jobs reserve free space before either has written bytes',
    () async {
      final policy = CachePolicy(
        ownerId: 'owner',
        settings: Blobs(),
        availableSpace: () async => 1500 * 1024 * 1024,
      );
      await policy.initialize();
      await policy.reserve('first', 800 * 1024 * 1024);
      await expectLater(
        policy.reserve('second', 800 * 1024 * 1024),
        throwsA(isA<CachePolicyException>()),
      );
      policy.noteWritten('first', 800 * 1024 * 1024);
      await policy.complete('first');
      // The estimate already includes completed data, so it is not subtracted twice.
      await policy.reserve('second', 800 * 1024 * 1024);
      expect(policy.reservedBytes, 1600 * 1024 * 1024);
      policy.dispose();
    },
  );
  test('a low-space file is rejected and failed settings writes do not change the limit', () async {
    final blobs = Blobs();
    final policy = CachePolicy(
      ownerId: 'owner',
      settings: blobs,
      availableSpace: () async => CachePolicy.freeSpaceReserve,
    );
    await policy.initialize();
    await expectLater(
      policy.reserve('file', 1),
      throwsA(isA<CachePolicyException>()),
    );
    expect(policy.reservedBytes, 0);
    blobs.failAny = true;
    await expectLater(
      policy.setLimitGiB(2),
      throwsA(isA<CachePolicyException>()),
    );
    expect(policy.limitBytes, 20 * CachePolicy.gib);
    policy.dispose();
  });
  test('a disposed owner cannot persist a new reservation', () async {
    final blobs = Blobs();
    final policy = CachePolicy(
      ownerId: 'owner',
      settings: blobs,
      availableSpace: () async => null,
    );
    await policy.initialize();
    policy.dispose();
    await expectLater(
      policy.reserve('file', 10),
      throwsA(isA<CachePolicyException>()),
    );
    expect(blobs.writes, isEmpty);
  });
}

class _GatedBlobs extends Blobs {
  Completer<void>? entered, release;
  @override
  Future<void> saveGroupBlob(String owner, String key, String value) async {
    if (entered != null && !entered!.isCompleted) {
      entered!.complete();
      await release!.future;
    }
    await super.saveGroupBlob(owner, key, value);
  }
}

class _ReadFailureBlobs extends Blobs {
  bool failRead = false;
  @override
  Future<String?> loadGroupBlob(String owner, String key) async {
    if (failRead) throw StateError('Synthetic temporary read failure');
    return super.loadGroupBlob(owner, key);
  }
}
