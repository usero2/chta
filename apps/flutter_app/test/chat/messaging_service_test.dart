import 'dart:async';
import 'dart:convert';

import 'package:cht/account/account_models.dart';
import 'package:cht/chat/messaging_service.dart';
import 'package:cht/chat/peer_history.dart';
import 'package:cht/chat/peer_message_action.dart';
import 'package:cht/relay/relay_network.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cht/chat/chat_attachment.dart';
import 'package:cht/chat/chunked_attachment_bridge.dart';
import 'package:cht/p2p/direct_file_link.dart';

import 'dart:typed_data';

import '../p2p/direct_file_link_test.dart' as rtc;
import '../groups/swarm_test.dart' show Attachments;

import '../relay/relay_network_test.dart' as f;
import 'durable_outbox_test.dart' show Store;

class Account extends f.SessionAccount {
  Account(String id, List<String> peers, {this.messageActions = true})
    : all = {for (final p in peers) p: f.SessionAccount(id, p)},
      super(id, peers.first);
  final Map<String, f.SessionAccount> all;
  final bool messageActions;
  int contactReads = 0;
  @override
  Future<ContactView> inspectContactCard(String source) async => ContactView(
    identityId: source,
    displayName: source,
    fingerprint: '',
    verified: true,
    capabilities: [
      'peer-sessions-v2',
      'files-v2',
      if (messageActions) PeerMessageAction.capability,
    ],
  );
  @override
  Future<List<ContactView>> contacts() async {
    contactReads++;
    return [for (final id in all.keys) await inspectContactCard(id)];
  }

  @override
  Future<Map<String, Object?>> groupCall(
    String op,
    Map<String, Object?> args,
  ) => all[args['peerId']]!.groupCall(op, args);
}

class GatedReadAttachments extends Attachments {
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<ChatAttachment> read(String owner, ref) async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
    return super.read(owner, ref);
  }
}

