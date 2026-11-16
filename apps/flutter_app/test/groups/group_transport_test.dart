import 'dart:async';
import 'dart:convert';

import 'package:cht/groups/group_crypto_bridge.dart';
import 'package:cht/groups/group_seed_client.dart';
import 'package:cht/groups/group_transport.dart';
import 'package:cht/p2p/direct_file_link.dart';
import 'package:cht/relay/relay_network.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../relay/relay_network_test.dart' as fixture;
import '../p2p/direct_file_link_test.dart' as direct_fixture;

String did(String c) => 'did:cht:${c * 64}';

class QuietSeed extends ChangeNotifier implements GroupSignaling {
  @override
  bool get registered => false;
  final events = StreamController<GroupSeedSignal>.broadcast();
  @override
  Stream<GroupSeedSignal> get signals => events.stream;
  @override
  Future<void> start(String owner) async {}
  @override
  Future<void> send(String peer, String id, String text) async {
    throw StateError('offline');
  }

  @override
  Future<void> close() async {
    await events.close();
    super.dispose();
  }
}

class FakeGroups implements GroupCryptoBridge {
  FakeGroups(this.allowed);
  final Set<String> allowed;
  final calls = <String>[];
  String? failEncryptFor;
  @override
  Future<Map<String, Object?>> groupCall(
    String op,
    Map<String, Object?> args,
  ) async {
    calls.add(op);
    if (op == 'authorize') return {'allowed': allowed.contains(args['peerId'])};
    if (!allowed.contains(args['peerId'])) throw StateError('unauthorized');
    if (op == 'handshake' && !['start', 'reply'].contains(args['frame'])) {
      throw const FormatException('Bad handshake');
    }
    if (op == 'encrypt' && args['peerId'] == failEncryptFor) {
      failEncryptFor = null;
      throw StateError('Crypto failed');
    }
    return switch (op) {
      'start' => {'frame': 'start'},
      'handshake' => {
        'reply': args['frame'] == 'start' ? 'reply' : null,
        'established': true,
      },
      'encrypt' => {
        'frame': base64UrlEncode(
          utf8.encode(jsonEncode({'id': args['id'], 'text': args['text']})),
        ).replaceAll('=', ''),
      },
      'decrypt' => Map<String, Object?>.from(
        jsonDecode(
          utf8.decode(
            base64Url.decode(base64Url.normalize(args['frame'] as String)),
          ),
        ) as Map,
      ),
      _ => {},
    };
  }
}

class RegisteredSeed extends QuietSeed {
  @override
  bool get registered => true;
  @override
  Future<void> send(String peer, String id, String text) async {}
}

class FailingDirectFactory implements DirectPeerFactory {
  @override
  Future<DirectPeer> create() async =>
      throw StateError('Synthetic WebRTC unavailable');
}

