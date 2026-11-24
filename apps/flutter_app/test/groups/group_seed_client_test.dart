import 'dart:async';
import 'dart:convert';

import 'package:cht/account/account_bridge.dart';
import 'package:cht/account/account_models.dart';
import 'package:cht/groups/group_crypto_bridge.dart';
import 'package:cht/groups/group_seed_client.dart';
import 'package:cht/relay/relay_crypto_bridge.dart';
import 'package:cht/relay/relay_network.dart';
import 'package:cht/relay/relay_socket.dart';
import 'package:cht/seed/seed_client.dart' show seedId;
import 'package:cht/seed/seed_crypto_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

const owner =
    'did:cht:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const bob =
    'did:cht:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const carol =
    'did:cht:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
const session = '0123456789abcdef0123456789abcdef';
const sdp =
    'v=0\r\na=fingerprint:sha-256 AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB:AB\r\na=setup:actpass\r\n';

String id(String kind, int n) => 'cht-control-groups-v1-$session-$kind-$n';
String payload() => jsonEncode({'v': 1, 't': 'offer', 's': session, 'd': sdp});
Map<String, dynamic> envelope(
  String from,
  String messageId, {
  int expiry = 121000,
  String? topic,
  int version = 2,
}) => {
  'version': version,
  if (version == 2) 'topic': topic ?? 'groups',
  'from': from,
  'to': owner,
  'session': session,
  'id': messageId,
  'kind': 'offer',
  'payload': payload(),
  'issuedAt': 1000,
  'expiresAt': expiry,
  'publicKey': 'key',
  'signature': 'valid',
};

