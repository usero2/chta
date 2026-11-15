import 'dart:async';
import 'dart:convert';

import 'package:cht/relay/relay_network.dart';
import 'package:cht/relay/relay_peer_sync.dart';
import 'package:cht/relay/relay_socket.dart';
import 'package:flutter_test/flutter_test.dart';

import 'relay_network_test.dart' show Crypto, Hub, a, b, until;

void main() {
  test(
    'records local add, refresh and route use without catalog echo',
    () async {
      var time = 1000;
      final crypto = Crypto('alice');
      final hub = Hub(a, 'relay-a');
      final network = RelayNetwork(
        crypto,
        connector: hub.connect,
        clock: () => time,
      );
      final sent = <String>[];
      final sync = RelayPeerSync(
        network,
        send: (_, text) async => sent.add(text),
      );
      try {
        await network.addSeed(a);
        await until(() => network.online.isNotEmpty);
        expect(network.activityFor(a).addedAtMilliseconds, 1000);
        expect(network.activityFor(a).updatedAtMilliseconds, 1000);
        expect(network.activityFor(a).lastUsedAtMilliseconds, isNull);
        time = 2000;
        await network.addSeed(a);
        expect(network.activityFor(a).updatedAtMilliseconds, 1000);
        time = 3000;
        hub.sockets.single.receive({
          'type': 'catalog',
          'relays': [
            {...hub.record, 'issuedAt': 2},
          ],
        });
        await until(() => network.activityFor(a).updatedAtMilliseconds == 3000);
        time = 4000;
        hub.sockets.single.receive({
          'type': 'catalog',
          'relays': [hub.record],
        });
        await network.tick();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(network.activityFor(a).updatedAtMilliseconds, 3000);
        expect(network.activityFor(a).lastUsedAtMilliseconds, isNull);
        sync.updateSession('bob', authenticated: true);
        await until(() => sent.isNotEmpty);
        time = 5000;
        expect(network.send(a, {'type': 'route', 'to': 'nobody'}), isTrue);
        expect(network.activityFor(a).lastUsedAtMilliseconds, 5000);
        time = 6000;
        hub.sockets.single.receive({'type': 'route', 'from': 'bob'});
        await until(
          () => network.activityFor(a).lastUsedAtMilliseconds == 6000,
        );
        await Future<void>.delayed(const Duration(milliseconds: 1600));
        expect(sent, hasLength(1));
        final state = jsonDecode(crypto.cache) as Map;
        expect(state['activity'][a], {
          'addedAtMilliseconds': 1000,
          'updatedAtMilliseconds': 3000,
          'lastUsedAtMilliseconds': 6000,
        });
        expect(jsonEncode(network.peerCatalog()), isNot(contains('lastUsed')));
        time = 6500;
        expect(network.send(a, {'type': 'route', 'to': 'nobody'}), isTrue);
        await network.close();
        final restored = RelayNetwork(
          crypto,
          connector: (_) async => throw StateError('offline'),
          clock: () => 7000,
        );
        try {
          await restored.initialize();
          expect(restored.activityFor(a).addedAtMilliseconds, 1000);
          expect(restored.activityFor(a).updatedAtMilliseconds, 3000);
          expect(restored.activityFor(a).lastUsedAtMilliseconds, 6500);
        } finally {
          await restored.close();
        }
      } finally {
        sync.dispose();
        await network.close();
      }
    },
  );

  test(
    'restores legacy dates as unknown and tracks new discovery separately',
    () async {
      var time = 1000;
      final crypto = Crypto('alice')
        ..cache = jsonEncode({
          'version': 1,
          'seeds': [a],
          'pins': {a: 'relay-a'},
          'relays': [Hub(a, 'relay-a').record],
        });
      final network = RelayNetwork(
        crypto,
        connector: (_) async => throw StateError('offline'),
        clock: () => time,
      );
      try {
        await network.initialize();
        await network.addSeed(a);
        expect(network.activityFor(a).addedAtMilliseconds, isNull);
        expect(network.activityFor(a).updatedAtMilliseconds, isNull);
        expect(network.activityFor(a).lastUsedAtMilliseconds, isNull);
        await network.mergePeerCatalog({
          'protocol': 'cht-relays',
          'version': 1,
          'urls': [b],
          'relays': [],
        });
        expect(network.activityFor(b).addedAtMilliseconds, 1000);
        time = 2000;
        await network.mergePeerCatalog({
          'protocol': 'cht-relays',
          'version': 1,
          'urls': [b],
          'relays': [],
        });
        expect(network.activityFor(b).updatedAtMilliseconds, 1000);
        await network.forget(b);
        expect(network.activityFor(b).addedAtMilliseconds, isNull);
        expect(network.statusFor(b), RelayConnectionStatus.disconnected);
        await network.addContactRoutes([b]);
        expect(network.activityFor(b).addedAtMilliseconds, 2000);
        time = 3000;
        await network.addHostedEndpoint(null, 'ws://localhost:9000/cht');
        expect(
          network.activityFor('ws://localhost:9000/cht').addedAtMilliseconds,
          3000,
        );
      } finally {
        await network.close();
      }
    },
  );

  test(
    'status follows pending, registered, failed and closed sockets',
    () async {
      final pending = Completer<RelaySocket>();
      final hub = Hub(a, 'relay-a');
      final network = RelayNetwork(
        Crypto('alice'),
        connector: (_) => pending.future,
      );
      try {
        expect(network.statusFor(a), RelayConnectionStatus.disconnected);
        await network.addSeed(a);
        expect(network.statusFor(a), RelayConnectionStatus.connecting);
        pending.complete(await hub.connect(a));
        await until(() => network.online.isNotEmpty);
        expect(network.statusFor(a), RelayConnectionStatus.online);
        await hub.stop();
        await until(() => network.online.isEmpty);
        expect(network.statusFor(a), RelayConnectionStatus.unavailable);
        expect(network.send(a, {'type': 'route'}), isFalse);
        expect(network.activityFor(a).lastUsedAtMilliseconds, isNull);
        await network.close();
        expect(network.statusFor(a), RelayConnectionStatus.disconnected);
      } finally {
        await network.close();
      }
    },
  );

  test('restores activity beyond the first cached record batch', () async {
    final endpoints = List.generate(70, (i) => 'wss://r$i.example.com/cht');
    final crypto = Crypto('alice')
      ..cache = jsonEncode({
        'version': 1,
        'relays': [
          for (var i = 0; i < 70; i++) Hub(endpoints[i], 'relay-$i').record,
        ],
        'activity': {
          for (final endpoint in endpoints)
            endpoint: {
              'addedAtMilliseconds': 1000,
              'updatedAtMilliseconds': 2000,
              'lastUsedAtMilliseconds': 3000,
            },
        },
      });
    final network = RelayNetwork(
      crypto,
      connector: (_) async => throw StateError('offline'),
      clock: () => 4000,
    );
    try {
      await network.initialize();
      expect(network.records, hasLength(70));
      expect(network.activityFor(endpoints.last).addedAtMilliseconds, 1000);
      expect(network.activityFor(endpoints.last).lastUsedAtMilliseconds, 3000);
    } finally {
      await network.close();
    }
  });

  test('ignores malformed and out of range cached timestamps', () async {
    final crypto = Crypto('alice')
      ..cache = jsonEncode({
        'version': 1,
        'seeds': [a],
        'activity': {
          a: {
            'addedAtMilliseconds': 8640000000000001,
            'updatedAtMilliseconds': -1,
            'lastUsedAtMilliseconds': 'yesterday',
          },
        },
      });
    final network = RelayNetwork(
      crypto,
      connector: (_) async => throw StateError('offline'),
    );
    try {
      await network.initialize();
      expect(network.activityFor(a).addedAtMilliseconds, isNull);
      expect(network.activityFor(a).updatedAtMilliseconds, isNull);
      expect(network.activityFor(a).lastUsedAtMilliseconds, isNull);
    } finally {
      await network.close();
    }
  });
}
