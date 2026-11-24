import 'dart:async';

import 'package:cht/chat/durable_outbox.dart';
import 'package:cht/chat/peer_history.dart';
import 'package:cht/chat/peer_history_store.dart';
import 'package:cht/chat/chat_attachment.dart';
import 'package:cht/chat/resumable_attachment_transfer.dart';

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

class Store implements PeerHistoryStore {
  final saved = <String, String>{};
  bool fail = false;
  Completer<void>? gate;
  @override
  Future<String?> load(String id) async => saved[id];
  @override
  Future<void> save(String id, String value) async {
    await gate?.future;
    if (fail) throw StateError('disk full');
    saved[id] = value;
  }
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 60));
void main() {
  test(
    'bulk files leave independent capacity for text to every peer',
    () async {
      final h = PeerHistory(store: Store());
      await h.load('owner');
      final released = Completer<void>(), sent = <String>[];
      final out = DurableOutbox(
        ownerId: 'owner',
        history: h,
        isReady: (_) => true,
        send: (_, m) async {
          sent.add(m.id);
          if (m.hasAttachment) await released.future;
        },
      );
      try {
        for (var i = 0; i < 8; i++) {
          await out.enqueue(
            'friend-$i',
            PeerMessage(
              id: 'file-$i',
              text: 'file',
              incoming: false,
              status: DeliveryStatus.pending,
              attachment: ChatAttachment(
                name: 'fixture',
                mimeType: 'application/octet-stream',
                bytes: Uint8List(1),
              ),
            ),
          );
          await settle();
        }
        await out.enqueue(
          'friend-0',
          PeerMessage(
            id: 'text-same',
            text: 'hi',
            incoming: false,
            status: DeliveryStatus.pending,
          ),
        );
        await out.enqueue(
          'another',
          PeerMessage(
            id: 'text-other',
            text: 'hi',
            incoming: false,
            status: DeliveryStatus.pending,
          ),
        );
        await settle();
        expect(sent, containsAll(['text-same', 'text-other']));
        expect(
          sent.where((id) => id.startsWith('file-')).length,
          lessThanOrEqualTo(4),
        );
      } finally {
        released.complete();
        out.close();
        await settle();
        h.dispose();
      }
    },
  );

  test(
    'permanent file rejection stops automatic retry and survives restart',
    () async {
      final store = Store(), h = PeerHistory(store: Store());
      final history = PeerHistory(store: store);
      await history.load('owner');
      var now = 0, attempts = 0;
      final out = DurableOutbox(
        ownerId: 'owner',
        history: history,
        clock: () => now,
        isReady: (_) => true,
        send: (peer, m) async {
          attempts++;
          history.setStatus(peer, m.id, DeliveryStatus.failed);
          throw const TransferRejected('Cached file is missing or damaged');
        },
      );
      await out.enqueue(
        'friend',
        PeerMessage(
          id: 'bad-file',
          text: 'file',
          incoming: false,
          status: DeliveryStatus.pending,
        ),
      );
      await settle();
      now = 10001;
      out.pump();
      await settle();
      expect(attempts, 1);
      await history.flush();
      final resumed = PeerHistory(store: store);
      await resumed.load('owner');
      expect(resumed.queuedMessages, isEmpty);
      expect(
        resumed.messagesFor('friend').single.status,
        DeliveryStatus.failed,
      );
      expect(
        resumed.messagesFor('friend').single.toJson()['failureReason'],
        'Cached file is missing or damaged',
      );
      out.close();
      h.dispose();
      history.dispose();
      resumed.dispose();
    },
  );

  test(
    'paused delivery survives reload and needs explicit enqueue to resume',
    () async {
      final store = Store();
      final history = PeerHistory(store: store);
      await history.load('owner');
      final message = PeerMessage.fromJson({
        ...PeerMessage(
          id: 'paused',
          text: 'file',
          incoming: false,
          status: DeliveryStatus.pending,
        ).toJson(),
        'queuedForDelivery': true,
        'deliveryPaused': true,
      });
      history.add('friend', message);
      await history.flush();
      final resumed = PeerHistory(store: store);
      await resumed.load('owner');
      final saved = resumed.messagesFor('friend').single;
      var attempts = 0;
      final out = DurableOutbox(
        ownerId: 'owner',
        history: resumed,
        isReady: (_) => true,
        send: (_, _) async {
          attempts++;
        },
      );
      out.pump();
      await settle();
      expect(attempts, 0);
      expect(saved.toJson()['deliveryPaused'], isTrue);
      await out.enqueue('friend', saved);
      await settle();
      expect(attempts, 1);
      out.close();
      history.dispose();
      resumed.dispose();
    },
  );

  test('a slow file does not block text to the same peer', () async {
    final h = PeerHistory(store: Store());
    await h.load('a');
    final gate = Completer<void>(), sent = <String>[];
    final out = DurableOutbox(
      ownerId: 'a',
      history: h,
      isReady: (_) => true,
      send: (_, message) async {
        sent.add(message.id);
        if (message.hasAttachment) await gate.future;
      },
    );
    await out.enqueue(
      'b',
      PeerMessage(
        id: 'file',
        text: 'file',
        incoming: false,
        status: DeliveryStatus.pending,
        attachment: ChatAttachment(
          name: 'x',
          mimeType: 'application/octet-stream',
          bytes: Uint8List(1),
        ),
      ),
    );
    await out.enqueue(
      'b',
      PeerMessage(
        id: 'text',
        text: 'hello during file',
        incoming: false,
        status: DeliveryStatus.pending,
      ),
    );
    await settle();
    expect(sent, contains('text'));
    gate.complete();
    out.close();
    h.dispose();
  });
  test('offline work survives restart with same ID and only durable ACK removes intent', () async {
    final store = Store(), h = PeerHistory(store: Store());
    await h.load('other');
    final first = PeerHistory(store: store);
    await first.load('owner');
    final out = DurableOutbox(
      ownerId: 'owner',
      history: first,
      isReady: (_) => false,
      send: (_, _) async => throw StateError('offline'),
    );
    await out.enqueue(
      'friend',
      PeerMessage(
        id: 'stable',
        text: 'protected by store',
        incoming: false,
        status: DeliveryStatus.pending,
        sentAtMilliseconds: 123,
      ),
    );
    out.close();
    final restarted = PeerHistory(store: store);
    await restarted.load('owner');
    final sent = <String>[];
    var now = 1000;
    final second = DurableOutbox(
      ownerId: 'owner',
      history: restarted,
      isReady: (_) => true,
      send: (peer, m) async {
        sent.add('$peer/${m.id}/${m.sentAtMilliseconds}');
      },
      clock: () => now,
    );
    second.pump();
    await settle();
    expect(sent, ['friend/stable/123']);
    now += 20000;
    second.pump();
    await settle();
    expect(sent.length, 2, reason: 'lost receipt retries same ID');
    await second.acknowledge('friend', 'stable', 999);
    now += 20000;
    second.pump();
    await settle();
    expect(sent.length, 2);
    final loaded = PeerHistory(store: store);
    await loaded.load('owner');
    expect(loaded.queuedMessages, isEmpty);
    expect(loaded.messagesFor('friend').single.receivedAtMilliseconds, 999);
    second.close();
    first.dispose();
    restarted.dispose();
    loaded.dispose();
    h.dispose();
  });
  test('never transmits before durable save; failure preserves draft and restart intent', () async {
    final store = Store(), history = PeerHistory(store: store);
    await history.load('a');
    var sent = 0;
    final out = DurableOutbox(
      ownerId: 'a',
      history: history,
      isReady: (_) => true,
      send: (_, _) async {
        sent++;
      },
    );
    store.fail = true;
    await expectLater(
      out.enqueue(
        'b',
        PeerMessage(
          id: 'x',
          text: 'x',
          incoming: false,
          status: DeliveryStatus.pending,
        ),
      ),
      throwsStateError,
    );
    out.pump();
    await settle();
    expect(sent, 0);
    store.fail = false;
    history.changed();
    await history.flush();
    out.pump();
    await settle();
    expect(sent, 1);
    out.close();
    history.dispose();
  });
  test('deleting a room or changing owner prevents queued sends; historical failures remain unsent', () async {
    final store = Store(), history = PeerHistory(store: store);
    await history.load('a');
    var ready = false, sent = 0;
    final out = DurableOutbox(
      ownerId: 'a',
      history: history,
      isReady: (_) => ready,
      send: (_, _) async {
        sent++;
      },
    );
    history.add(
      'b',
      PeerMessage(
        id: 'old',
        text: 'abandoned',
        incoming: false,
        status: DeliveryStatus.failed,
      ),
    );
    await out.enqueue(
      'c',
      PeerMessage(
        id: 'new',
        text: 'queued',
        incoming: false,
        status: DeliveryStatus.pending,
      ),
    );
    await history.clearConversation('c');
    ready = true;
    out.pump();
    await settle();
    expect(sent, 0);
    await history.load('other');
    out.pump();
    await settle();
    expect(sent, 0);
    out.close();
    history.dispose();
  });
}