Future<void> settle() async {
  for (var i = 0; i < 15; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class FakeAccount implements AccountBridge {
  String active = owner;
  @override
  Future<IdentityView> identity() async => IdentityView(
    id: active,
    rootPublicKey: '',
    noiseStaticPublicKey: '',
    derivationVersion: 1,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeCrypto
    implements GroupCryptoBridge, RelayCryptoBridge, SeedDispatchCryptoBridge {
  @override
  Future<String> signSeedDispatch(
    String seedId,
    String connection,
    int sequence,
    String envelopeJson,
  ) async => jsonEncode({'sequence': sequence, 'connection': connection});
  Completer<Map<String, Object?>>? signGate, inspectGate;
  int inspected = 0, signed = 0;
  @override
  Future<Map<String, Object?>> groupCall(
    String op,
    Map<String, Object?> args,
  ) async {
    if (op == 'signSignal') {
      signed++;
      if (signGate != null) return signGate!.future;
      final text = args['text'] as String;
      return {
        'source': jsonEncode(
          envelope(owner, args['id'] as String)
            ..['to'] = args['peerId']
            ..['payload'] = text,
        ),
      };
    }
    if (op == 'inspectSignal') {
      inspected++;
      if (inspectGate != null) return inspectGate!.future;
      final e = jsonDecode(args['source'] as String) as Map;
      if (e['signature'] != 'valid' || e['from'] != args['expectedPeer']) {
        throw StateError('untrusted');
      }
      return {'peerId': e['from'], 'messageId': e['id'], 'text': e['payload']};
    }
    throw StateError(op);
  }

  @override
  Future<String> relayProof(String nonce, String relayId) async =>
      jsonEncode({'identityId': owner});
  @override
  Future<String> inspectRelayRecord(
    String source,
    int now,
    bool loopback,
  ) async => source;
  @override
  Future<String> loadRelayState() async => '';
  @override
  Future<void> saveRelayState(String source) async {}
}

class FakeSocket implements RelaySocket {
  final input = StreamController<String>();
  final sent = <Map<String, dynamic>>[];
  bool closed = false;
  @override
  Stream<String> get frames => input.stream;
  void receive(Map<String, dynamic> frame) => input.add(jsonEncode(frame));
  @override
  void send(String frame) {
    if (closed) throw StateError('closed');
    sent.add(jsonDecode(frame) as Map<String, dynamic>);
  }

  @override
  Future<void> close() async {
    closed = true;
    await input.close();
  }
}

void main() {
  late FakeAccount account;
  late FakeCrypto crypto;
  late FakeSocket socket;
  late RelayNetwork network;
  late GroupSeedClient client;
  late int now;
  setUp(() {
    now = 1000;
    account = FakeAccount();
    crypto = FakeCrypto();
    socket = FakeSocket();
    network = RelayNetwork(
      crypto,
      connector: (_) async => FakeSocket(),
      clock: () => now,
    );
    client = GroupSeedClient(
      account: account,
      relayCrypto: crypto,
      crypto: crypto,
      network: network,
      connector: (_) => Future.value(socket),
      clock: () => now,
    );
  });
  tearDown(() async {
    await client.close();
    await network.close();
  });
  Future<void> register({bool upgraded = false}) async {
    await client.start(owner);
    socket.receive({
      'type': 'challenge',
      'protocol': 'chta-seed',
      'version': 1,
      'seedId': seedId,
      'nonce': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      if (upgraded) 'capabilities': ['session-dispatch-v1'],
    });
    await settle();
    socket.receive({
      'type': 'registered',
      'protocol': 'chta-seed',
      'version': 1,
    });
    await settle();
  }

  test(
    'group negotiations use the negotiated connection dispatch capability',
    () async {
      await register(upgraded: true);
      await client.send(bob, id('offer', 1), payload());
      expect((socket.sent.last['dispatch'] as Map)['sequence'], 1);
      expect((socket.sent.last['envelope'] as Map)['topic'], 'groups');
    },
  );
  test(
    'one socket dispatches independent signals from two authorized peers',
    () async {
      await register();
      final got = <GroupSeedSignal>[];
      final sub = client.signals.listen(got.add);
      socket.receive({
        'type': 'signal',
        'envelope': envelope(bob, id('offer', 1)),
      });
      socket.receive({
        'type': 'signal',
        'envelope': envelope(carol, id('offer', 2)),
      });
      await settle();
      expect(got.map((e) => e.peerId), [bob, carol]);
      expect(crypto.inspected, 2);
      await sub.cancel();
    },
  );
  test('v1, wrong topic and content never reach crypto', () async {
    await register();
    socket.receive({
      'type': 'signal',
      'envelope': envelope(bob, id('offer', 1), version: 1),
    });
    socket.receive({
      'type': 'signal',
      'envelope': envelope(bob, id('offer', 2), topic: 'direct'),
    });
    await settle();
    expect(crypto.inspected, 0);
    await expectLater(
      client.send(bob, 'chat-1', 'secret'),
      throwsFormatException,
    );
    expect(crypto.signed, 0);
  });
  test('duplicate signal is delivered once and invalid signature does not close peers', () async {
    await register();
    final got = <GroupSeedSignal>[];
    final sub = client.signals.listen(got.add);
    final valid = envelope(bob, id('offer', 1));
    socket.receive({
      'type': 'signal',
      'envelope': {...valid, 'signature': 'forged'},
    });
    socket.receive({'type': 'signal', 'envelope': valid});
    socket.receive({'type': 'signal', 'envelope': valid});
    socket.receive({
      'type': 'signal',
      'envelope': envelope(carol, id('offer', 2)),
    });
    await settle();
    expect(got.map((e) => e.peerId), [bob, carol]);
    expect(client.registered, isTrue);
    await sub.cancel();
  });
  test(
    'send signs only after registration and resolves when flushed',
    () async {
      await client.start(owner);
      final pending = client.send(bob, id('offer', 1), payload());
      await settle();
      expect(crypto.signed, 0);
      socket.receive({
        'type': 'challenge',
        'protocol': 'chta-seed',
        'version': 1,
        'seedId': seedId,
        'nonce': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      });
      await settle();
      socket.receive({
        'type': 'registered',
        'protocol': 'chta-seed',
        'version': 1,
      });
      await pending;
      expect(crypto.signed, 1);
      expect(socket.sent.where((f) => f['type'] == 'signal'), hasLength(1));
    },
  );
  test('close while signing rejects pending send', () async {
    await register();
    crypto.signGate = Completer();
    final pending = expectLater(
      client.send(bob, id('offer', 1), payload()),
      throwsStateError,
    );
    await settle();
    await client.close();
    crypto.signGate!.complete({
      'source': jsonEncode(envelope(owner, id('offer', 1))),
    });
    await pending;
    expect(socket.sent.where((f) => f['type'] == 'signal'), isEmpty);
  });
  test('identity switch while inspecting closes registration and suppresses signal', () async {
    await register();
    crypto.inspectGate = Completer();
    final got = <GroupSeedSignal>[];
    final sub = client.signals.listen(got.add);
    socket.receive({
      'type': 'signal',
      'envelope': envelope(bob, id('offer', 1)),
    });
    await settle();
    account.active = carol;
    crypto.inspectGate!.complete({
      'peerId': bob,
      'messageId': id('offer', 1),
      'text': payload(),
    });
    await settle();
    expect(got, isEmpty);
    expect(client.registered, isFalse);
    await sub.cancel();
  });
  test('bounded outgoing queue rejects overflow without signing', () async {
    await client.start(owner);
    final pending = <Future<void>>[];
    for (var i = 0; i < 128; i++) {
      pending.add(
        expectLater(
          client.send(bob, id('offer', i), payload()),
          throwsStateError,
        ),
      );
    }
    await expectLater(
      client.send(bob, id('offer', 129), payload()),
      throwsStateError,
    );
    expect(crypto.signed, 0);
    await client.close();
    await Future.wait(pending);
  });
}