void main() {
  test(
    'failed WebRTC negotiation does not block encrypted group relay delivery',
    () async {
      final hub = fixture.Hub(fixture.a, 'relay-a');
      final a = RelayNetwork(fixture.Crypto(did('a')), connector: hub.connect),
          b = RelayNetwork(fixture.Crypto(did('b')), connector: hub.connect);
      final alice = GroupTransport(
        ownerId: did('a'),
        crypto: FakeGroups({did('a'), did('b')}),
        network: a,
        signaling: RegisteredSeed(),
        peerFactory: FailingDirectFactory(),
      );
      final bob = GroupTransport(
        ownerId: did('b'),
        crypto: FakeGroups({did('a'), did('b')}),
        network: b,
        signaling: RegisteredSeed(),
        peerFactory: FailingDirectFactory(),
      );
      final received = <String>[];
      bob.frames.listen((f) => received.add(f.text));
      try {
        await a.addSeed(fixture.a);
        await b.addSeed(fixture.a);
        await alice.start();
        await bob.start();
        await fixture.until(() => a.online.isNotEmpty && b.online.isNotEmpty);
        await alice.connect(did('b'));
        await fixture.until(
          () => alice.connected(did('b')) && bob.connected(did('a')),
        );
        await alice.send(did('b'), 'synthetic group invitation');
        await fixture.until(() => received.isNotEmpty);
        expect(received.single, 'synthetic group invitation');
      } finally {
        await alice.close();
        await bob.close();
        await a.close();
        await b.close();
      }
    },
  );
  test('ICE waits for an asynchronous glare replacement on the same peer', () async {
    final gate = Completer<void>(), factory = direct_fixture.FakeFactory();
    final seed = RegisteredSeed(),
        network = RelayNetwork(fixture.Crypto(did('b')));
    final transport = GroupTransport(
      ownerId: did('b'),
      crypto: FakeGroups({did('a')}),
      network: network,
      signaling: seed,
      peerFactory: factory,
    );
    final session = 'f' * 32;
    try {
      await transport.start();
      await transport.connect(did('a'));
      factory.peers.first.closeGate = gate.future;
      seed.events.add(
        GroupSeedSignal(
          did('a'),
          'cht-control-groups-v1-$session-offer-1',
          jsonEncode({
            'v': 1,
            't': 'offer',
            's': session,
            'd':
                'v=0\na=fingerprint:sha-256 ${direct_fixture.FakePeer.fingerprint}\n',
          }),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      seed.events.add(
        GroupSeedSignal(
          did('a'),
          'cht-control-groups-v1-$session-ice-2',
          jsonEncode({
            'v': 1,
            't': 'ice',
            's': session,
            'c': 'candidate:1 1 udp 1 127.0.0.1 9 typ host',
            'm': '0',
            'l': 0,
          }),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      gate.complete();
      await fixture.until(
        () =>
            factory.peers.length == 2 &&
            factory.peers.last.addedCandidates.isNotEmpty,
      );
      expect(factory.peers.last.addedCandidates, hasLength(1));
    } finally {
      if (!gate.isCompleted) gate.complete();
      await transport.close();
      await network.close();
    }
  });
  test(
    'simultaneous group peers share a relay without replacing DM callback',
    () async {
      final hub = fixture.Hub(fixture.a, 'relay-a');
      final networks = <RelayNetwork>[], transports = <GroupTransport>[];
      for (final key in ['a', 'b', 'c']) {
        final network = RelayNetwork(
          fixture.Crypto(did(key)),
          connector: hub.connect,
        );
        networks.add(network);
        await network.addSeed(fixture.a);
        final t = GroupTransport(
          ownerId: did(key),
          crypto: FakeGroups({'a', 'b', 'c'}.map(did).toSet()),
          network: network,
          signaling: QuietSeed(),
        );
        transports.add(t);
        await t.start();
      }
      var legacy = 0;
      networks[1].onFrame = (_, _) => legacy++;
      final receivedB = <String>[], receivedC = <String>[];
      transports[1].frames.listen((f) => receivedB.add(f.text));
      transports[2].frames.listen((f) => receivedC.add(f.text));
      try {
        await transports[0].connect(did('b'));
        await transports[0].connect(did('c'));
        await fixture.until(
          () =>
              transports[0].connected(did('b')) &&
              transports[0].connected(did('c')),
        );
        await transports[0].send(did('b'), 'B' * 20000);
        await transports[0].send(did('c'), 'C only');
        await fixture.until(() => receivedB.isNotEmpty && receivedC.isNotEmpty);
        expect(receivedB.single, 'B' * 20000);
        expect(receivedC.single, 'C only');
        expect(legacy, greaterThan(0));
        await expectLater(transports[0].connect(did('d')), throwsStateError);
      } finally {
        for (final t in transports) {
          await t.close();
        }
        for (final n in networks) {
          await n.close();
        }
      }
    },
  );
  test('invalid new start leaves established group peer ready', () async {
    final hub = fixture.Hub(fixture.a, 'relay-a');
    final left = RelayNetwork(fixture.Crypto(did('a')), connector: hub.connect);
    final right = RelayNetwork(
      fixture.Crypto(did('b')),
      connector: hub.connect,
    );
    final alice = GroupTransport(
      ownerId: did('a'),
      crypto: FakeGroups({did('a'), did('b')}),
      network: left,
      signaling: QuietSeed(),
    );
    final bob = GroupTransport(
      ownerId: did('b'),
      crypto: FakeGroups({did('a'), did('b')}),
      network: right,
      signaling: QuietSeed(),
    );
    try {
      await left.addSeed(fixture.a);
      await right.addSeed(fixture.a);
      await alice.start();
      await bob.start();
      await alice.connect(did('b'));
      await fixture.until(
        () => alice.connected(did('b')) && bob.connected(did('a')),
      );
      left.send(fixture.a, {
        'type': 'route',
        'to': did('b'),
        'session': groupRandomId(),
        'packet': groupRandomId(),
        'body': {
          'type': 'group-v1',
          'frame': jsonEncode({
            'v': 1,
            't': 'noise',
            's': groupRandomId(),
            'step': 'start',
            'frame': 'invalid',
          }),
        },
      });
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(bob.connected(did('a')), isTrue);
      final received = <String>[];
      bob.frames.listen((f) => received.add(f.text));
      await alice.send(did('b'), 'still live');
      await fixture.until(() => received.contains('still live'));
    } finally {
      await alice.close();
      await bob.close();
      await left.close();
      await right.close();
    }
  });
  test(
    'crypto failure drops only affected ready group peer promptly',
    () async {
      final hub = fixture.Hub(fixture.a, 'relay-a');
      final networks = <RelayNetwork>[], transports = <GroupTransport>[];
      final cryptos = <FakeGroups>[];
      try {
        for (final key in ['a', 'b', 'c']) {
          final network = RelayNetwork(
            fixture.Crypto(did(key)),
            connector: hub.connect,
          );
          networks.add(network);
          await network.addSeed(fixture.a);
          final crypto = FakeGroups({'a', 'b', 'c'}.map(did).toSet());
          cryptos.add(crypto);
          final transport = GroupTransport(
            ownerId: did(key),
            crypto: crypto,
            network: network,
            signaling: QuietSeed(),
          );
          transports.add(transport);
          await transport.start();
        }
        await transports[0].connect(did('b'));
        await transports[0].connect(did('c'));
        await fixture.until(
          () =>
              transports[0].connected(did('b')) &&
              transports[0].connected(did('c')),
        );
        cryptos[0].failEncryptFor = did('b');
        await expectLater(
          transports[0].send(did('b'), 'fail'),
          throwsStateError,
        );
        expect(transports[0].connected(did('b')), isFalse);
        expect(transports[0].connected(did('c')), isTrue);
      } finally {
        for (final t in transports) {
          await t.close();
        }
        for (final n in networks) {
          await n.close();
        }
      }
    },
  );
}
