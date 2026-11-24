import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:cht/account/account_bridge.dart';
import 'package:cht/account/account_models.dart';
import 'package:cht/groups/group_crypto_bridge.dart';
import 'package:cht/relay/relay_chat.dart';
import 'package:cht/relay/relay_crypto_bridge.dart';
import 'package:cht/relay/relay_network.dart';
import 'package:cht/relay/relay_socket.dart';
import 'package:cht/p2p/p2p_bridge.dart';

const a = 'wss://a.example.com/cht';
const b = 'wss://b.example.com/cht';
Future<void> until(bool Function() test) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!test()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for relay state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

class Crypto implements RelayCryptoBridge {
  Crypto(this.id);
  final String id;
  String cache = '';
  @override
  Future<String> loadRelayState() async => cache;
  @override
  Future<void> saveRelayState(String source) async {
    cache = source;
  }

  @override
  Future<String> relayProof(String nonce, String relayId) async =>
      jsonEncode({'identityId': id});
  @override
  Future<String> inspectRelayRecord(
    String source,
    int now,
    bool allowLoopback,
  ) async {
    final value = jsonDecode(source) as Map;
    if (value['signature'] != 'test-valid' ||
        (value['expiresAt'] as int) <= now) {
      throw StateError('Invalid signature or expired');
    }
    return source;
  }
}

class Socket implements RelaySocket {
  Socket(this.hub);
  final Hub hub;
  final controller = StreamController<String>();
  String? identity;
  bool closed = false;
  bool subscribed = false;
  @override
  Stream<String> get frames => controller.stream;
  void receive(Map<String, dynamic> value) {
    if (!closed) controller.add(jsonEncode(value));
  }

  @override
  void send(String source) {
    if (closed || hub.offline) throw StateError('Offline');
    final frame = jsonDecode(source) as Map<String, dynamic>;
    if (frame['type'] == 'register') {
      subscribed = frame['subscribeCatalog'] != false;
      identity = (frame['proof'] as Map)['identityId'] as String;
      receive({'type': 'registered'});
    }
    if (frame['type'] == 'keepalive') receive({'type': 'alive'});
    if (frame['type'] == 'route') {
      final destination = hub.sockets
          .where((s) => !s.closed && s.identity == frame['to'])
          .firstOrNull;
      if (destination == null) {
        receive({
          'type': 'unreachable',
          'to': frame['to'],
          'session': frame['session'],
        });
      } else {
        destination.receive({...frame, 'from': identity});
      }
    }
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    unawaited(controller.close());
  }
}

class Hub {
  Hub(this.url, this.id);
  final String url;
  final String id;
  bool offline = false;
  final sockets = <Socket>[];
  List<Map<String, dynamic>> catalog = [];
  Map<String, dynamic> get record => {
    'relayId': id,
    'endpoint': url,
    'issuedAt': 1,
    'expiresAt': DateTime.now()
        .add(const Duration(hours: 1))
        .millisecondsSinceEpoch,
    'signature': 'test-valid',
  };
  Future<RelaySocket> connect(String endpoint) async {
    if (offline) throw StateError('Offline');
    final socket = Socket(this);
    sockets.add(socket);
    socket.receive({
      'type': 'challenge',
      'nonce': 'challenge',
      'relay': record,
      'relays': catalog,
    });
    return socket;
  }

  Future<void> stop() async {
    offline = true;
    for (final socket in sockets) {
      await socket.close();
    }
  }
}

