import 'dart:async';
import 'dart:convert';

import 'package:cht/account/account_models.dart';
import 'package:cht/chat/chunked_attachment_bridge.dart';
import 'package:cht/chat/peer_history.dart';
import 'package:cht/chat/attachment_ref.dart';
import 'package:cht/chat/peer_history_store.dart';
import 'package:cht/p2p/peer_file_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'direct_file_link_test.dart' show FakeFactory;

ContactView friend(String id) => ContactView(
  identityId: id,
  displayName: id,
  fingerprint: 'fake',
  verified: true,
  capabilities: const ['files-v2'],
);
void main() {
  test('authenticated late V2 completion updates paused history but cannot recreate deleted messages', () async {
    final history = PeerHistory();
    await history.load('z-owner');
    const id = 'late-completion-fixture';
    final message = PeerMessage(
      id: id,
      text: 'file',
      incoming: false,
      status: DeliveryStatus.failed,
      deliveryPaused: true,
      failureReason: 'Cancelled',
      attachmentRef: AttachmentRef(
        name: 'empty.bin',
        mimeType: 'application/octet-stream',
        size: 0,
        digest: _emptyHash,
        chunkedId: 'late-cache-fixture',
        chunkSize: 262144,
      ),
    );
    history.add('a-peer', message);
    var receipts = 0;
    final controller = PeerFileController(
      ownerId: 'z-owner',
      cache: _CompletedCache(),
      history: history,
      sendEncryptedControl: (_, _) async {},
      sendFallbackPacket: (_, _, _) async {},
      onPacket: (_, _, _) async {},
      onReceipt: (id, time) {
        receipts++;
        history.setStatus(
          'a-peer',
          id,
          DeliveryStatus.delivered,
          receivedAtMilliseconds: time,
        );
      },
      peerFactory: FakeFactory(),
    );
    try {
      await controller.updatePeer(
        friend('a-peer'),
        encryptedAuthenticated: true,
      );
      Future<void> complete(int time) => controller.receiveFilePacket(
        'chtfile2_late',
        jsonEncode({'v': 2, 'type': 'complete', 'id': id, 'receivedAt': time}),
        direct: false,
      );
      await complete(-1);
      expect(receipts, 0);
      await complete(777);
      expect(message.status, DeliveryStatus.delivered);
      expect(message.deliveryPaused, isFalse);
      expect(message.receivedAtMilliseconds, 777);
      await history.clearConversation('a-peer');
      await complete(777);
      expect(receipts, 1);
      expect(history.messagesFor('a-peer'), isEmpty);
    } finally {
      await controller.close();
      history.dispose();
    }
  });
  for (final receiptFails in [false, true]) {
    test(
      'durably completed streamed receive removes active progress even if receipt fails $receiptFails',
      () async {
        final history = PeerHistory();
        await history.load('z-owner');
        final packets = <String>[];
        final controller = PeerFileController(
          ownerId: 'z-owner',
          cache: _CompletedCache(),
          history: history,
          sendEncryptedControl: (_, _) async {},
          sendFallbackPacket: (_, text, _) async {
            packets.add(text);
            if (receiptFails &&
                (jsonDecode(text) as Map)['type'] == 'complete') {
              throw StateError('Synthetic receipt transport failure');
            }
          },
          onPacket: (_, _, _) async {},
          onReceipt: (_, _) {},
          peerFactory: FakeFactory(),
        );
        try {
          await controller.updatePeer(
            friend('a-peer'),
            encryptedAuthenticated: true,
          );
          await controller.receiveFilePacket(
            'chtfile2_offer',
            jsonEncode({
              'v': 2,
              'type': 'offer',
              'id': 'file-progress-fixture-0001',
              'name': 'empty.bin',
              'mimeType': 'application/octet-stream',
              'size': 0,
              'chunkSize': 262144,
              'digest': _emptyHash,
            }),
            direct: false,
          );
          expect(
            history.messagesFor('a-peer').single.status,
            DeliveryStatus.delivered,
          );
          expect(
            packets.map((p) => (jsonDecode(p) as Map)['type']),
            contains('complete'),
          );
          expect(controller.progress, isEmpty);
        } finally {
          await controller.close();
          history.dispose();
        }
      },
    );
  }
  test(
    'either identity can initiate Direct using signed seed signaling',
    () async {
      final factory = FakeFactory(), signals = <String>[];
      final controller = PeerFileController(
        ownerId: 'z-owner',
        cache: _Cache(),
        history: PeerHistory(),
        sendEncryptedControl: (_, _) async {},
        sendSeedControl: (_, text) async => signals.add(text),
        sendFallbackPacket: (_, _, _) async {},
        onPacket: (_, _, _) async {},
        onReceipt: (_, _) {},
        peerFactory: factory,
      );
      try {
        await controller.updatePeer(
          friend('a-peer'),
          encryptedAuthenticated: false,
          seedSignalingAvailable: true,
        );
        expect(signals, hasLength(1));
        expect((jsonDecode(signals.single) as Map)['t'], 'offer');
      } finally {
        await controller.close();
      }
    },
  );
  test(
    'clearing one conversation cancels retries without closing its direct link',
    () async {
      final factory = FakeFactory(), history = PeerHistory();
      var now = 1000;
      final controller = PeerFileController(
        ownerId: 'alice',
        cache: _Cache(),
        history: history,
        sendEncryptedControl: (id, text) async {},
        sendFallbackPacket: (id, text, time) async {},
        onPacket: (id, text, time) async {},
        onReceipt: (id, time) {},
        peerFactory: factory,
        clock: () => now,
      );
      try {
        await controller.updatePeer(
          friend('bob'),
          encryptedAuthenticated: true,
        );
        final rtc = factory.peers.single;
        rtc.onReadyChanged?.call(true);
        await controller.sendChatMessage('old', 'old text', now);
        controller.cancelPendingFor('carol');
        now += 6000;
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        expect(rtc.sent, hasLength(2));
        controller.cancelPendingFor('bob');
        await history.clearConversation('bob');
        now += 6000;
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        expect(rtc.sent, hasLength(2));
        expect(controller.ready, isTrue);
        expect(factory.peers, hasLength(1));
        await controller.sendChatMessage('new', 'new text', now);
        expect(rtc.sent, hasLength(3));
      } finally {
        await controller.close();
        history.dispose();
      }
    },
  );
  test(
    'signed seed negotiates old verified contacts without enabling fallback',
    () async {
      final factory = FakeFactory(),
          signals = <String>[],
          fallback = <String>[];
      final history = PeerHistory();
      final controller = PeerFileController(
        ownerId: 'alice',
        cache: _Cache(),
        history: history,
        sendEncryptedControl: (id, text) async => fail('Noise control absent'),
        sendSeedControl: (id, text) async {
          signals.add(text);
        },
        sendFallbackPacket: (id, text, time) async {
          fallback.add(text);
        },
        onPacket: (id, text, time) async {},
        onReceipt: (id, time) {},
        peerFactory: factory,
      );
      const oldContact = ContactView(
        identityId: 'bob',
        displayName: 'Bob',
        fingerprint: 'fake',
        verified: true,
      );
      await controller.updatePeer(
        oldContact,
        encryptedAuthenticated: false,
        seedSignalingAvailable: true,
      );
      expect(signals, hasLength(1));
      final rtc = factory.peers.single;
      rtc.onReadyChanged?.call(true);
      expect(
        controller.ready,
        isFalse,
        reason: 'Remote SDP must first be signed by friend',
      );
      final offer = jsonDecode(signals.single) as Map;
      final session = offer['s'];
      await controller.receiveSeedControl(
        'cht-control-direct-v1-$session-answer-1',
        jsonEncode({'v': 1, 't': 'answer', 's': session, 'd': offer['d']}),
        peer: 'bob',
      );
      expect(controller.ready, isTrue);
      await controller.sendChatMessage('hello-1', 'private', 1000);
      expect(rtc.sent, hasLength(1));
      rtc.onReadyChanged?.call(false);
      await controller.receiveFilePacket(
        'chtfile2_offer',
        jsonEncode({
          'v': 2,
          'type': 'offer',
          'id': 'seed-file',
          'name': 'secret.bin',
          'size': 0,
        }),
        direct: false,
      );
      expect(fallback, isEmpty);
      await controller.close();
      history.dispose();
    },
  );
  test('seed availability cannot promote unverified contacts', () async {
    final factory = FakeFactory();
    final controller = PeerFileController(
      ownerId: 'alice',
      cache: _Cache(),
      history: PeerHistory(),
      sendEncryptedControl: (id, text) async {},
      sendSeedControl: (id, text) async {},
      sendFallbackPacket: (id, text, time) async {},
      onPacket: (id, text, time) async {},
      onReceipt: (id, time) {},
      peerFactory: factory,
    );
    await controller.updatePeer(
      const ContactView(
        identityId: 'bob',
        displayName: 'Bob',
        fingerprint: 'fake',
        verified: false,
      ),
      encryptedAuthenticated: false,
      seedSignalingAvailable: true,
    );
    expect(factory.peers, isEmpty);
    expect(controller.ready, isFalse);
    await controller.close();
  });
  test('direct text retries without a receipt and stops after receipt or peer switch', () async {
    final factory = FakeFactory();
    final history = PeerHistory();
    var now = 1000;
    final controller = PeerFileController(
      ownerId: 'alice',
      cache: _Cache(),
      history: history,
      sendEncryptedControl: (id, text) async {},
      sendFallbackPacket: (id, text, time) async {},
      onPacket: (id, text, time) async {},
      onReceipt: (id, time) {},
      peerFactory: factory,
      clock: () => now,
    );
    await controller.updatePeer(friend('bob'), encryptedAuthenticated: true);
    final rtc = factory.peers.single;
    rtc.onReadyChanged?.call(true);
    final message = PeerMessage(
      id: 'text-1',
      text: 'hello',
      incoming: false,
      status: DeliveryStatus.pending,
    );
    history.add('bob', message);
    await controller.sendChatMessage(
      message.id,
      message.text,
      message.sentAtMilliseconds!,
    );
    expect(rtc.sent, hasLength(1));
    now += 6000;
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(rtc.sent, hasLength(2));
    rtc.onFrame?.call(
      jsonEncode({
        'v': 1,
        'type': 'receipt',
        'id': 'text-1',
        'receivedAt': 1234,
      }),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(rtc.sent, hasLength(2));
    await controller.sendChatMessage('text-2', 'next', 1234);
    await controller.updatePeer(friend('carol'), encryptedAuthenticated: false);
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(rtc.sent, hasLength(3));
    await controller.close();
    history.dispose();
  });
  test('peer selection during pending negotiation keeps latest peer and suppresses old signal', () async {
    final gate = Completer<void>(),
        factory = FakeFactory()..offerGate = gate.future;
    final signals = <String>[];
    final controller = PeerFileController(
      ownerId: 'alice',
      cache: _Cache(),
      history: PeerHistory(),
      sendEncryptedControl: (id, text) async {
        signals.add(text);
      },
      sendFallbackPacket: (id, text, time) async {},
      onPacket: (id, text, time) async {},
      onReceipt: (id, time) {},
      peerFactory: factory,
    );
    final first = controller.updatePeer(
      friend('bob'),
      encryptedAuthenticated: true,
    );
    await Future<void>.delayed(Duration.zero);
    final latest = controller.updatePeer(
      friend('carol'),
      encryptedAuthenticated: true,
    );
    gate.complete();
    await first;
    await latest;
    expect(controller.peerId, 'carol');
    expect(controller.link.peerId, 'carol');
    expect(factory.peers, hasLength(2));
    expect(signals, hasLength(1));
    await controller.close();
  });
  test(
    'failed history save does not accept or deliver a completed incoming cache',
    () async {
      final history = PeerHistory(store: _BrokenHistory());
      await history.load('z-owner');
      final packets = <String>[];
      final controller = PeerFileController(
        ownerId: 'z-owner',
        cache: _Cache(),
        history: history,
        sendEncryptedControl: (id, text) async {},
        sendFallbackPacket: (id, text, time) async {
          packets.add(text);
        },
        onPacket: (id, text, time) async {},
        onReceipt: (id, time) {},
        peerFactory: FakeFactory(),
      );
      await controller.updatePeer(
        friend('a-peer'),
        encryptedAuthenticated: true,
      );
      await controller.receiveFilePacket(
        'chtfile2_offer',
        jsonEncode({
          'v': 2,
          'type': 'offer',
          'id': 'file-history-fixture-001',
          'name': 'empty.bin',
          'mimeType': 'application/octet-stream',
          'size': 0,
          'chunkSize': 262144,
          'digest': _emptyHash,
        }),
        direct: false,
      );
      expect(packets.map((text) => (jsonDecode(text) as Map)['type']), [
        'error',
      ]);
      expect(
        history.messagesFor('a-peer').single.status,
        isNot(DeliveryStatus.delivered),
      );
      await controller.close();
      history.dispose();
    },
  );
}

const _emptyHash =
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

class _CompletedCache extends _Cache {
  @override
  Future<ChunkedAttachmentState> finishChunkedAttachment(
    String owner,
    String id, {
    String? expectedDigest,
  }) => beginChunkedAttachment(owner, id, 0, 262144, digest: expectedDigest);
}

class _Cache implements ChunkedAttachmentBridge {
  @override
  Future<ChunkedAttachmentState> beginChunkedAttachment(
    String owner,
    String id,
    int size,
    int chunkSize, {
    String? digest,
  }) async => ChunkedAttachmentState(
    id: id,
    size: size,
    chunkSize: chunkSize,
    contiguousChunks: 0,
    completed: true,
    digest: digest ?? _emptyHash,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _BrokenHistory implements PeerHistoryStore {
  @override
  Future<String?> load(String owner) async => null;
  @override
  Future<void> save(String owner, String data) async =>
      throw StateError('disk full');
}
