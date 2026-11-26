import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:cht/runtime/app_runtime.dart';

class FakeRuntime implements RuntimeBridge {
  final calls = <String>[];
  bool enabled = true;
  bool notificationVisible = true;
  bool showLockAction = true;
  int backgroundRefreshSeconds = 10;
  bool fail = false;
  @override
  Future<RuntimeState> configure({
    required bool active,
    bool? enabled,
    bool? showLockAction,
    int? backgroundRefreshSeconds,
  }) async {
    calls.add('$active:$enabled');
    if (fail) throw StateError('Native service unavailable');
    this.enabled = enabled ?? this.enabled;
    this.showLockAction = showLockAction ?? this.showLockAction;
    this.backgroundRefreshSeconds =
        backgroundRefreshSeconds ?? this.backgroundRefreshSeconds;
    return RuntimeState(
      enabled: this.enabled,
      running: active && this.enabled,
      notificationVisible: notificationVisible,
      showLockAction: this.showLockAction,
      backgroundRefreshSeconds: this.backgroundRefreshSeconds,
    );
  }
}

void main() {
  test(
    'background refresh is restored and rejects values outside 10–300',
    () async {
      final bridge = FakeRuntime()..backgroundRefreshSeconds = 120;
      final runtime = AppRuntime(bridge: bridge);
      await runtime.attach('owner', flush: () async {}, lock: () async {});
      expect(runtime.backgroundRefreshSeconds, 120);
      await runtime.setBackgroundRefreshSeconds(300);
      expect(runtime.backgroundRefreshSeconds, 300);
      expect(bridge.backgroundRefreshSeconds, 300);
      expect(runtime.running, isTrue);
      expect(() => runtime.setBackgroundRefreshSeconds(9), throwsRangeError);
      expect(() => runtime.setBackgroundRefreshSeconds(301), throwsRangeError);
    },
  );

  test(
    'overlapping native exit retries take a fresh durable snapshot',
    () async {
      final runtime = AppRuntime(bridge: FakeRuntime());
      final gate = Completer<void>(), entered = Completer<void>();
      var writes = 0;
      final snapshots = <int>[];
      await runtime.attach(
        'owner',
        flush: () async {
          snapshots.add(writes);
          if (snapshots.length == 1) {
            entered.complete();
            await gate.future;
          }
        },
        lock: () async {},
      );
      final first = runtime.handle('exitRequested');
      await entered.future;
      writes++;
      final retry = runtime.handle('exitRequested');
      gate.complete();
      expect(await first, isTrue);
      expect(await retry, isTrue);
      expect(snapshots, [0, 1]);
    },
  );
  test(
    'denied notification permission is not reported as a visible lock action',
    () async {
      final bridge = FakeRuntime()..notificationVisible = false;
      final runtime = AppRuntime(bridge: bridge);
      await runtime.attach('owner', flush: () async {}, lock: () async {});
      expect(runtime.running, isTrue);
      expect(runtime.notificationVisible, isFalse);
      bridge.notificationVisible = true;
      await runtime.setEnabled(true);
      expect(runtime.notificationVisible, isTrue);
    },
  );
  test(
    'a timed-out native exit keeps callbacks available for a later exit',
    () async {
      final runtime = AppRuntime(bridge: FakeRuntime());
      var flushes = 0;
      await runtime.attach(
        'owner',
        flush: () async {
          flushes++;
        },
        lock: () async {},
      );
      expect(await runtime.handle('exitRequested'), isTrue);
      // Native may have cancelled its timeout while this flush was pending.
      expect(runtime.running, isTrue);
      expect(await runtime.handle('exitRequested'), isTrue);
      expect(flushes, 2);
    },
  );
  test('a late shutdown cannot lock a newly attached account', () async {
    final runtime = AppRuntime(bridge: FakeRuntime());
    final gate = Completer<void>(), entered = Completer<void>();
    var locks = 0;
    await runtime.attach(
      'old',
      flush: () {
        entered.complete();
        return gate.future;
      },
      lock: () async {
        locks++;
      },
    );
    final shutdown = runtime.handle('lockRequested');
    await entered.future;
    await runtime.attach(
      'new',
      flush: () async {},
      lock: () async {
        locks++;
      },
    );
    gate.complete();
    expect(await shutdown, isFalse);
    expect(runtime.running, isTrue);
    expect(locks, 0);
  });
  test(
    'retains one account, flushes before explicit lock and stops runtime',
    () async {
      final bridge = FakeRuntime();
      final runtime = AppRuntime(bridge: bridge);
      final events = <String>[];
      await runtime.attach(
        'owner',
        flush: () async => events.add('flush'),
        lock: () async => events.add('lock'),
      );
      expect(runtime.running, isTrue);
      await runtime.handle('lockRequested');
      expect(events, ['flush', 'lock']);
      expect(runtime.running, isFalse);
      expect(bridge.calls.last, 'false:null');
    },
  );

  test('stale home disposal cannot stop a newer account runtime', () async {
    final bridge = FakeRuntime();
    final runtime = AppRuntime(bridge: bridge);
    await runtime.attach('old', flush: () async {}, lock: () async {});
    await runtime.attach('new', flush: () async {}, lock: () async {});
    await runtime.detach('old');
    expect(runtime.running, isTrue);
    expect(bridge.calls.length, 2);
    await runtime.setEnabled(false);
    expect(runtime.running, isFalse);
    expect(bridge.calls.last, 'true:false');
  });

  test('exit waits for durable flush; failed flush refuses exit', () async {
    final runtime = AppRuntime(bridge: FakeRuntime());
    var fail = true;
    await runtime.attach(
      'owner',
      flush: () async {
        if (fail) throw StateError('Storage full');
      },
      lock: () async {},
    );
    expect(await runtime.handle('exitRequested'), isFalse);
    expect(runtime.running, isTrue);
    expect(runtime.error, isNotNull);
    fail = false;
    expect(await runtime.handle('exitRequested'), isTrue);
    expect(runtime.running, isTrue);
  });

  test('native service failure is visible and retryable', () async {
    final bridge = FakeRuntime()..fail = true;
    final runtime = AppRuntime(bridge: bridge);
    await runtime.attach('owner', flush: () async {}, lock: () async {});
    expect(runtime.running, isFalse);
    expect(runtime.error, isNotNull);
    bridge.fail = false;
    await runtime.setEnabled(true);
    expect(runtime.running, isTrue);
    expect(runtime.error, isNull);
  });
}