/// Enforces ordered counters so the client cannot silently stripe one Noise
/// session across multiple relay connections. Actual crypto is tested in Rust.
class Account implements AccountBridge {
  Account(this.id, this.friend);
  final String id;
  final String friend;
  bool trusted = true;
  int sent = 0;
  int received = 0;
  Completer<void>? decryptGate;
  Completer<void>? decryptEntered;
  Completer<void>? encryptGate;
  Completer<void>? encryptEntered;
  @override
  Future<IdentityView> identity() async => IdentityView(
    id: id,
    rootPublicKey: '',
    noiseStaticPublicKey: '',
    derivationVersion: 1,
  );
  @override
  Future<List<ContactView>> contacts() async => trusted
      ? [
          ContactView(
            identityId: friend,
            displayName: friend,
            fingerprint: '',
            verified: true,
          ),
        ]
      : [];
  @override
  Future<ContactView> inspectContactCard(String source) async => ContactView(
    identityId: source,
    displayName: source,
    fingerprint: '',
    verified: true,
  );
  @override
  Future<String> preparePeer(String cardJson, bool initiator) async {
    sent = 0;
    received = 0;
    return friend;
  }

  @override
  Future<String> startPeerHandshake() async => 'start';
  @override
  Future<Map<String, Object?>> receivePeerHandshake(String source) async =>
      source == 'start'
      ? {'established': true, 'reply': 'reply'}
      : {'established': true};
  @override
  Future<String> encryptPeerMessage(
    String id,
    String text, {
    int? sentAtMilliseconds,
  }) async {
    encryptEntered?.complete();
    await encryptGate?.future;
    return jsonEncode({
      'counter': sent++,
      'messageId': id,
      'text': text,
      'sentAtMilliseconds': sentAtMilliseconds,
    });
  }

