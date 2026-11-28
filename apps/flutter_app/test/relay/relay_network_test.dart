import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:cht/account/account_bridge.dart';
import 'package:cht/account/account_models.dart';
import 'package:cht/groups/group_crypto_bridge.dart';
import 'package:cht/relay/relay_chat.dart';
import 'package:cht/relay/relay_crypto_bridge.dart';
import 'package:cht/relay/relay_network.dart';
import 'package:cht/relay/relay_provider_policy.dart';
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
  bool muteKeepalive = false;
  final sent = <Map<String, dynamic>>[];
  @override
  Stream<String> get frames => controller.stream;
  void receive(Map<String, dynamic> value) {
    if (!closed) controller.add(jsonEncode(value));
  }

  @override
  void send(String source) {
    if (closed || hub.offline) throw StateError('Offline');
    final frame = jsonDecode(source) as Map<String, dynamic>;
    sent.add(frame);
    if (frame['type'] == 'register') {
      subscribed = frame['subscribeCatalog'] != false;
      identity = (frame['proof'] as Map)['identityId'] as String;
      receive({'type': 'registered'});
    }
    if (frame['type'] == 'keepalive' && !muteKeepalive) {
      receive({'type': 'alive'});
    }
    if (frame['type'] == 'directory') {
      subscribed = frame['subscribeCatalog'] != false;
    }
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
  test('handover replaces a retained relay that stopped responding', () async {
    final active = Hub(a, 'relay-a'), warm = Hub(b, 'relay-b');
    final network = RelayNetwork(
      Crypto('alice'),
      connector: (endpoint) => (endpoint == a ? active : warm).connect(endpoint),
      handoverProbeTimeout: const Duration(milliseconds: 150),
    );
    try {
      await network.addSeed(a);
      await network.addSeed(b);
      await until(() => network.online.length == 2);
      network.activeEndpoint = a;
      final oldActive = active.sockets.single..muteKeepalive = true;
      await network.recoverNetwork();
      expect(oldActive.closed, isFalse, reason: 'probe before replacing');
      await until(() => oldActive.closed).timeout(const Duration(seconds: 1));
      await until(() => network.online.length == 2);
      expect(active.sockets.length, 2);
      expect(warm.sockets.length, 2);

      final live = active.sockets.last;
      await network.recoverNetwork();
      await until(() => warm.sockets.length == 3 && network.online.length == 2);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(live.closed, isFalse);
      expect(active.sockets.length, 2);
    } finally {
      await network.close();
    }
  });

  test('non-forced recovery keeps a healthy idle relay', () async {
    final hub = Hub(a, 'relay-a');
    var now = DateTime.now().millisecondsSinceEpoch;
    final network = RelayNetwork(
      Crypto('alice'),
      connector: hub.connect,
      clock: () => now,
    );
    try {
      await network.addSeed(a);
      await until(() => network.online.contains(a));
      now += 35000;
      await network.recoverNetwork(force: false);
      expect(network.online, contains(a));
      expect(hub.sockets, hasLength(1));
    } finally {
      await network.close();
    }
  });

  test('300-second refresh keeps the relay alive between refreshes', () async {
    final hub = Hub(a, 'relay-a');
    var now = 100000;
    final network = RelayNetwork(
      Crypto('alice'),
      connector: hub.connect,
      bootstrapRelays: const {a: 'relay-a'},
      clock: () => now,
    );
    final received = <String>[];
    final pulses = <Duration, void Function()>{};
    network.onFrame = (_, frame) => received.add(frame['session'] as String);
    try {
      await runZoned(
        () async {
          await network.initialize();
          await until(() => network.online.contains(a));
          final socket = hub.sockets.single;
          const refresh = Duration(seconds: 300);
          const heartbeat = Duration(seconds: 10);
          network.setInBackground(true, refreshInterval: refresh);
          socket.sent.clear();
          for (var i = 0; i < 29; i++) {
            now += heartbeat.inMilliseconds;
            pulses[heartbeat]!();
            await Future<void>.delayed(Duration.zero);
          }
          expect(socket.sent, isNotEmpty);
          expect(socket.sent.map((frame) => frame['type']).toSet(), {
            'keepalive',
          });
          socket.receive({'type': 'route', 'session': 'incoming-message'});
          await until(() => received.isNotEmpty);
          expect(received, ['incoming-message']);
          expect(network.online, contains(a));
          now += heartbeat.inMilliseconds;
          pulses[refresh]!();
          expect(socket.sent.last['type'], 'directory');
          expect(hub.sockets.single, same(socket));
        },
        zoneSpecification: ZoneSpecification(
          createPeriodicTimer: (self, parent, zone, interval, callback) {
            final timer = parent.createPeriodicTimer(zone, interval, callback);
            pulses[interval] = () => callback(timer);
            return timer;
          },
        ),
      );
    } finally {
      await network.close();
    }
  });

  test(
    'background relays keep routes live with less catalog traffic',
    () async {
      var now = 100000;
      final primary = Hub(a, 'relay-a');
      final backup = Hub(b, 'relay-b');
      final network = RelayNetwork(
        Crypto('alice'),
        connector: (url) => (url == a ? primary : backup).connect(url),
        clock: () => now,
      );
      final received = <String>[];
      network.onFrame = (_, frame) => received.add(frame['session'] as String);
      try {
        await network.initialize();
        await network.addSeed(a);
        await network.addSeed(b);
        await until(() => network.online.length == 2);
        final first = primary.sockets.single, second = backup.sockets.single;
        expect(first.subscribed && second.subscribed, isTrue);

        network.setInBackground(true);
        await until(() => !second.subscribed);
        expect(first.subscribed, isTrue);
        first.sent.clear();
        second.sent.clear();
        for (var round = 0; round < 2; round++) {
          now += 27000;
          await network.tick();
          await Future<void>.delayed(Duration.zero);
        }
        expect(first.sent.map((frame) => frame['type']), [
          'keepalive',
          'keepalive',
        ]);
        expect(second.sent.map((frame) => frame['type']), [
          'keepalive',
          'keepalive',
        ]);
        expect(network.online, containsAll([a, b]));

        second.receive({'type': 'route', 'session': 'background-message'});
        await until(() => received.contains('background-message'));
        now += 27000;
        await network.tick();
        expect(first.sent.last['type'], 'directory');
        expect(second.sent.last['type'], 'keepalive');

        network.setInBackground(false);
        await until(() => second.subscribed);
        expect(first.sent.last['type'], 'directory');
        expect(primary.sockets.single, same(first));
        expect(backup.sockets.single, same(second));
      } finally {
        await network.close();
      }
    },
  );

  test(
    'closing a relay releases a tick queued behind a blocked write',
    () async {
      final hub = Hub(a, 'relay-a');
      final account = Account('alice', 'bob');
      final alice = RelayChat(
        account,
        RelayNetwork(Crypto('alice'), connector: hub.connect),
        ownCard: () async => 'alice',
        automaticTicks: false,
      );
      final bob = RelayChat(
        Account('bob', 'alice'),
        RelayNetwork(Crypto('bob'), connector: hub.connect),
        ownCard: () async => 'bob',
      );
      final gate = Completer<void>();
      try {
        await alice.network.addSeed(a);
        await bob.network.addSeed(a);
        alice.select('bob');
        bob.select('alice');
        await until(() => alice.authenticated && bob.authenticated);
        account.encryptGate = gate;
        account.encryptEntered = Completer<void>();
        final send = expectLater(
          alice.sendMessage('blocked', 'text', 124),
          throwsStateError,
        );
        await account.encryptEntered!.future;
        final tick = alice.tick();
        await alice.close();
        await tick.timeout(const Duration(seconds: 1));
        gate.complete();
        await send;
      } finally {
        if (!gate.isCompleted) gate.complete();
        await alice.close();
        await bob.close();
      }
    },
  );

  test(
    'Relay sends text and ACK ahead of queued file chunks in Noise order',
    () async {
      final hub = Hub(a, 'relay-a');
      final account = Account('alice', 'bob');
      final left = RelayNetwork(Crypto('alice'), connector: hub.connect);
      final right = RelayNetwork(Crypto('bob'), connector: hub.connect);
      final alice = RelayChat(account, left, ownCard: () async => 'alice');
      final bob = RelayChat(
        Account('bob', 'alice'),
        right,
        ownCard: () async => 'bob',
      );
      final gate = Completer<void>();
      try {
        await left.addSeed(a);
        await right.addSeed(a);
        alice.select('bob');
        bob.select('alice');
        await until(() => alice.authenticated && bob.authenticated);
        await bob.sendMessage('reply-target', 'hi', 123);
        await until(
          () => alice.events.any((e) => e.messageId == 'reply-target'),
        );
        alice.drainEvents();
        bob.drainEvents();

        account.encryptGate = gate;
        account.encryptEntered = Completer<void>();
        final first = alice.sendMessage('chtatt1_first', 'chunk', 124);
        await account.encryptEntered!.future;
        account.encryptEntered = null;
        final second = alice.sendMessage(
          'chtfile2_second',
          '{"type":"part"}',
          125,
        );
        final text = alice.sendMessage('text', 'chat', 126);
        final receipt = alice.acknowledge('reply-target', 127);
        gate.complete();
        await Future.wait([first, second, text, receipt]);
        await until(
          () => bob.events.any((e) => e.messageId == 'chtfile2_second'),
        );
        expect(
          bob.events
              .where((event) => event.messageId != null)
              .map((event) => event.messageId),
          ['chtatt1_first', 'text', 'reply-target', 'chtfile2_second'],
        );
        expect(alice.authenticated && bob.authenticated, isTrue);
      } finally {
        if (!gate.isCompleted) gate.complete();
        await alice.close();
        await bob.close();
      }
    },
  );

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
        'chtatt1_file-packet',
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
          (e) => e.type == 'sent' && e.messageId == 'chtatt1_file-packet',
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
  test(
    'keeps two relay sockets while retaining the full saved catalog',
    () async {
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
        await until(() => net.online.length >= 2);
        await net.tick();
        await expectLater(net.setConnectionLimit(49), throwsFormatException);
        await expectLater(net.setConnectionLimit(1001), throwsFormatException);
        await net.setConnectionLimit(1000);
        expect(peak, 2);
        expect(net.online, [hubs[0].url, hubs[1].url]);
        expect(net.knownRelayCount, 1000);
        expect(
          hubs.expand((h) => h.sockets).where((s) => !s.closed),
          hasLength(2),
        );
        expect(jsonDecode(crypto.cache)['connectionLimit'], 1000);
        final restored = RelayNetwork(
          crypto,
          connector: (_) async => throw StateError('offline'),
        );
        try {
          await restored.initialize();
          expect(restored.connectionLimit, 1000);
          expect(restored.records, hasLength(1000));
        } finally {
          await restored.close();
        }
      } finally {
        await net.close();
      }
    },
  );

  test(
    'warms a relay with a different configured operator and refills on failure',
    () async {
      final primary = Hub(a, 'relay-a');
      final sameOperator = Hub(b, 'relay-b');
      final independent = Hub('wss://c.example.com/cht', 'relay-c');
      final hubs = {
        for (final h in [primary, sameOperator, independent]) h.url: h,
      };
      final network = RelayNetwork(
        Crypto('alice'),
        bootstrapRelays: hubs.map((url, hub) => MapEntry(url, hub.id)),
        providerPolicy: RelayProviderPolicy({
          'relay-a': 'operator-one',
          'relay-b': 'operator-one',
          'relay-c': 'operator-two',
        }),
        connector: (url) => hubs[url]!.connect(url),
      );
      try {
        await network.initialize();
        await until(() => network.online.length >= 2);
        final warmSocket = independent.sockets.single;
        expect(network.online, [primary.url, independent.url]);
        expect(sameOperator.sockets, isEmpty);
        await primary.stop();
        await until(
          () => network.online.toSet().containsAll([
            independent.url,
            sameOperator.url,
          ]),
        );
        expect(network.online.first, independent.url);
        expect(warmSocket.closed, isFalse);
        expect(independent.sockets, hasLength(1));
      } finally {
        await network.close();
      }
    },
  );

  test(
    'keeps both sockets while a preferred contact route is connecting',
    () async {
      final primary = Hub(a, 'relay-a');
      final standby = Hub(b, 'relay-b');
      final contact = Hub('wss://c.example.com/cht', 'relay-c');
      final connecting = Completer<RelaySocket>();
      final network = RelayNetwork(
        Crypto('alice'),
        connector: (url) => switch (url) {
          a => primary.connect(url),
          b => standby.connect(url),
          _ => connecting.future,
        },
      );
      final lease = Object();
      try {
        await network.addSeed(a);
        await network.addSeed(b);
        await until(() => network.online.length == 2);
        network.leaseRoute(lease, a);
        await network.addContactRoutes([contact.url]);
        expect(network.online, [a, b]);
        final oldStandby = standby.sockets.single;
        connecting.complete(await contact.connect(contact.url));
        await until(() => network.online.contains(contact.url));
        expect(network.online, [a, contact.url]);
        expect(primary.sockets.single.closed, isFalse);
        expect(oldStandby.closed, isTrue);
      } finally {
        await network.close();
      }
    },
  );

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
