import 'dart:async';

import 'package:cht/relay/relay_chat.dart';
import 'package:cht/relay/relay_network.dart';
import 'package:flutter_test/flutter_test.dart';

import 'relay_network_test.dart' as f;

// Rust records an ID as seen during decryption, before the UI persists it.
class _DeduplicatingAccount extends f.SessionAccount {
  _DeduplicatingAccount(super.id, super.friend);
  final seen = <String>{};
  @override
  Future<Map<String, Object?>> groupCall(
    String op,
    Map<String, Object?> args,
  ) async {
    final value = await super.groupCall(op, args);
    if (op == 'decrypt') {
      final id = value['messageId'] ?? value['id'];
      return {...value, 'duplicate': !seen.add(id as String)};
    }
    return value;
  }
}

void main() {
  test('one unacknowledged file stream does not hold other relay sends', () async {
    final hub = f.Hub(f.a, 'relay-a');
    final left = RelayNetwork(f.Crypto('alice'), connector: hub.connect);
    final right = RelayNetwork(f.Crypto('bob'), connector: hub.connect);
    final alice = RelayChat(
      f.SessionAccount('alice', 'bob'), left, ownCard: () async => 'alice',
    );
    final bob = RelayChat(
      f.SessionAccount('bob', 'alice'), right, ownCard: () async => 'bob',
    );
    const part = '{"v":2,"type":"part"}';
    const blockedId = 'chtfile2_slow_file_4';
    final observed = Completer<void>();
    Future<void>? blocked;
    try {
      await left.addSeed(f.a);
      await right.addSeed(f.a);
      alice.select('bob');
      bob.select('alice');
      await f.until(() => alice.authenticated && bob.authenticated);
      for (var i = 0; i < 4; i++) {
        await alice.sendMessage('chtfile2_slow_file_$i', part, 1000);
      }
      blocked = alice.sendMessage(blockedId, part, 1000).whenComplete(() {
        observed.complete();
      });
      unawaited(blocked.catchError((Object _) {}));
      await alice.sendMessage('text-bypasses-file', 'chat', 1000);
      await alice.sendMessage('chtfile2_other_file_0', part, 1000);
      bool received(String id) => bob.events.any(
        (e) => e.type == 'message' && e.messageId == id,
      );
      await f.until(() => received('chtfile2_other_file_0'));
      expect(received('text-bypasses-file'), isTrue);
      expect(received(blockedId), isFalse);
      expect(observed.isCompleted, isFalse);
      await bob.acknowledge('chtfile2_other_file_0', 2000);
      await f.until(() => alice.events.any(
        (event) => event.messageId == 'chtfile2_other_file_0' && event.type == 'delivered',
      ));
      expect(observed.isCompleted, isFalse);
      await bob.acknowledge('chtfile2_slow_file_0', 2000);
      await blocked.timeout(const Duration(seconds: 2));
      await f.until(() => received(blockedId));
    } finally {
      await alice.close();
      await bob.close();
      await blocked?.catchError((Object _) {});
    }
  });
  test(
    'authenticated relay receipt reaches a message originally sent on Direct',
    () async {
      final hub = f.Hub(f.a, 'relay-a');
      final left = RelayNetwork(f.Crypto('alice'), connector: hub.connect);
      final right = RelayNetwork(f.Crypto('bob'), connector: hub.connect);
      final alice = RelayChat(
        f.SessionAccount('alice', 'bob'),
        left,
        ownCard: () async => 'alice',
      );
      final bob = RelayChat(
        f.SessionAccount('bob', 'alice'),
        right,
        ownCard: () async => 'bob',
      );
      try {
        await left.initialize();
        await right.initialize();
        await left.addSeed(f.a);
        await right.addSeed(f.a);
        alice.select('bob');
        bob.select('alice');
        await f.until(() => alice.authenticated && bob.authenticated);
        alice.drainEvents();
        await bob.acknowledge('direct-id', 2000);
        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(
          alice.events.where(
            (e) => e.type == 'delivered' && e.messageId == 'direct-id',
          ),
          hasLength(1),
        );
      } finally {
        await alice.close();
        await bob.close();
      }
    },
  );
  test('a decrypted retry reaches durable handling again when its first receipt was lost', () async {
    final hub = f.Hub(f.a, 'relay-a');
    final left = RelayNetwork(f.Crypto('alice'), connector: hub.connect);
    final right = RelayNetwork(f.Crypto('bob'), connector: hub.connect);
    var now = DateTime.now().millisecondsSinceEpoch;
    final alice = RelayChat(
      _DeduplicatingAccount('alice', 'bob'),
      left,
      ownCard: () async => 'alice',
      clock: () => now,
    );
    final bob = RelayChat(
      _DeduplicatingAccount('bob', 'alice'),
      right,
      ownCard: () async => 'bob',
      clock: () => now,
    );
    try {
      await left.initialize();
      await right.initialize();
      await left.addSeed(f.a);
      await right.addSeed(f.a);
      alice.select('bob');
      bob.select('alice');
      await f.until(() => alice.authenticated && bob.authenticated);
      alice.drainEvents();
      bob.drainEvents();
      await alice.sendMessage('lost-receipt', 'synthetic message', now);
      await f.until(() => bob.events.any((e) => e.messageId == 'lost-receipt'));
      bob.drainEvents(); // Simulate interruption before durable handling/ACK.
      now += 6000;
      await alice.tick();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(
        bob.events.where(
          (e) => e.type == 'message' && e.messageId == 'lost-receipt',
        ),
        hasLength(1),
      );
      await bob.acknowledge('lost-receipt', now);
      await f.until(
        () => alice.events.any(
          (e) => e.type == 'delivered' && e.messageId == 'lost-receipt',
        ),
      );
    } finally {
      await alice.close();
      await bob.close();
    }
  });

  test('current authenticated route becoming unreachable clears stale online state immediately', () async {
    final hub = f.Hub(f.a, 'relay-a');
    final left = RelayNetwork(f.Crypto('alice'), connector: hub.connect);
    final right = RelayNetwork(f.Crypto('bob'), connector: hub.connect);
    final account = f.SessionAccount('alice', 'bob');
    final alice = RelayChat(account, left, ownCard: () async => 'alice');
    final bob = RelayChat(
      f.SessionAccount('bob', 'alice'),
      right,
      ownCard: () async => 'bob',
    );
    try {
      await left.initialize();
      await right.initialize();
      await left.addSeed(f.a);
      await right.addSeed(f.a);
      alice.select('bob');
      bob.select('alice');
      await f.until(() => alice.authenticated && bob.authenticated);
      final sender = hub.sockets.singleWhere((s) => s.identity == 'alice');
      for (final session in account.sessions.keys.toList()) {
        sender.receive({
          'type': 'unreachable',
          'to': 'unrelated-peer',
          'session': session,
        });
      }
      sender.receive({'type': 'unreachable', 'to': 'bob', 'session': '0' * 32});
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(
        alice.authenticated,
        isTrue,
        reason:
            'Unrelated peer/session failures cannot retire a healthy channel',
      );
      // The sender's socket stays healthy while the recipient registration vanishes.
      final recipient = hub.sockets.singleWhere((s) => s.identity == 'bob');
      recipient.identity = 'temporarily-absent';
      await alice.sendMessage('unreachable', 'synthetic pending', 1000);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(
        alice.authenticated,
        isFalse,
        reason: 'A matching relay failure must not look connected for another 65 seconds',
      );
    } finally {
      await alice.close();
      await bob.close();
    }
  });
}