  @override
  Future<Map<String, Object?>> decryptPeerMessage(String source) async {
    decryptEntered?.complete();
    await decryptGate?.future;
    final value = (jsonDecode(source) as Map).cast<String, Object?>();
    if (value['counter'] != received++) throw StateError('Out of order');
    return value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class SessionAccount extends Account implements GroupCryptoBridge {
  SessionAccount(super.id, super.friend, {this.staleSavedCapabilities = false});
  final bool staleSavedCapabilities;
  final sessions = <String, (int, int)>{};
  @override
  Future<List<ContactView>> contacts() async => trusted
      ? [
          if (staleSavedCapabilities)
            ContactView(
              identityId: friend,
              displayName: friend,
              fingerprint: '',
              verified: true,
            )
          else
            await inspectContactCard(friend),
        ]
      : [];
  @override
  Future<ContactView> inspectContactCard(String source) async => ContactView(
    identityId: source,
    displayName: source,
    fingerprint: '',
    verified: true,
    capabilities: const ['peer-sessions-v2'],
  );
  @override
  Future<Map<String, Object?>> groupCall(
    String operation,
    Map<String, Object?> args,
  ) async {
    expect(args['context'], 'dm-v2');
    expect(args['peerId'], friend);
    final session = args['sessionId'] as String;
    switch (operation) {
      case 'prepare':
        sessions[session] = (0, 0);
        return {};
      case 'start':
        return {'frame': 'start'};
      case 'handshake':
        if (!sessions.containsKey(session)) throw StateError('No session');
        return args['frame'] == 'start'
            ? {'reply': 'reply', 'established': true}
            : args['frame'] == 'reply'
            ? {'established': true}
            : throw const FormatException('Bad handshake');
      case 'encrypt':
        final (sent, received) = sessions[session]!;
        sessions[session] = (sent + 1, received);
        return {
          'frame': jsonEncode({
            'counter': sent,
            'id': args['id'],
            'text': args['text'],
          }),
        };
      case 'decrypt':
        decryptEntered?.complete();
        await decryptGate?.future;
        final value = jsonDecode(args['frame'] as String) as Map;
        final (sent, received) = sessions[session]!;
        if (value['counter'] != received) throw StateError('Out of order');
        sessions[session] = (sent, received + 1);
        return {'id': value['id'] as String, 'text': value['text'] as String};
      case 'closeSession':
        sessions.remove(session);
        return {};
      default:
        throw UnimplementedError(operation);
    }
  }
}

void main() {
  test('new Courier catalogs require negotiated support and never replace private routed-frame handlers', () async {
    final hub = Hub(a, 'relay-a'),
        network = RelayNetwork(
          Crypto('did:cht:${'a' * 64}'),
          connector: hub.connect,
        );
    final seen = <List<Object?>>[];
    final sub = network.courierRecords.listen(seen.add);
    await network.initialize();
    await network.addContactRoutes([a]);
    await until(() => network.online.isNotEmpty);
    network.publishCouriers([
      {'hint': 'not sent to legacy relay'},
    ]);
    expect(hub.sockets.single.closed, isFalse);
    await sub.cancel();
    await network.close();
  });
  test('file send guards persist across lost-ACK relay retries', () async {
    final hub = Hub(a, 'relay-a');
    final left = RelayNetwork(Crypto('alice'), connector: hub.connect);
    final right = RelayNetwork(Crypto('bob'), connector: hub.connect);
    var now = 100000, allowed = true;
    final alice = RelayChat(
      Account('alice', 'bob'),
      left,
      ownCard: () async => 'alice',
      clock: () => now,
    );
    final bob = RelayChat(
      Account('bob', 'alice'),
      right,
      ownCard: () async => 'bob',
    );
    try {
      await left.addSeed(a);
      await right.addSeed(a);
      alice.select('bob');
      bob.select('alice');
      await until(() => alice.authenticated && bob.authenticated);
      await alice.sendMessage(
        'file-packet',
        'file data',
        123,
        isCurrent: () => allowed,
      );
      alice.drainEvents();
      allowed = false;
      now += 5000;
      await alice.tick();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        alice.drainEvents().where(
          (e) => e.type == 'sent' && e.messageId == 'file-packet',
        ),
        isEmpty,
      );
      expect(alice.authenticated, isTrue);
      await alice.sendMessage('text-after-pause', 'text', 124);
      await until(
        () => bob.events.any((e) => e.messageId == 'text-after-pause'),
      );
    } finally {
      await alice.close();
      await bob.close();
    }
  });
  test(
    'resume keeps a healthy socket; a network handover replaces it',
    () async {
      final hub = Hub(a, 'relay-a');
      final network = RelayNetwork(Crypto('alice'), connector: hub.connect);
      try {
        await network.addSeed(a);
        await until(() => network.online.contains(a));
        final original = hub.sockets.single;
        await network.recoverNetwork(force: false);
        expect(original.closed, isFalse);
        expect(hub.sockets.length, 1);
        await network.recoverNetwork();
        await until(
          () => hub.sockets.length == 2 && network.online.contains(a),
        );
        expect(original.closed, isTrue);
      } finally {
        await network.close();
      }
    },
  );
  test(
    'upgraded saved contacts use fresh v2 cards and ignore unproven probe',
    () async {
      final hub = Hub(a, 'relay-a');
      final left = RelayNetwork(Crypto('alice'), connector: hub.connect);
      final right = RelayNetwork(Crypto('bob'), connector: hub.connect);
      final alice = RelayChat(
        SessionAccount('alice', 'bob', staleSavedCapabilities: true),
        left,
        ownCard: () async => 'alice',
      );
      final bob = RelayChat(
        SessionAccount('bob', 'alice', staleSavedCapabilities: true),
        right,
        ownCard: () async => 'bob',
      );
      try {
        await left.addSeed(a);
        await right.addSeed(a);
        alice.select('bob');
        bob.select('alice');
        await until(() => alice.authenticated && bob.authenticated);
        alice.drainEvents();
        right.send(a, {
          'type': 'route',
          'to': 'alice',
          'session': RelayChat.randomId(),
          'packet': RelayChat.randomId(),
          'body': {'type': 'probe', 'contactCard': 'bob'},
        });
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(alice.authenticated, isTrue);
        expect(alice.state, 'connected');
        expect(
          alice.drainEvents().where((e) => e.type == 'connection'),
          isEmpty,
        );
        await bob.sendMessage('still-live', 'hello', 123);
        await until(() => alice.events.any((e) => e.messageId == 'still-live'));
      } finally {
        await alice.close();
        await bob.close();
      }
    },
  );

  test('peer restart promotes v2 candidate without connecting state', () async {
    final hub = Hub(a, 'relay-a');
    final left = RelayNetwork(Crypto('alice'), connector: hub.connect);
    final right = RelayNetwork(Crypto('bob'), connector: hub.connect);
    final alice = RelayChat(
      SessionAccount('alice', 'bob'),
      left,
      ownCard: () async => 'alice',
    );
    final bob = RelayChat(
      SessionAccount('bob', 'alice'),
      right,
      ownCard: () async => 'bob',
    );
    try {
      await left.addSeed(a);
      await right.addSeed(a);
      alice.select('bob');
      bob.select('alice');
      await until(() => alice.authenticated && bob.authenticated);
      alice.drainEvents();
      bob.disconnectPeer();
      bob.select('alice');
      await until(() => alice.authenticated && bob.authenticated);
      expect(alice.state, 'connected');
      expect(
        alice.drainEvents().where(
          (e) => e.type == 'connection' && e.state == 'connecting',
        ),
        isEmpty,
      );
      await bob.sendMessage('after-restart', 'hello', 123);
      await until(
        () => alice.events.any((e) => e.messageId == 'after-restart'),
      );
    } finally {
      await alice.close();
      await bob.close();
    }
  });

  test(
    'bad and expired candidate handshakes leave live v2 session intact',
    () async {
      final hub = Hub(a, 'relay-a');
      final left = RelayNetwork(Crypto('alice'), connector: hub.connect);
      final right = RelayNetwork(Crypto('bob'), connector: hub.connect);
      final aliceAccount = SessionAccount('alice', 'bob');
      var time = DateTime.now().millisecondsSinceEpoch;
      final alice = RelayChat(
        aliceAccount,
        left,
        ownCard: () async => 'alice',
        clock: () => time,
      );
      final bob = RelayChat(
        SessionAccount('bob', 'alice'),
        right,
        ownCard: () async => 'bob',
      );
      try {
        await left.addSeed(a);
        await right.addSeed(a);
        alice.select('bob');
        bob.select('alice');
        await until(() => alice.authenticated && bob.authenticated);
        alice.drainEvents();
        Future<void> probe(String session) async {
          right.send(a, {
            'type': 'route',
            'to': 'alice',
            'session': session,
            'packet': RelayChat.randomId(),
            'body': {'type': 'probe', 'contactCard': 'bob'},
          });
          await until(() => aliceAccount.sessions.containsKey(session));
        }

        final bad = RelayChat.randomId();
        await probe(bad);
        right.send(a, {
          'type': 'route',
          'to': 'alice',
          'session': bad,
          'packet': RelayChat.randomId(),
          'body': {'type': 'noise', 'payload': 'invalid'},
        });
        await until(() => !aliceAccount.sessions.containsKey(bad));
        final expired = RelayChat.randomId();
        await probe(expired);
        time += 16000;
        await alice.tick();
        await until(() => !aliceAccount.sessions.containsKey(expired));
        expect(alice.authenticated, isTrue);
        expect(alice.state, 'connected');
        expect(
          alice.drainEvents().where((e) => e.type == 'connection'),
          isEmpty,
        );
        await bob.sendMessage('still-live', 'hello', 123);
        await until(() => alice.events.any((e) => e.messageId == 'still-live'));
      } finally {
        await alice.close();
        await bob.close();
      }
    },
  );
  test(
    'v2 decrypt finishing after peer switch cannot deliver old message',
    () async {
      final hub = Hub(a, 'relay-a');
      final left = RelayNetwork(Crypto('alice'), connector: hub.connect);
      final right = RelayNetwork(Crypto('bob'), connector: hub.connect);
      final aliceAccount = SessionAccount('alice', 'bob');
      final alice = RelayChat(aliceAccount, left, ownCard: () async => 'alice');
      final bob = RelayChat(
        SessionAccount('bob', 'alice'),
        right,
        ownCard: () async => 'bob',
      );
      try {
        await left.addSeed(a);
        await right.addSeed(a);
        alice.select('bob');
        bob.select('alice');
        await until(() => alice.authenticated && bob.authenticated);
        aliceAccount.decryptGate = Completer<void>();
        aliceAccount.decryptEntered = Completer<void>();
        await bob.sendMessage('stale-v2', 'old peer', 123);
        await aliceAccount.decryptEntered!.future;
        alice.select('carol');
        aliceAccount.decryptGate!.complete();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(alice.events.where((e) => e.messageId == 'stale-v2'), isEmpty);
        expect(alice.authenticated, isFalse);
      } finally {
        await alice.close();
        await bob.close();
      }
    },
  );
  test(
    'v1 fallback ignores delayed probe and still handles heartbeat',
    () async {
      final hub = Hub(a, 'relay-a');
      final left = RelayNetwork(Crypto('alice'), connector: hub.connect);
      final right = RelayNetwork(Crypto('bob'), connector: hub.connect);
      final aliceAccount = Account('alice', 'bob');
      var time = DateTime.now().millisecondsSinceEpoch;
      final alice = RelayChat(
        aliceAccount,
        left,
        ownCard: () async => 'alice',
        clock: () => time,
      );
      final bob = RelayChat(
        Account('bob', 'alice'),
        right,
        ownCard: () async => 'bob',
      );
      try {
        await left.addSeed(a);
        await right.addSeed(a);
        alice.select('bob');
        bob.select('alice');
        await until(() => alice.authenticated && bob.authenticated);
        alice.drainEvents();
        right.send(a, {
          'type': 'route',
          'to': 'alice',
          'session': RelayChat.randomId(),
          'packet': RelayChat.randomId(),
          'body': {'type': 'probe', 'contactCard': 'bob'},
        });
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(alice.authenticated, isTrue);
        time += 21000;
        await alice.tick();
        await until(() => aliceAccount.received > 0);
        expect(alice.authenticated, isTrue);
        expect(
          alice.drainEvents().where((e) => e.type == 'connection'),
          isEmpty,
        );
      } finally {
        await alice.close();
        await bob.close();
      }
    },
  );
  test(
    'clearing deleted chat pending send does not reset live relay session',
    () async {
      final hub = Hub(a, 'relay-a');
      final left = RelayNetwork(Crypto('alice'), connector: hub.connect);
      final right = RelayNetwork(Crypto('bob'), connector: hub.connect);
      final account = Account('alice', 'bob');
      final alice = RelayChat(account, left, ownCard: () async => 'alice');
      final bob = RelayChat(
        Account('bob', 'alice'),
        right,
        ownCard: () async => 'bob',
      );
      try {
        await left.addSeed(a);
        await right.addSeed(a);
        alice.select('bob');
        bob.select('alice');
        await until(() => alice.authenticated && bob.authenticated);
        account.encryptGate = Completer<void>();
        account.encryptEntered = Completer<void>();
        final send = alice.sendMessage('delete-pending', 'private', 123);
        await account.encryptEntered!.future;
        alice.cancelPendingFor('wrong-peer');
        alice.cancelPendingFor('bob');
        account.encryptGate!.complete();
        await expectLater(send, throwsStateError);
        expect(alice.authenticated, isTrue);
        await alice.tick();
        expect(
          bob.events.where((e) => e.messageId == 'delete-pending'),
          isEmpty,
        );
      } finally {
        await alice.close();
        await bob.close();
      }
    },
  );
  test(
    'group subscribers coexist with legacy relay callback and detach',
    () async {
      final hub = Hub(a, 'relay-a');
      final left = RelayNetwork(Crypto('alice'), connector: hub.connect);
      final right = RelayNetwork(Crypto('bob'), connector: hub.connect);
      var legacy = 0, groups = 0;
      void listener(String endpoint, Map<String, dynamic> frame) {
        groups++;
      }

      right.onFrame = (_, _) => legacy++;
      right.addFrameListener(listener);
      try {
        await left.addSeed(a);
        await right.addSeed(a);
        await until(() => left.online.isNotEmpty && right.online.isNotEmpty);
        left.send(a, {
          'type': 'route',
          'to': 'bob',
          'session': '0' * 32,
          'packet': '1' * 32,
          'body': {'type': 'group-v1'},
        });
        await until(() => groups == 1);
        expect(legacy, 1);
        right.removeFrameListener(listener);
        left.send(a, {
          'type': 'route',
          'to': 'bob',
          'session': '0' * 32,
          'packet': '2' * 32,
          'body': {'type': 'group-v1'},
        });
        await until(() => legacy == 2);
        expect(groups, 1);
      } finally {
        await left.close();
        await right.close();
      }
    },
  );

  test('in-flight decrypted message cannot survive a peer switch', () async {
    final hub = Hub(a, 'relay-a');
    final netA = RelayNetwork(Crypto('alice'), connector: hub.connect);
    final netB = RelayNetwork(Crypto('bob'), connector: hub.connect);
    final account = Account('alice', 'bob');
    final alice = RelayChat(account, netA, ownCard: () async => 'alice');
    final bob = RelayChat(
      Account('bob', 'alice'),
      netB,
      ownCard: () async => 'bob',
    );
    try {
      await netA.addSeed(a);
      await netB.addSeed(a);
      alice.select('bob');
      bob.select('alice');
      await until(() => alice.authenticated && bob.authenticated);
      account.decryptGate = Completer<void>();
      account.decryptEntered = Completer<void>();
      await bob.sendMessage('stale-text', 'old peer', 1234);
      await account.decryptEntered!.future;
      alice.select('carol');
      account.decryptGate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        alice.events.where((event) => event.messageId == 'stale-text'),
        isEmpty,
      );
      expect(alice.authenticated, isFalse);
    } finally {
      await alice.close();
      await bob.close();
    }
  });
  test(
    'queued message is rejected before encryption under another peer',
    () async {
      final account = Account('alice', 'bob');
      final network = RelayNetwork(
        Crypto('alice'),
        connector: Hub(a, 'relay-a').connect,
      );
      final chat = RelayChat(account, network, ownCard: () async => 'alice');
      chat.select('bob');
      chat.authenticated = true;
      final send = chat.sendMessage('stale-text', 'private', 1234);
      chat.select('carol');
      chat.authenticated = true;
      await expectLater(send, throwsStateError);
      expect(account.sent, 0);
      await chat.close();
    },
  );
  test('changing peer discards previously decrypted queued events', () async {
    final network = RelayNetwork(
      Crypto('alice'),
      connector: Hub(a, 'relay-a').connect,
    );
    final chat = RelayChat(
      Account('alice', 'bob'),
      network,
      ownCard: () async => 'alice',
    );
    chat.select('bob');
    chat.events.add(
      const PeerEvent(type: 'message', messageId: 'old', text: 'old peer'),
    );
    chat.select('carol');
    expect(chat.drainEvents().where((e) => e.type == 'message'), isEmpty);
    await chat.close();
  });
  test(
    'new friend request requires explicit approval before a secure session',
    () async {
      final hub = Hub(a, 'relay-a');
      final netA = RelayNetwork(Crypto('alice'), connector: hub.connect);
      final netB = RelayNetwork(Crypto('bob'), connector: hub.connect);
      final accountB = Account('bob', 'alice')..trusted = false;
      var requests = 0;
      final alice = RelayChat(
        Account('alice', 'bob'),
        netA,
        ownCard: () async => 'alice',
      );
      final bob = RelayChat(
        accountB,
        netB,
        ownCard: () async => 'bob',
        onFriendRequest: (card, contact) {
          requests++;
          expect(card, 'alice');
        },
      );
      try {
        await netA.initialize();
        await netB.initialize();
        await netA.addSeed(a);
        await netB.addSeed(a);
        await until(() => netA.online.isNotEmpty && netB.online.isNotEmpty);
        alice.select('bob');
        await until(() => requests == 1);
        expect(alice.authenticated, isFalse);
        expect(bob.authenticated, isFalse);
        for (var i = 0; i < 10; i++) {
          bob.acceptFrame(a, {
            'type': 'route',
            'from': 'alice',
            'session': RelayChat.randomId(),
            'packet': RelayChat.randomId(),
            'body': {'type': 'probe', 'contactCard': 'alice'},
          });
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(requests, 1);
        accountB.trusted = true;
        bob.select('alice');
        await until(() => alice.authenticated && bob.authenticated);
        await alice.sendMessage('approved', 'hello after approval', 123);
        await until(() => bob.events.any((e) => e.messageId == 'approved'));
      } finally {
        await alice.close();
        await bob.close();
      }
    },
  );
  test('50–1000 simultaneous relay sockets, six pending dials, saved target and active route protection', () async {
    final hubs = List.generate(
      1000,
      (i) => Hub(
        'wss://r$i.example.com/cht',
        'relay-${i.toString().padLeft(4, '0')}',
      ),
    );
    final byUrl = {for (final h in hubs) h.url: h};
    final crypto = Crypto('did:cht:test');
    var inFlight = 0;
    var peak = 0;
    final net = RelayNetwork(
      crypto,
      connector: (url) async {
        inFlight++;
        if (inFlight > peak) peak = inFlight;
        await Future<void>.delayed(const Duration(milliseconds: 1));
        inFlight--;
        return byUrl[url]!.connect(url);
      },
    );
    try {
      await net.initialize();
      await net.importList(
        jsonEncode({
          'version': 1,
          'relays': hubs.map((h) => h.record).toList(),
        }),
      );
      while (net.online.length < 50) {
        await net.tick();
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(net.online, hasLength(50));
      await expectLater(net.setConnectionLimit(49), throwsFormatException);
      await expectLater(net.setConnectionLimit(1001), throwsFormatException);
      await net.setConnectionLimit(1000);
      while (net.online.length < 1000) {
        await net.tick();
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(peak, lessThanOrEqualTo(6));
      expect(net.online, hasLength(1000));
      expect(
        hubs.expand((h) => h.sockets).where((s) => s.subscribed),
        hasLength(3),
      );
      final active = net.online.last;
      net.activeEndpoint = active;
      await net.setConnectionLimit(50);
      expect(net.online, hasLength(50));
      expect(net.online, contains(active));
      final newFriendRelay = Hub(a, 'relay-new-friend');
      byUrl[a] = newFriendRelay;
      await net.addContactRoutes([a]);
      await until(() => net.online.contains(a));
      expect(net.online, hasLength(50));
      expect(net.online, contains(active));
      expect(net.preferredRoutes, [a]);
      expect(jsonDecode(crypto.cache)['connectionLimit'], 50);
      final restored = RelayNetwork(
        crypto,
        connector: (_) async => throw StateError('offline'),
      );
      try {
        await restored.initialize();
        expect(restored.connectionLimit, 50);
        expect(restored.records, hasLength(1000));
      } finally {
        await restored.close();
      }
    } finally {
      await net.close();
    }
  });

  test(
    'signed public routes from a contact bootstrap the relay automatically',
    () async {
      final hub = Hub(a, 'relay-a');
      final net = RelayNetwork(Crypto('did:cht:test'), connector: hub.connect);
      try {
        await net.initialize();
        expect(net.contactRelayUrls, isEmpty);
        await net.addContactRoutes([a]);
        await until(() => net.online.isNotEmpty);
        expect(net.contactRelayUrls, [a]);
      } finally {
        await net.close();
      }
    },
  );

  test(
    'normalizes TryCloudflare URL and rejects credential-bearing addresses',
    () {
      expect(
        normalizeRelayUrl('https://demo.trycloudflare.com'),
        'wss://demo.trycloudflare.com/cht',
      );
      for (final url in [
        'http://example.com',
        'wss://user:pass@example.com/cht',
        'wss://example.com/cht?token=secret',
      ]) {
        expect(() => normalizeRelayUrl(url), throwsFormatException);
      }
    },
  );

  test('learns backups, saves them, and securely reconnects after primary relay fails', () async {
    final first = Hub(a, 'relay-a');
    final second = Hub(b, 'relay-b');
    first.catalog = [first.record, second.record];
    second.catalog = [first.record, second.record];
    Future<RelaySocket> connect(String endpoint) =>
        (endpoint == a ? first : second).connect(endpoint);
    final cryptoA = Crypto('did:cht:alice');
    final cryptoB = Crypto('did:cht:bob');
    final netA = RelayNetwork(cryptoA, connector: connect);
    final netB = RelayNetwork(cryptoB, connector: connect);
    final alice = RelayChat(
      Account(cryptoA.id, cryptoB.id),
      netA,
      ownCard: () async => cryptoA.id,
    );
    final bob = RelayChat(
      Account(cryptoB.id, cryptoA.id),
      netB,
      ownCard: () async => cryptoB.id,
    );
    try {
      await netA.initialize();
      await netB.initialize();
      await netA.addSeed(a);
      await netB.addSeed(a);
      await until(() => netA.records.length == 2 && netB.records.length == 2);
      await netA.tick();
      await netB.tick();
      await until(() => netA.online.length == 2 && netB.online.length == 2);
      alice.select(cryptoB.id);
      await until(() => alice.authenticated && bob.authenticated);
      await expectLater(
        alice.sendMessage('too-large', '\u0001' * 5000, 123),
        throwsStateError,
      );
      expect(alice.authenticated, isTrue);
      await alice.sendMessage('before', 'before failover', 123);
      await until(() => bob.events.any((e) => e.messageId == 'before'));
      await bob.acknowledge('before', 456);
      await until(
        () => alice.events.any(
          (e) => e.type == 'delivered' && e.messageId == 'before',
        ),
      );
      await first.stop();
      await until(() => !alice.authenticated && !bob.authenticated);
      await until(() => alice.authenticated && bob.authenticated);
      await alice.sendMessage('after', 'after failover', 789);
      await until(() => bob.events.any((e) => e.messageId == 'after'));
      expect(netA.online, [b]);
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(jsonDecode(cryptoA.cache)['relays'], hasLength(2));
    } finally {
      await alice.close();
      await bob.close();
    }
  });

  test(
    'ignores poisoned relay hints and refuses a changed bootstrap identity',
    () async {
      final hub = Hub(a, 'original');
      hub.catalog = [
        {
          ...hub.record,
          'relayId': 'poisoned',
          'endpoint': b,
          'signature': 'forged',
        },
      ];
      final crypto = Crypto('did:cht:test');
      final network = RelayNetwork(crypto, connector: hub.connect);
      try {
        await network.initialize();
        await network.addSeed(a);
        await until(() => network.online.isNotEmpty);
        expect(network.records.keys, ['original']);
        expect(network.pins[a], 'original');
        await network.close();
        final attacker = Hub(a, 'replacement');
        final restored = RelayNetwork(crypto, connector: attacker.connect);
        try {
          // Flush explicitly through a seed update before restoring the cache.
          crypto.cache = jsonEncode({
            'version': 1,
            'seeds': [a],
            'pins': {a: 'original'},
            'relays': [],
          });
          await restored.initialize();
          await until(() => restored.error != null);
          expect(restored.online, isEmpty);
        } finally {
          await restored.close();
        }
      } finally {
        await network.close();
      }
    },
  );
}
