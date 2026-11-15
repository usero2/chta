import 'dart:convert';

import 'package:cht/relay/relay_network.dart';
import 'package:flutter_test/flutter_test.dart';

import 'relay_network_test.dart' show Crypto, Hub, a;

const _week = 7 * 24 * 60 * 60 * 1000;

void main() {
  test('removes a known failed relay at the seven day boundary', () async {
    var time = 1000;
    final crypto = Crypto('alice');
    final network = RelayNetwork(
      crypto,
      connector: (_) async => throw StateError('offline'),
      clock: () => time,
    );
    try {
      await network.addSeed(a);
      await _until(
        () => network.statusFor(a) == RelayConnectionStatus.unavailable,
      );
      time += _week - 1;
      await network.tick();
      await _until(
        () => network.statusFor(a) == RelayConnectionStatus.unavailable,
      );
      expect(network.seeds, contains(a));

      time++;
      time += 60_000;
      await network.tick();
      await _until(() => !network.seeds.contains(a));
      expect(
        network.records.values.any((record) => record['endpoint'] == a),
        isFalse,
      );
    } finally {
      await network.close();
    }
  });

  test(
    'a successful registration resets the seven day unavailable period',
    () async {
      var time = DateTime.now().millisecondsSinceEpoch;
      var available = false;
      final hub = _LongLivedHub(a, 'relay-a', () => time);
      final network = RelayNetwork(
        Crypto('alice'),
        connector: (endpoint) async {
          if (!available) throw StateError('offline');
          return hub.connect(endpoint);
        },
        clock: () => time,
      );
      try {
        await network.addSeed(a);
        await _until(
          () => network.statusFor(a) == RelayConnectionStatus.unavailable,
        );
        time += _week - 1;
        available = true;
        await network.tick();
        await _until(
          () => network.statusFor(a) == RelayConnectionStatus.online,
        );

        available = false;
        await hub.stop();
        await _until(
          () => network.statusFor(a) == RelayConnectionStatus.unavailable,
        );
        time += _week - 1;
        await network.tick();
        await _until(
          () => network.statusFor(a) == RelayConnectionStatus.unavailable,
        );
        expect(network.seeds, contains(a));

        time++;
        time += 60_000;
        await network.tick();
        await _until(() => !network.seeds.contains(a));
      } finally {
        await network.close();
      }
    },
  );

  test(
    'persists the first failure but does not age an untested saved relay',
    () async {
      var time = 1000;
      final crypto = Crypto('alice');
      final first = RelayNetwork(
        crypto,
        connector: (_) async => throw StateError('offline'),
        clock: () => time,
      );
      await first.addSeed(a);
      await _until(
        () => first.statusFor(a) == RelayConnectionStatus.unavailable,
      );
      await first.close();

      time += _week;
      final restored = RelayNetwork(
        crypto,
        connector: (_) async => throw StateError('offline'),
        clock: () => time,
      );
      try {
        await restored.initialize();
        await _until(() => !restored.seeds.contains(a));
      } finally {
        await restored.close();
      }

      final untestedCrypto = Crypto('alice')
        ..cache = jsonEncode({
          'version': 1,
          'seeds': [a],
        });
      final untested = RelayNetwork(
        untestedCrypto,
        connector: (_) async => throw StateError('offline'),
        clock: () => time,
      );
      try {
        await untested.initialize();
        await _until(
          () => untested.statusFor(a) == RelayConnectionStatus.unavailable,
        );
        expect(untested.seeds, contains(a));
      } finally {
        await untested.close();
      }
    },
  );

  test(
    'user lock is persisted and prevents automatic removal until unlocked',
    () async {
      var time = 1000;
      final crypto = Crypto('alice');
      final network = RelayNetwork(
        crypto,
        connector: (_) async => throw StateError('offline'),
        clock: () => time,
      );
      try {
        await network.addSeed(a);
        await _until(
          () => network.statusFor(a) == RelayConnectionStatus.unavailable,
        );
        network.pins[a] = 'relay-a';
        await network.setRelayLocked(a, true);
        expect(network.isRelayLocked(a), isTrue);
        expect(network.pins[a], 'relay-a');
        expect((jsonDecode(crypto.cache) as Map)['userLockedRelays'], [a]);

        time += _week;
        time += 60_000;
        await network.tick();
        await _until(
          () => network.statusFor(a) == RelayConnectionStatus.unavailable,
        );
        expect(network.seeds, contains(a));

        final restored = RelayNetwork(
          crypto,
          connector: (_) async => throw StateError('offline'),
          clock: () => time,
        );
        try {
          await restored.initialize();
          expect(restored.isRelayLocked(a), isTrue);
          expect(restored.seeds, contains(a));
          await restored.setRelayLocked(a, false);
          await restored.tick();
          await _until(() => !restored.seeds.contains(a));
        } finally {
          await restored.close();
        }
      } finally {
        await network.close();
      }
    },
  );

  test(
    'automatic removal preserves the local hosted relay and active route',
    () async {
      var time = 1000;
      final endpoint = 'ws://localhost:9000/cht';
      final network = RelayNetwork(
        Crypto('alice'),
        connector: (_) async => throw StateError('offline'),
        clock: () => time,
      );
      try {
        await network.addHostedEndpoint(null, endpoint);
        await _until(
          () =>
              network.statusFor(endpoint) == RelayConnectionStatus.unavailable,
        );
        time += _week;
        time += 60_000;
        await network.tick();
        await _until(
          () =>
              network.statusFor(endpoint) == RelayConnectionStatus.unavailable,
        );
        expect(network.hostedEndpoint, endpoint);
        expect(network.seeds, contains(endpoint));

        final active = 'wss://active.example.com/cht';
        await network.addSeed(active);
        network.activeEndpoint = active;
        await _until(
          () => network.statusFor(active) == RelayConnectionStatus.unavailable,
        );
        time += _week;
        await network.tick();
        await _until(
          () => network.statusFor(active) == RelayConnectionStatus.unavailable,
        );
        expect(network.seeds, contains(active));
      } finally {
        await network.close();
      }
    },
  );

  test('manual forget removes a user locked relay', () async {
    final network = RelayNetwork(
      Crypto('alice'),
      connector: (_) async => throw StateError('offline'),
    );
    try {
      await network.addSeed(a);
      await _until(
        () => network.statusFor(a) == RelayConnectionStatus.unavailable,
      );
      await network.setRelayLocked(a, true);
      await network.forget(a);
      expect(network.isRelayLocked(a), isFalse);
      expect(network.seeds, isNot(contains(a)));
    } finally {
      await network.close();
    }
  });

  test(
    'locked endpoint survives expiry without accepting the expired record',
    () async {
      var time = DateTime.now().millisecondsSinceEpoch + 24 * 60 * 60 * 1000;
      final hub = Hub(a, 'relay-a');
      final crypto = Crypto('alice')
        ..cache = jsonEncode({
          'version': 1,
          'userLockedRelays': [a],
          'relays': [
            {...hub.record, 'expiresAt': time - 1},
          ],
        });
      final network = RelayNetwork(
        crypto,
        connector: hub.connect,
        clock: () => time,
      );
      try {
        await network.initialize();
        await _until(
          () => network.statusFor(a) == RelayConnectionStatus.unavailable,
        );
        expect(network.isRelayLocked(a), isTrue);
        expect(network.userLockedRelays, contains(a));
        expect(
          network.records.values.any((record) => record['endpoint'] == a),
          isFalse,
        );
      } finally {
        await network.close();
      }
    },
  );
}

Future<void> _until(bool Function() test) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!test()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for relay state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class _LongLivedHub extends Hub {
  _LongLivedHub(super.url, super.id, this.clock);

  final int Function() clock;

  @override
  Map<String, dynamic> get record => {
    'relayId': id,
    'endpoint': url,
    'issuedAt': clock() - 1,
    'expiresAt': clock() + 30 * 24 * 60 * 60 * 1000,
    'signature': 'test-valid',
  };
}
