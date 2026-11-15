import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:cht/relay/relay_network.dart';
import 'package:cht/relay/relay_peer_sync.dart';
import 'package:cht/relay/relay_chat.dart';

import 'relay_network_test.dart' show Crypto, Hub, Account, until, a, b;

void main() {
  test(
    'relay peers exchange encrypted catalog controls without chat messages',
    () async {
      final hub = Hub(a, 'shared');
      final left = RelayNetwork(Crypto('alice'), connector: hub.connect);
      final right = RelayNetwork(Crypto('bob'), connector: hub.connect);
      final alice = RelayChat(
        Account('alice', 'bob'),
        left,
        ownCard: () async => 'alice',
      );
      final bob = RelayChat(
        Account('bob', 'alice'),
        right,
        ownCard: () async => 'bob',
      );
      final sync = RelayPeerSync(left, send: alice.sendControl);
      final receiver = RelayPeerSync(right, send: bob.sendControl);
      try {
        await left.addSeed(a);
        await right.addSeed(a);
        await until(() => left.online.isNotEmpty && right.online.isNotEmpty);
        alice.select('bob');
        await until(() => alice.authenticated && bob.authenticated);
        await left.mergePeerCatalog({
          'protocol': 'cht-relays',
          'version': 1,
          'urls': [b],
          'relays': [Hub(b, 'learned').record],
        });
        sync.updateSession('bob', authenticated: true);
        receiver.updateSession('alice', authenticated: true);
        await until(() => bob.events.any((event) => event.type == 'control'));
        for (final event in bob.drainEvents()) {
          if (event.type == 'control') {
            await receiver.receive(event.messageId!, event.text!);
          }
          expect(event.type, isNot('message'));
        }
        expect(right.seeds, contains(b));
        expect(right.records.keys, contains('learned'));
        expect(alice.authenticated && bob.authenticated, isTrue);
        await alice.sendMessage('normal', 'hello', 123);
        await until(
          () => bob.events.any((event) => event.messageId == 'normal'),
        );
        expect(
          bob.events.singleWhere((event) => event.messageId == 'normal').text,
          'hello',
        );
        final reconnectFrames = <Map<String, dynamic>>[];
        final original = left.onFrame;
        left.onFrame = (endpoint, frame) {
          reconnectFrames.add(frame);
          original?.call(endpoint, frame);
        };
        left.send(a, {
          'type': 'route',
          'to': 'bob',
          'session': 'c' * 32,
          'packet': 'd' * 32,
          'body': {'type': 'probe', 'contactCard': 'alice'},
        });
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(
          reconnectFrames.where(
            (frame) =>
                frame['session'] == 'c' * 32 &&
                (frame['body'] as Map)['type'] == 'ready',
          ),
          isEmpty,
        );
        expect(alice.authenticated && bob.authenticated, isTrue);
        final stale = alice.sendControl('cht-control-relays-v1-stale', '{}');
        alice.select('another-friend');
        await expectLater(stale, throwsStateError);
        expect(alice.peerId, 'another-friend');
        expect(
          bob.events.where(
            (event) => event.messageId == 'cht-control-relays-v1-stale',
          ),
          isEmpty,
        );
      } finally {
        sync.dispose();
        receiver.dispose();
        await alice.close();
        await bob.close();
      }
    },
  );
  test(
    'sync is authenticated, debounced, scoped and does not echo duplicates',
    () async {
      final network = RelayNetwork(
        Crypto('alice'),
        connector: (_) async => throw StateError('offline'),
      );
      final sent = <String>[];
      final sync = RelayPeerSync(
        network,
        send: (id, text) async {
          sent.add(text);
        },
      );
      try {
        await network.addSeed(a);
        await Future<void>.delayed(const Duration(milliseconds: 600));
        expect(sent, isEmpty);
        sync.updateSession('bob', authenticated: true);
        await Future<void>.delayed(const Duration(milliseconds: 600));
        expect(sent, hasLength(1));
        expect(jsonDecode(sent.single)['urls'], [a]);
        await sync.receive('cht-control-relays-v1-packet', sent.single);
        await Future<void>.delayed(const Duration(milliseconds: 600));
        expect(sent, hasLength(1));
        await network.addSeed(b);
        await network.addSeed(b);
        await Future<void>.delayed(const Duration(milliseconds: 600));
        expect(sent, hasLength(2));
        sync.updateSession(null, authenticated: false);
        await network.addSeed('wss://c.example.com/cht');
        await Future<void>.delayed(const Duration(milliseconds: 600));
        expect(sent, hasLength(2));
        sync.updateSession('bob', authenticated: true);
        await Future<void>.delayed(const Duration(milliseconds: 600));
        expect(sent, hasLength(3));
      } finally {
        sync.dispose();
        await network.close();
      }
    },
  );

  test(
    'peer catalogs reject unsafe URLs, forged records and oversized envelopes',
    () async {
      final network = RelayNetwork(
        Crypto('alice'),
        connector: (_) async => throw StateError('offline'),
      );
      final sync = RelayPeerSync(network, send: (_, _) async {});
      try {
        final record = Hub(b, 'valid').record;
        final payload = jsonEncode({
          'protocol': 'cht-relays',
          'version': 1,
          'urls': [a, 'wss://127.0.0.1/cht', 'wss://10.1.2.3/cht'],
          'relays': [
            record,
            {...record, 'relayId': 'forged', 'signature': 'bad'},
          ],
        });
        await sync.receive('cht-control-relays-v1-one', payload);
        expect(network.seeds, isEmpty);
        sync.updateSession('bob', authenticated: true);
        await sync.receive('cht-control-relays-v1-one', payload);
        expect(network.seeds, [a]);
        expect(network.records.keys, ['valid']);
        await sync.receive(
          'cht-control-relays-v1-two',
          jsonEncode({
            'protocol': 'cht-relays',
            'version': 1,
            'urls': List.filled(9, b),
            'relays': [],
          }),
        );
        expect(network.seeds, [a]);
        await sync.receive('cht-control-relays-v1-three', 'x' * 12001);
        expect(network.seeds, [a]);
        expect(RelayPeerSync.isControlId('hello'), isFalse);
        expect(
          RelayPeerSync.isControlId('cht-control-relays-v2-future'),
          isTrue,
        );
      } finally {
        sync.dispose();
        await network.close();
      }
    },
  );
}
