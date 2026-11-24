import 'dart:async';
import 'dart:convert';

import 'package:cht/account/account_models.dart';
import 'package:cht/account/account_bridge.dart';
import 'package:cht/relay/relay_crypto_bridge.dart';
import 'package:cht/relay/relay_network.dart';
import 'package:cht/relay/relay_socket.dart';
import 'package:cht/seed/seed_client.dart';
import 'package:cht/seed/seed_crypto_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

const owner =
    'did:cht:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const peer =
    'did:cht:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const other =
    'did:cht:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
ContactView contact(String id, {bool verified = true}) => ContactView(
  identityId: id,
  displayName: 'friend',
  fingerprint: 'test',
  verified: verified,
);
Future<void> flush() async {
  for (var i = 0; i < 12; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class Crypto
    implements SeedCryptoBridge, RelayCryptoBridge, SeedDispatchCryptoBridge {
  @override
  Future<String> signSeedDispatch(
    String seedId,
    String connection,
    int sequence,
    String envelopeJson,
  ) async => jsonEncode({'sequence': sequence, 'connection': connection});
  Completer<String>? gate;
  @override
  Future<String> relayProof(String nonce, String relayId) async =>
      jsonEncode({'identityId': owner});
  @override
  Future<String> signSeedSignal(
    String peerId,
    String messageId,
    String text,
    int now,
  ) async => jsonEncode({
    'from': owner,
    'to': peerId,
    'id': messageId,
    'payload': text,
    'signature': 'valid',
    'expiresAt': now + 1000,
  });
  @override
  Future<String> inspectSeedSignal(
    String source,
    String expectedPeer,
    int now,
  ) async {
    if (gate != null) return gate!.future;
    final e = jsonDecode(source) as Map;
    if (e['from'] != expectedPeer ||
        e['to'] != owner ||
        e['signature'] != 'valid' ||
        (e['expiresAt'] as int) <= now) {
      throw StateError('untrusted');
    }
    return jsonEncode({
      'peerId': e['from'],
      'messageId': e['id'],
      'text': e['payload'],
    });
  }

  @override
  Future<String> inspectRelayRecord(
    String source,
    int now,
    bool allowLoopback,
  ) async {
    final e = jsonDecode(source) as Map;
    if (e['signature'] != 'valid' || (e['expiresAt'] as int) <= now) {
      throw StateError('invalid');
    }
    return source;
  }

  @override
  Future<String> loadRelayState() async => '';
  @override
  Future<void> saveRelayState(String source) async {}
}

class Account implements AccountBridge {
  String active = owner;
  final savedContacts = <ContactView>[];
  @override
  Future<List<ContactView>> contacts() async => savedContacts;
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

class Socket implements RelaySocket {
  final input = StreamController<String>();
  final sent = <Map<String, dynamic>>[];
  bool closed = false;
  @override
  Stream<String> get frames => input.stream;
  void receive(Map<String, dynamic> frame) => input.add(jsonEncode(frame));
  @override
  void send(String frame) =>
      sent.add(jsonDecode(frame) as Map<String, dynamic>);
  @override
  Future<void> close() async {
    closed = true;
    unawaited(input.close());
  }
}

Map<String, dynamic> envelope({String from = peer, String id = 'control-1'}) =>
    {
      'from': from,
      'to': owner,
      'id': id,
      'payload': 'signal',
      'signature': 'valid',
      'expiresAt': 2000,
    };
void main() {
  test('Courier discovery negotiates capability and preserves legacy registration frames', () async {
    for (final capable in [false, true]) {
      final crypto = Crypto(),
          account = Account(),
          socket = Socket(),
          network = RelayNetwork(Crypto());
      final client = SeedClient(
        account: account,
        relayCrypto: crypto,
        signalCrypto: crypto,
        network: network,
        connector: (_) async => socket,
        clock: () => 1000,
      );
      final seen = <List<Object?>>[];
      final sub = client.courierRecords.listen(seen.add);
      await client.start(owner);
      socket.receive({
        'type': 'challenge',
        'protocol': 'chta-seed',
        'version': 1,
        'seedId': seedId,
        'nonce': 'A' * 43,
        'capabilities': capable ? ['courier-directory-v1'] : [],
      });
      await flush();
      socket.receive({
        'type': 'registered',
        'protocol': 'chta-seed',
        'version': 1,
      });
      await flush();
      client.publishCouriers([
        {'synthetic': 'metadata'},
      ]);
      expect(socket.sent.any((f) => f['type'] == 'couriers'), capable);
      if (capable) {
        socket.receive({
          'type': 'couriers',
          'records': [
            {'synthetic': 'untrusted'},
          ],
        });
        await flush();
        expect(seen.single.single, {'synthetic': 'untrusted'});
      }
      await sub.cancel();
      await client.close();
      await network.close();
    }
  });
  test('multi-peer signaling delivers authorized controls without switching selected room', () async {
    final crypto = Crypto(),
        account = Account()
          ..savedContacts.addAll([contact(peer), contact(other)]),
        socket = Socket();
    final network = RelayNetwork(crypto);
    final client = SeedClient(
      account: account,
      relayCrypto: crypto,
      signalCrypto: crypto,
      network: network,
      multiPeer: true,
      connector: (_) async => socket,
      clock: () => 1000,
    );
    final received = <SeedVerifiedSignal>[];
    final subscription = client.signals.listen(received.add);
    try {
      await client.start(owner);
      client.selectContact(contact(peer));
      socket.receive({
        'type': 'challenge',
        'protocol': 'chta-seed',
        'version': 1,
        'seedId': seedId,
        'nonce': 'A' * 43,
      });
      await flush();
      socket.receive({
        'type': 'registered',
        'protocol': 'chta-seed',
        'version': 1,
      });
      await flush();
      socket.receive({
        'type': 'signal',
        'envelope': envelope(from: other, id: 'other-answer'),
      });
      await flush();
      expect(received.single.peerId, other);
      expect(client.selectedPeer, peer);
      await client.sendPeerSignal(
        other,
        'cht-control-direct-v1-test',
        '{"v":1,"t":"ice"}',
      );
      expect((socket.sent.last['envelope'] as Map)['to'], other);
      account.savedContacts.removeWhere((c) => c.identityId == other);
      socket.receive({
        'type': 'signal',
        'envelope': envelope(from: other, id: 'removed'),
      });
      await flush();
      expect(received.length, 1);
      await expectLater(
        client.sendPeerSignal(
          other,
          'cht-control-direct-v1-test',
          '{"v":1,"t":"ice"}',
        ),
        throwsStateError,
      );
    } finally {
      await subscription.cancel();
      await client.close();
      await network.close();
    }
  });
  late Crypto crypto;
  late Socket socket;
  late RelayNetwork network;
  late SeedClient client;
  late Account account;
  late int now;
  setUp(() {
    now = 1000;
    crypto = Crypto();
    socket = Socket();
    network = RelayNetwork(
      crypto,
      connector: (_) async => Socket(),
      clock: () => now,
    );
    account = Account();
    client = SeedClient(
      account: account,
      relayCrypto: crypto,
      signalCrypto: crypto,
      network: network,
      connector: (_) async => socket,
      clock: () => now,
    );
  });
  tearDown(() async {
    await client.close();
    await network.close();
  });
  Future<void> register({bool upgraded = false}) async {
    await client.start(owner);
    client.selectContact(contact(peer));
    socket.receive({
      'type': 'challenge',
      'protocol': 'chta-seed',
      'version': 1,
      'seedId': seedId,
      'nonce': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      if (upgraded) 'capabilities': ['session-dispatch-v1'],
    });
    await flush();
    socket.receive({
      'type': 'registered',
      'protocol': 'chta-seed',
      'version': 1,
    });
    await flush();
  }

  test('updated seed wraps direct and contact sends in one monotonic dispatch stream', () async {
    await register(upgraded: true);
    await client.sendSignal(
      'cht-control-direct-v1-session-offer-1',
      jsonEncode({'v': 1, 't': 'offer'}),
    );
    await client.sendContactRequest({
      'version': 2,
      'topic': 'contacts',
      'from': owner,
      'to': other,
    });
    final frames = socket.sent.where((f) => f['type'] == 'signal').toList();
    expect(frames.map((f) => (f['dispatch'] as Map)['sequence']), [1, 2]);
  });
  test(
    'legacy quota failure has explicit status and stays backed off',
    () async {
      await register();
      socket.receive({
        'type': 'error',
        'code': 'storage-unavailable',
        'retryAfter': 300,
        'upgrade': 'session-dispatch-v1',
      });
      await flush();
      expect(client.registered, isFalse);
      expect(client.status, contains('update'));
    },
  );
  test('contact setup reaches its review stream without trusting or selecting an unknown peer', () async {
    await register();
    final packets = <Map<String, Object?>>[], chats = <SeedVerifiedSignal>[];
    final contactSub = client.contactRequests.listen(packets.add);
    final chatSub = client.signals.listen(chats.add);
    final packet = <String, Object?>{
      ...envelope(from: other),
      'version': 2,
      'topic': 'contacts',
    };
    socket.receive({'type': 'signal', 'envelope': packet});
    await flush();
    expect(packets, [packet]);
    expect(chats, isEmpty);
    expect(account.savedContacts, isEmpty);
    expect(client.selectedPeer, peer);
    expect(client.registered, isTrue);
    await contactSub.cancel();
    await chatSub.cancel();
  });
  test('contact send reuses the socket without changing the selected chat and checks owner', () async {
    await register();
    final packet = <String, Object?>{
      ...envelope(),
      'from': owner,
      'to': other,
      'version': 2,
      'topic': 'contacts',
    };
    await client.sendContactRequest(packet);
    expect(socket.sent.last, {'type': 'signal', 'envelope': packet});
    expect(client.selectedPeer, peer);
    await expectLater(
      client.sendContactRequest({...packet, 'from': other}),
      throwsStateError,
    );
    account.active = other;
    await expectLater(client.sendContactRequest(packet), throwsStateError);
  });

  test(
    'idle receiver adopts only a verified signed offer before emitting it',
    () async {
      await client.close();
      var adopted = 0;
      client = SeedClient(
        account: account,
        relayCrypto: crypto,
        signalCrypto: crypto,
        network: network,
        connector: (_) async => socket,
        clock: () => now,
        acceptIncomingPeer: (id) async {
          adopted++;
          client.selectContact(contact(id));
          return true;
        },
      );
      await register();
      client.selectContact(null);
      account.savedContacts.add(contact(peer));
      final got = <SeedVerifiedSignal>[];
      final sub = client.signals.listen(got.add);
      Map<String, dynamic> offer(String from) => {
        ...envelope(from: from),
        'payload': jsonEncode({'v': 1, 't': 'offer'}),
      };
      socket.receive({'type': 'signal', 'envelope': offer(other)});
      socket.receive({
        'type': 'signal',
        'envelope': {
          ...offer(peer),
          'payload': jsonEncode({'v': 1, 't': 'ice'}),
        },
      });
      await flush();
      expect(adopted, 0);
      socket.receive({'type': 'signal', 'envelope': offer(peer)});
      await flush();
      expect(adopted, 1);
      expect(client.selectedPeer, peer);
      expect(got, hasLength(1));
      await sub.cancel();
    },
  );

  test(
    'registers separately and only queries a verified selected contact',
    () async {
      await register();
      expect(client.registered, isTrue);
      expect(
        socket.sent.map((e) => e['type']),
        containsAll(['register', 'lookup']),
      );
      expect(network.seeds, isEmpty);
      client.selectContact(contact(other, verified: false));
      await flush();
      expect(client.selectedPeer, isNull);
      expect(socket.sent.where((e) => e['identityId'] == other), isEmpty);
    },
  );
  test('verified signal rejects wrong peer and replay', () async {
    await register();
    final got = <SeedVerifiedSignal>[];
    final sub = client.signals.listen(got.add);
    socket.receive({'type': 'signal', 'envelope': envelope(from: other)});
    socket.receive({'type': 'signal', 'envelope': envelope()});
    socket.receive({'type': 'signal', 'envelope': envelope()});
    await flush();
    expect(got, hasLength(1));
    expect(got.single.peerId, peer);
    await sub.cancel();
  });
  test(
    'peer and identity changes suppress work during crypto awaits',
    () async {
      await register();
      final got = <SeedVerifiedSignal>[];
      final sub = client.signals.listen(got.add);
      crypto.gate = Completer();
      socket.receive({'type': 'signal', 'envelope': envelope()});
      await flush();
      client.selectContact(contact(other));
      crypto.gate!.complete(
        jsonEncode({
          'peerId': peer,
          'messageId': 'control-1',
          'text': 'signal',
        }),
      );
      await flush();
      expect(got, isEmpty);
      await client.stop();
      expect(socket.closed, isTrue);
      expect(client.registered, isFalse);
      await sub.cancel();
    },
  );
  test('seed sends control only and never accepts content packets', () async {
    await register();
    await expectLater(
      client.sendSignal('chat-1', 'hello'),
      throwsFormatException,
    );
    await expectLater(
      client.sendSignal(
        'cht-control-direct-v1-bad-offer-1',
        jsonEncode({'v': 1, 't': 'packet', 'text': 'hello'}),
      ),
      throwsFormatException,
    );
    expect(socket.sent.where((e) => e['type'] == 'signal'), isEmpty);
    socket.receive({'type': 'message', 'text': 'hello'});
    await flush();
    expect(client.registered, isFalse);
  });
  test(
    'identity switch during signature validation closes registration',
    () async {
      await register();
      final got = <SeedVerifiedSignal>[];
      final sub = client.signals.listen(got.add);
      crypto.gate = Completer();
      socket.receive({'type': 'signal', 'envelope': envelope()});
      await flush();
      account.active = other;
      crypto.gate!.complete(
        jsonEncode({
          'peerId': peer,
          'messageId': 'control-1',
          'text': 'signal',
        }),
      );
      await flush();
      expect(got, isEmpty);
      expect(client.registered, isFalse);
      await sub.cancel();
    },
  );
  test(
    'socket disconnect reconnects and retains only selected verified peer',
    () async {
      await register();
      await socket.close();
      await flush();
      expect(client.registered, isFalse);
      socket = Socket();
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      socket.receive({
        'type': 'challenge',
        'protocol': 'chta-seed',
        'version': 1,
        'seedId': seedId,
        'nonce': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      });
      await flush();
      socket.receive({
        'type': 'registered',
        'protocol': 'chta-seed',
        'version': 1,
      });
      await flush();
      expect(client.registered, isTrue);
      expect(client.selectedPeer, peer);
      expect(
        socket.sent.where((f) => f['type'] == 'lookup').single['identityId'],
        peer,
      );
    },
  );
  test('same client restarts despite stale signature validation', () async {
    await register();
    crypto.gate = Completer();
    socket.receive({'type': 'signal', 'envelope': envelope()});
    await flush();
    await client.stop();
    socket = Socket();
    await client.start(owner);
    socket.receive({
      'type': 'challenge',
      'protocol': 'chta-seed',
      'version': 1,
      'seedId': seedId,
      'nonce': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    });
    await flush();
    socket.receive({
      'type': 'registered',
      'protocol': 'chta-seed',
      'version': 1,
    });
    await flush();
    expect(client.registered, isTrue);
    crypto.gate!.complete(
      jsonEncode({'peerId': peer, 'messageId': 'control-1', 'text': 'signal'}),
    );
    await flush();
  });
  test('catalog uses signature validation and never installs discovery as data relay', () async {
    await register();
    socket.receive({
      'type': 'catalog',
      'records': [
        {
          'relayId': 'bad',
          'endpoint': 'wss://public.example/cht',
          'expiresAt': 2000,
          'signature': 'forged',
        },
        {
          'relayId': 'seed',
          'endpoint': 'wss://chta.app/relay',
          'expiresAt': 2000,
          'signature': 'valid',
        },
        {
          'relayId': 'expired',
          'endpoint': 'wss://public.example/cht',
          'expiresAt': 999,
          'signature': 'valid',
        },
      ],
    });
    await flush();
    expect(network.records, isEmpty);
    expect(network.seeds, isEmpty);
  });
  test(
    'catalog publishes bounded rotating batches and ignores expired records',
    () async {
      for (var i = 0; i < 64; i++) {
        network.records['relay-$i'] = {
          'relayId': 'relay-$i',
          'endpoint': 'wss://r$i.example.com/cht',
          'issuedAt': 0,
          'expiresAt': 2000,
          'signature': 'valid',
          'publicKey': List.filled(1000, 'a').join(),
        };
      }
      network.records['expired'] = {
        'relayId': 'expired',
        'endpoint': 'wss://expired.example.com/cht',
        'issuedAt': 0,
        'expiresAt': 999,
        'signature': 'valid',
      };
      await register();
      final catalogs = socket.sent
          .where((f) => f['type'] == 'catalog')
          .toList();
      expect(catalogs, isNotEmpty);
      expect((catalogs.single['records'] as List), hasLength(lessThan(64)));
      expect(
        utf8.encode(jsonEncode(catalogs.single)).length,
        lessThanOrEqualTo(16384),
      );
      expect(
        (catalogs.single['records'] as List).where(
          (r) => (r as Map)['relayId'] == 'expired',
        ),
        isEmpty,
      );
    },
  );
  test('presence expires and cannot describe an unselected contact', () async {
    await register();
    socket.receive({'type': 'presence', 'identityId': other, 'online': true});
    await flush();
    expect(client.peerOnline, isFalse);
    socket.receive({'type': 'presence', 'identityId': peer, 'online': true});
    await flush();
    expect(client.peerOnline, isTrue);
    now += 30001;
    expect(client.peerOnline, isFalse);
  });
  test('signals expiring during verification are never dispatched', () async {
    await register();
    final got = <SeedVerifiedSignal>[];
    final subscription = client.signals.listen(got.add);
    crypto.gate = Completer();
    socket.receive({'type': 'signal', 'envelope': envelope()});
    await flush();
    now = 2001;
    crypto.gate!.complete(
      jsonEncode({'peerId': peer, 'messageId': 'control-1', 'text': 'signal'}),
    );
    await flush();
    expect(got, isEmpty);
    await subscription.cancel();
  });
  testWidgets('idle identity changes stop seed before the next heartbeat', (
    tester,
  ) async {
    final idleSocket = Socket();
    final idle = SeedClient(
      account: account,
      relayCrypto: crypto,
      signalCrypto: crypto,
      network: network,
      connector: (_) async => idleSocket,
      clock: () => now,
    );
    await idle.start(owner);
    idleSocket.receive({
      'type': 'challenge',
      'protocol': 'chta-seed',
      'version': 1,
      'seedId': seedId,
      'nonce': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    });
    await tester.pump();
    idleSocket.receive({
      'type': 'registered',
      'protocol': 'chta-seed',
      'version': 1,
    });
    await tester.pump();
    expect(idle.registered, isTrue);
    account.active = other;
    await tester.pump(const Duration(seconds: 15));
    await tester.pump();
    expect(idle.registered, isFalse);
    expect(idleSocket.closed, isTrue);
    await idle.close();
    await tester.pump(const Duration(seconds: 5));
  });
  test('overlapping starts open only the latest owner socket', () async {
    final sockets = <Socket>[];
    final racing = SeedClient(
      account: account,
      relayCrypto: crypto,
      signalCrypto: crypto,
      network: network,
      connector: (_) async {
        final s = Socket();
        sockets.add(s);
        return s;
      },
      clock: () => now,
    );
    final first = racing.start(owner);
    final latest = racing.start(other);
    await first;
    await latest;
    expect(sockets, hasLength(1));
    await racing.close();
  });
}