class _Cache implements ChunkedAttachmentBridge {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Factory implements DirectPeerFactory {
  Future<void>? remoteGate;
  late _Factory other;
  final peers = <_Peer>[];
  @override
  Future<DirectPeer> create() async {
    final p = _Peer(() => other.peers.lastWhere((p) => !p.closed))
      ..remoteGate = remoteGate;
    peers.add(p);
    return p;
  }
}

class _Peer extends rtc.FakePeer {
  _Peer(this.remote);
  final _Peer Function() remote;
  bool dropPackets = false, throwPackets = false, dropReceipts = false;
  @override
  Future<void> send(String frame) async {
    await super.send(frame);
    final type = (jsonDecode(frame) as Map)['type'];
    if (type == 'packet' && throwPackets) {
      throw StateError('Synthetic stale Direct route');
    }
    if (type == 'packet' && dropPackets || type == 'receipt' && dropReceipts) {
      return;
    }
    remote().onFrame?.call(frame);
  }
}

void main() {
  test('reply, edit and delete exchange acknowledgements through encrypted relay chat', () async {
    final hub = f.Hub(f.a, 'relay-a');
    final histories = <String, PeerHistory>{};
    final services = <String, MessagingService>{};
    try {
      for (final name in ['alice', 'bob']) {
        final peer = name == 'alice' ? 'bob' : 'alice';
        final history = PeerHistory(store: Store());
        await history.load(name);
        histories[name] = history;
        final network = RelayNetwork(f.Crypto(name), connector: hub.connect);
        await network.addSeed(f.a);
        final service = MessagingService(
          ownerId: name,
          account: Account(name, [peer]),
          network: network,
          history: history,
          ownCard: () async => name,
          observeNetwork: false,
        );
        services[name] = service;
        await service.start();
      }
      final alice = services['alice']!, bob = services['bob']!;
      final received = histories['bob']!;
      await alice.queueText('bob', 'Original text', id: 'original');
      await f.until(() => received.visibleMessagesFor('alice').isNotEmpty);
      await expectLater(
        bob.queueMessageAction(
          'alice',
          PeerMessageActionKind.delete,
          'original',
        ),
        throwsFormatException,
      );
      await bob.queueMessageAction(
        'alice',
        PeerMessageActionKind.reply,
        'original',
        text: 'Reply text',
      );
      await f.until(
        () => histories['alice']!.visibleMessagesFor('bob').length == 2,
      );
      await alice.queueMessageAction(
        'bob',
        PeerMessageActionKind.edit,
        'original',
        text: 'Updated',
      );
      await f.until(
        () => received.presentationFor('alice', 'original')?.text == 'Updated',
      );
      await alice.queueMessageAction(
        'bob',
        PeerMessageActionKind.delete,
        'original',
      );
      await f.until(
        () => received.presentationFor('alice', 'original')?.deleted == true,
      );
      await f.until(
        () =>
            histories['alice']!.queuedMessages.isEmpty &&
            received.queuedMessages.isEmpty,
      );
      expect(received.visibleMessagesFor('alice').map((m) => m.body), [
        'Original text',
        'Reply text',
      ]);
      expect(
        received.visibleMessagesFor('alice').last.action?.target,
        'original',
      );
    } finally {
      for (final service in services.values) {
        await service.close();
      }
      for (final history in histories.values) {
        history.dispose();
      }
    }
  });

  test('first message can use Relay while Direct opens and the next message upgrades', () async {
    final hub = f.Hub(f.a, 'relay-a'), factories = [_Factory(), _Factory()];
    factories[0].other = factories[1];
    factories[1].other = factories[0];
    final services = <MessagingService>[], histories = <PeerHistory>[];
    try {
      for (var i = 0; i < 2; i++) {
        final name = i == 0 ? 'alice' : 'bob';
        final friend = i == 0 ? 'bob' : 'alice';
        final history = PeerHistory(store: Store());
        await history.load(name);
        histories.add(history);
        final network = RelayNetwork(f.Crypto(name), connector: hub.connect);
        await network.addSeed(f.a);
        final service = MessagingService(
          ownerId: name,
          account: Account(name, [friend]),
          network: network,
          history: history,
          ownCard: () async => name,
          cache: _Cache(),
          peerFactory: factories[i],
          observeNetwork: false,
        );
        services.add(service);
        await service.start();
      }
      final alice = services.first;
      await alice.prepareConversation('bob');
      await f.until(
        () => services.every((service) => service.onlinePeers.isNotEmpty),
      );
      await alice.queueText('bob', 'first', id: 'relay-first');
      await f.until(
        () =>
            histories.first.messagesFor('bob').first.status ==
            DeliveryStatus.delivered,
      );
      await f.until(
        () => factories.every((factory) => factory.peers.isNotEmpty),
      );
      expect(alice.filesFor('bob')?.ready, isFalse);
      for (final factory in factories) {
        factory.peers.last.onReadyChanged?.call(true);
      }
      await f.until(
        () =>
            alice.filesFor('bob')?.ready == true &&
            services.last.filesFor('alice')?.ready == true,
      );
      await alice.queueText('bob', 'second', id: 'direct-next');
      await f.until(
        () =>
            histories.first.messagesFor('bob').last.status ==
            DeliveryStatus.delivered,
      );
      expect(
        factories.first.peers.last.sent
            .map(jsonDecode)
            .whereType<Map>()
            .map((packet) => packet['id']),
        contains('direct-next'),
      );
      expect(histories.last.messagesFor('alice').map((message) => message.id), [
        'relay-first',
        'direct-next',
      ]);

      await f.until(
        () =>
            alice.filesFor('bob')?.supportsMessageActions == true &&
            services.last.filesFor('alice')?.supportsMessageActions == true,
      );
      await hub.stop();
      await f.until(() => alice.relayFor('bob')?.authenticated == false);
      await alice.queueMessageAction(
        'bob',
        PeerMessageActionKind.edit,
        'direct-next',
        text: 'Edited over Direct',
      );
      await f.until(
        () =>
            histories.last.presentationFor('alice', 'direct-next')?.text ==
            'Edited over Direct',
      );
      await f.until(() => histories.first.queuedMessages.isEmpty);
      expect(alice.filesFor('bob')?.ready, isTrue);
    } finally {
      for (final service in services) {
        await service.close();
      }
      for (final history in histories) {
        history.dispose();
      }
    }
  });

  test(
    'events arriving during a slow receiver save drain immediately afterward',
    () async {
      final hub = f.Hub(f.a, 'relay-a'),
          receiverStore = Store(),
          release = Completer<void>();
      final histories = <PeerHistory>[], services = <MessagingService>[];
      try {
        for (var i = 0; i < 2; i++) {
          final owner = i == 0 ? 'alice' : 'bob',
              peer = i == 0 ? 'bob' : 'alice';
          final h = PeerHistory(store: i == 0 ? Store() : receiverStore);
          await h.load(owner);
          histories.add(h);
          final net = RelayNetwork(f.Crypto(owner), connector: hub.connect);
          await net.addSeed(f.a);
          final service = MessagingService(
            ownerId: owner,
            account: Account(owner, [peer]),
            network: net,
            history: h,
            ownCard: () async => owner,
            observeNetwork: false,
          );
          services.add(service);
          await service.start();
        }
        await f.until(() => services.every((s) => s.onlinePeers.isNotEmpty));
        await histories.last.flush();
        receiverStore.gate = release;
        await services.first.queueText('bob', 'first', id: 'gated-first');
        await services.first.queueText('bob', 'second', id: 'gated-second');
        await f.until(
          () => services.last
              .relayFor('alice')!
              .events
              .any((e) => e.messageId == 'gated-second'),
        );
        release.complete();
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(
          histories.last.messagesFor('alice').map((m) => m.id),
          contains('gated-second'),
        );
      } finally {
        if (!release.isCompleted) release.complete();
        for (final s in services) {
          await s.close();
        }
        for (final h in histories) {
          h.dispose();
        }
      }
    },
  );
  test(
    'pausing while the legacy cache opens cannot start a ghost file send',
    () async {
      final hub = f.Hub(f.a, 'relay-a'), gated = GatedReadAttachments();
      final histories = <PeerHistory>[], services = <MessagingService>[];
      try {
        for (var i = 0; i < 2; i++) {
          final owner = i == 0 ? 'alice' : 'bob',
              peer = i == 0 ? 'bob' : 'alice';
          final h = PeerHistory(
            store: Store(),
            attachments: i == 0 ? gated : Attachments(),
          );
          await h.load(owner);
          histories.add(h);
          final net = RelayNetwork(f.Crypto(owner), connector: hub.connect);
          await net.addSeed(f.a);
          final service = MessagingService(
            ownerId: owner,
            account: Account(owner, [peer]),
            network: net,
            history: h,
            ownCard: () async => owner,
            observeNetwork: false,
          );
          services.add(service);
          await service.start();
        }
        await f.until(() => services.every((s) => s.onlinePeers.isNotEmpty));
        await services.first.queueMessage(
          'bob',
          PeerMessage(
            id: 'pause-before-read',
            text: 'file',
            incoming: false,
            status: DeliveryStatus.pending,
            attachment: ChatAttachment(
              name: 'fixture.bin',
              mimeType: 'application/octet-stream',
              bytes: Uint8List(16),
            ),
          ),
        );
        await gated.entered.future;
        await services.first.pauseFile('bob', 'pause-before-read');
        gated.release.complete();
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(histories.last.messagesFor('alice'), isEmpty);
        await services.first.queueText(
          'bob',
          'text still works',
          id: 'text-during-pause',
        );
        await f.until(
          () => histories.last
              .messagesFor('alice')
              .any((m) => m.id == 'text-during-pause'),
        );
        expect(histories.first.messagesFor('bob').first.deliveryPaused, isTrue);
      } finally {
        if (!gated.release.isCompleted) gated.release.complete();
        for (final s in services) {
          await s.close();
        }
        for (final h in histories) {
          h.dispose();
        }
      }
    },
  );
  test(
    'file pause, resume and cancel persist without disconnecting text',
    () async {
      final store = Store(), history = PeerHistory(store: Store());
      final h = PeerHistory(store: store);
      await h.load('alice');
      final net = RelayNetwork(f.Crypto('alice'));
      final service = MessagingService(
        ownerId: 'alice',
        account: Account('alice', ['bob']),
        network: net,
        history: h,
        ownCard: () async => 'alice',
        observeNetwork: false,
      );
      try {
        await service.start();
        await service.queueMessage(
          'bob',
          PeerMessage(
            id: 'file-actions',
            text: 'file',
            incoming: false,
            status: DeliveryStatus.pending,
            attachment: ChatAttachment(
              name: 'fixture.bin',
              mimeType: 'application/octet-stream',
              bytes: Uint8List(2),
            ),
          ),
        );
        await service.pauseFile('bob', 'file-actions');
        final message = h.messagesFor('bob').single;
        expect(message.deliveryPaused, isTrue);
        expect(message.queuedForDelivery, isTrue);
        final resumed = PeerHistory(store: store);
        await resumed.load('alice');
        expect(resumed.messagesFor('bob').single.deliveryPaused, isTrue);
        resumed.dispose();
        await service.resumeFile('bob', 'file-actions');
        expect(message.deliveryPaused, isFalse);
        expect(message.queuedForDelivery, isTrue);
        await service.cancelFile('bob', 'file-actions');
        expect(message.queuedForDelivery, isFalse);
        expect(message.failureReason, 'Cancelled');
        await service.queueText(
          'bob',
          'still chatting',
          id: 'text-after-cancel',
        );
        expect(h.messagesFor('bob').last.queuedForDelivery, isTrue);
        await service.outbox.acknowledge('bob', 'file-actions', 999);
        expect(message.status, DeliveryStatus.delivered);
        expect(message.deliveryPaused, isFalse);
        expect(message.failureReason, isNull);
      } finally {
        await service.close();
        h.dispose();
        history.dispose();
      }
    },
  );
  test(
    'an idle account does not rebuild its UI every polling interval',
    () async {
      final h = PeerHistory(store: Store());
      await h.load('alice');
      final network = RelayNetwork(f.Crypto('alice'));
      final service = MessagingService(
        ownerId: 'alice',
        account: Account('alice', ['bob']),
        network: network,
        history: h,
        ownCard: () async => 'alice',
        observeNetwork: false,
      );
      try {
        await service.start();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        var changes = 0;
        service.addListener(() => changes++);
        await Future<void>.delayed(const Duration(milliseconds: 800));
        expect(changes, 0);
      } finally {
        await service.close();
        h.dispose();
      }
    },
  );
  test(
    'receiver save failure clears its progress and never acknowledges delivery',
    () async {
      final hub = f.Hub(f.a, 'relay-a'), stores = [Store(), Store()];
      final histories = <PeerHistory>[], services = <MessagingService>[];
      try {
        for (var i = 0; i < 2; i++) {
          final name = i == 0 ? 'alice' : 'bob',
              friend = i == 0 ? 'bob' : 'alice';
          final history = PeerHistory(
            store: stores[i],
            attachments: Attachments(),
          );
          await history.load(name);
          histories.add(history);
          final network = RelayNetwork(f.Crypto(name), connector: hub.connect);
          await network.addSeed(f.a);
          final service = MessagingService(
            ownerId: name,
            account: Account(name, [friend]),
            network: network,
            history: history,
            ownCard: () async => name,
          );
          services.add(service);
          await service.start();
        }
        await f.until(() => services.every((s) => s.onlinePeers.isNotEmpty));
        stores[1].fail = true;
        await services[0].queueMessage(
          'bob',
          PeerMessage(
            id: 'save-failure',
            text: '[file]',
            incoming: false,
            status: DeliveryStatus.pending,
            attachment: ChatAttachment(
              name: 'fixture.bin',
              mimeType: 'application/octet-stream',
              bytes: Uint8List(100),
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 800));
        expect(histories[1].error, isNotNull);
        expect(services[1].incomingProgressFor('alice'), isEmpty);
        expect(
          histories[0].messagesFor('bob').single.status,
          isNot(DeliveryStatus.delivered),
        );
      } finally {
        for (final service in services) {
          await service.close();
        }
        for (final history in histories) {
          history.dispose();
        }
      }
    },
  );
  for (final failure in [
    'silent Direct loss',
    'Direct send error',
    'Direct receipt loss',
    'large retry backlog',
  ]) {
    test('$failure uses the working relay without duplicate bubbles', () async {
      final hub = f.Hub(f.a, 'relay-a'), factories = [_Factory(), _Factory()];
      factories[0].other = factories[1];
      factories[1].other = factories[0];
      final services = <MessagingService>[], histories = <PeerHistory>[];
      try {
        for (var i = 0; i < 2; i++) {
          final name = i == 0 ? 'alice' : 'bob',
              friend = i == 0 ? 'bob' : 'alice';
          final history = PeerHistory(store: Store());
          await history.load(name);
          histories.add(history);
          final network = RelayNetwork(f.Crypto(name), connector: hub.connect);
          await network.addSeed(f.a);
          final service = MessagingService(
            ownerId: name,
            account: Account(name, [friend]),
            network: network,
            history: history,
            ownCard: () async => name,
            cache: _Cache(),
            peerFactory: factories[i],
          );
          services.add(service);
          await service.start();
        }
        await f.until(
          () =>
              services.every((s) => s.onlinePeers.isNotEmpty) &&
              factories.every((f) => f.peers.isNotEmpty),
        );
        await Future<void>.delayed(const Duration(milliseconds: 600));
        for (final factory in factories) {
          factory.peers.last.onReadyChanged?.call(true);
        }
        await f.until(
          () =>
              services[0].filesFor('bob')?.ready == true &&
              services[1].filesFor('alice')?.ready == true,
        );
        factories[0].peers.last.dropPackets =
            failure == 'silent Direct loss' || failure == 'large retry backlog';
        factories[0].peers.last.throwPackets = failure == 'Direct send error';
        factories[1].peers.last.dropReceipts = failure == 'Direct receipt loss';
        await services[0].queueText(
          'bob',
          'Synthetic failover text',
          id: 'same-id',
        );
        if (failure == 'large retry backlog') {
          for (var i = 0; i < 257; i++) {
            await services[0].queueText(
              'bob',
              'Synthetic backlog $i',
              id: 'backlog-$i',
            );
            await f.until(
              () =>
                  histories[0].messagesFor('bob').last.status ==
                  DeliveryStatus.sent,
            );
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final sentAt = histories[0].messagesFor('bob').first.sentAtMilliseconds;
        int? firstReceipt;
        if (failure == 'Direct receipt loss') {
          firstReceipt = histories[1]
              .messagesFor('alice')
              .single
              .receivedAtMilliseconds;
        }
        if (failure != 'Direct send error') services[0].outbox.retryNow('bob');
        await Future<void>.delayed(const Duration(milliseconds: 800));
        expect(
          histories[0].messagesFor('bob').first.status,
          DeliveryStatus.delivered,
        );
        final matches = histories[1]
            .messagesFor('alice')
            .where((m) => m.id == 'same-id');
        expect(matches, hasLength(1));
        final received = matches.single;
        expect(received.id, 'same-id');
        expect(received.sentAtMilliseconds, sentAt);
        if (firstReceipt != null) {
          expect(received.receivedAtMilliseconds, firstReceipt);
        }
      } finally {
        for (final s in services) {
          await s.close();
        }
        for (final h in histories) {
          h.dispose();
        }
      }
    });
  }
  test('input above the Markdown limit never becomes a durable job', () async {
    final history = PeerHistory(store: Store());
    await history.load('alice');
    final network = RelayNetwork(f.Crypto('alice'));
    final service = MessagingService(
      ownerId: 'alice',
      account: Account('alice', ['bob']),
      network: network,
      history: history,
      ownCard: () async => 'alice',
    );
    try {
      await expectLater(
        service.queueText('bob', 'a' * (1024 * 1024 + 1)),
        throwsFormatException,
      );
      expect(history.messagesFor('bob'), isEmpty);
    } finally {
      await service.close();
      history.dispose();
    }
  });
  test(
    'long Markdown travels through the relay as one intact message',
    () async {
      final hub = f.Hub(f.a, 'relay-a');
      final services = <MessagingService>[], histories = <PeerHistory>[];
      try {
        for (final (owner, peer) in [('alice', 'bob'), ('bob', 'alice')]) {
          final history = PeerHistory(
            store: Store(),
            attachments: Attachments(),
          );
          await history.load(owner);
          histories.add(history);
          final network = RelayNetwork(f.Crypto(owner), connector: hub.connect);
          final service = MessagingService(
            ownerId: owner,
            account: Account(owner, [peer]),
            network: network,
            history: history,
            ownCard: () async => owner,
            observeNetwork: false,
          );
          services.add(service);
          await network.addSeed(f.a);
          await service.start();
        }
        final text =
            '    # ตัวอย่าง\n${'ข้อความ 😀 \\ **Markdown**\n' * 1100}\n';
        await services.first.queueText('bob', text, id: 'long-note');
        await f.until(
          () =>
              histories.first.messagesFor('bob').single.status ==
              DeliveryStatus.delivered,
        );
        final received = histories.last.messagesFor('alice').single;
        final file = await histories.last.resolveAttachment(received);
        expect(received.id, 'long-note');
        expect(file.name, endsWith('.md'));
        expect(file.mimeType, 'text/markdown');
        expect(utf8.decode(file.bytes), text);
      } finally {
        for (final service in services) {
          await service.close();
        }
        for (final history in histories) {
          history.dispose();
        }
      }
    },
  );
  test(
    'slow Direct negotiation never blocks relayed text to the same contact',
    () async {
      final hub = f.Hub(f.a, 'relay-a'),
          gate = Completer<void>(),
          factories = [_Factory(), _Factory()];
      factories[0].other = factories[1];
      factories[1].other = factories[0];
      for (final f in factories) {
        f.remoteGate = gate.future;
      }
      final services = <MessagingService>[], histories = <PeerHistory>[];
      try {
        for (var i = 0; i < 2; i++) {
          final name = i == 0 ? 'alice' : 'bob',
              friend = i == 0 ? 'bob' : 'alice',
              h = PeerHistory(store: Store());
          await h.load(name);
          histories.add(h);
          final n = RelayNetwork(f.Crypto(name), connector: hub.connect);
          await n.addSeed(f.a);
          final s = MessagingService(
            ownerId: name,
            account: Account(name, [friend]),
            network: n,
            history: h,
            ownCard: () async => name,
            cache: _Cache(),
            peerFactory: factories[i],
          );
          services.add(s);
          await s.start();
        }
        await f.until(
          () =>
              services.every((s) => s.onlinePeers.isNotEmpty) &&
              factories.every((f) => f.peers.isNotEmpty),
        );
        await Future<void>.delayed(const Duration(milliseconds: 600));
        await services[0].queueText(
          'bob',
          'Text while SDP is blocked',
          id: 'during-sdp',
        );
        await Future<void>.delayed(const Duration(milliseconds: 700));
        expect(
          histories[1].messagesFor('alice').map((m) => m.id),
          contains('during-sdp'),
        );
      } finally {
        gate.complete();
        for (final s in services) {
          await s.close();
        }
        for (final h in histories) {
          h.dispose();
        }
      }
    },
  );
  for (final relayStaysOnline in [true, false]) {
    test(
      'small cached file completes over Direct with relay online=$relayStaysOnline',
      () async {
        final hub = f.Hub(f.a, 'relay-a'), factories = [_Factory(), _Factory()];
        factories[0].other = factories[1];
        factories[1].other = factories[0];
        final services = <MessagingService>[],
            histories = <PeerHistory>[],
            networks = <RelayNetwork>[];
        try {
          for (var i = 0; i < 2; i++) {
            final name = i == 0 ? 'alice' : 'bob',
                friend = i == 0 ? 'bob' : 'alice';
            final h = PeerHistory(store: Store(), attachments: Attachments());
            await h.load(name);
            histories.add(h);
            final network = RelayNetwork(
              f.Crypto(name),
              connector: hub.connect,
            );
            await network.addSeed(f.a);
            networks.add(network);
            final service = MessagingService(
              ownerId: name,
              account: Account(name, [friend]),
              network: network,
              history: h,
              ownCard: () async => name,
              cache: _Cache(),
              peerFactory: factories[i],
            );
            services.add(service);
            await service.start();
          }
          await f.until(
            () =>
                services.every((s) => s.onlinePeers.isNotEmpty) &&
                factories.every((f) => f.peers.isNotEmpty),
          );
          await Future<void>.delayed(const Duration(milliseconds: 600));
          for (final factory in factories) {
            factory.peers.last.onReadyChanged?.call(true);
          }
          await f.until(
            () =>
                services[0].filesFor('bob')?.ready == true &&
                services[1].filesFor('alice')?.ready == true,
          );
          if (!relayStaysOnline) {
            for (final network in networks) {
              await network.forget(f.a);
            }
            expect(services[0].relayFor('bob')!.authenticated, false);
          }
          final file = ChatAttachment(
            name: 'direct.bin',
            mimeType: 'application/octet-stream',
            bytes: Uint8List(100),
          );
          await services[0].queueMessage(
            'bob',
            PeerMessage(
              id: 'direct-file',
              text: 'file',
              incoming: false,
              status: DeliveryStatus.pending,
              attachment: file,
            ),
          );
          await Future<void>.delayed(const Duration(milliseconds: 800));
          expect(
            histories[0].messagesFor('bob').single.status,
            DeliveryStatus.delivered,
          );
          expect(histories[1].messagesFor('alice').single.hasAttachment, true);
          expect(
            services[0].outgoingProgressFor('bob'),
            isEmpty,
            reason: 'A durably delivered file must not retain its 100% bar',
          );
          expect(services[1].incomingProgressFor('alice'), isEmpty);
        } finally {
          for (final s in services) {
            await s.close();
          }
          for (final h in histories) {
            h.dispose();
          }
        }
      },
    );
  }
  test('account service receives two peers with no selected screen and retries an offline queue', () async {
    final hub = f.Hub(f.a, 'relay-a'), stores = [Store(), Store(), Store()];
    final peers = [
          ['bob', 'carol'],
          ['alice'],
          ['alice'],
        ],
        names = ['alice', 'bob', 'carol'];
    final services = <MessagingService>[], histories = <PeerHistory>[];
    try {
      for (var i = 0; i < 3; i++) {
        final h = PeerHistory(store: stores[i]);
        await h.load(names[i]);
        histories.add(h);
        final net = RelayNetwork(f.Crypto(names[i]), connector: hub.connect);
        await net.addSeed(f.a);
        final s = MessagingService(
          ownerId: names[i],
          account: Account(names[i], peers[i]),
          network: net,
          history: h,
          ownCard: () async => names[i],
        );
        services.add(s);
        await s.start();
      }
      await f.until(() => services[0].onlinePeers.length == 2);
      await services[1].queueText('alice', 'from bob', id: 'b');
      await services[2].queueText('alice', 'from carol', id: 'c');
      await f.until(
        () =>
            histories[0].messagesFor('bob').length == 1 &&
            histories[0].messagesFor('carol').length == 1,
      );
      await f.until(
        () =>
            histories[1].messagesFor('alice').single.status ==
                DeliveryStatus.delivered &&
            histories[2].messagesFor('alice').single.status ==
                DeliveryStatus.delivered,
      );
      expect(histories[0].messagesFor('bob').single.text, 'from bob');
    } finally {
      for (final s in services) {
        await s.close();
      }
      for (final h in histories) {
        h.dispose();
      }
    }
  });
}
