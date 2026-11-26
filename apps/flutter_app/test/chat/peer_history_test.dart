import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:cht/chat/peer_history.dart';
import 'package:cht/chat/peer_message_action.dart';
import 'package:cht/chat/peer_history_store.dart';
import 'package:cht/chat/peer_history_store_native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'message actions survive reload and apply only to the original author',
    () async {
      final store = _Store();
      final h = PeerHistory(store: store);
      await h.load('owner');
      void add(String id, String text, int time, {bool incoming = true}) {
        h.add(
          'friend',
          PeerMessage(
            id: id,
            text: text,
            incoming: incoming,
            status: DeliveryStatus.delivered,
            sentAtMilliseconds: time,
          ),
        );
      }

      void action(
        String suffix,
        PeerMessageActionKind kind,
        String target,
        int time, {
        String? text,
        bool incoming = true,
      }) {
        add(
          '${PeerMessageAction.idPrefix}$suffix',
          PeerMessageAction(kind, target, text).encode(),
          time,
          incoming: incoming,
        );
      }

      action('a', PeerMessageActionKind.edit, 'original', 3, text: 'newest');
      add('original', 'original text', 1);
      action('b', PeerMessageActionKind.edit, 'original', 2, text: 'older');
      action(
        'c',
        PeerMessageActionKind.edit,
        'original',
        4,
        text: 'forged',
        incoming: false,
      );
      action(
        'reply',
        PeerMessageActionKind.reply,
        'original',
        7,
        text: 'my reply',
        incoming: false,
      );
      expect(h.presentationFor('friend', 'original')?.text, 'newest');
      expect(
        h
            .visibleMessagesFor('friend')
            .map((m) => h.presentationFor('friend', m.id)?.text),
        [
          'original',
          'reply',
        ].map((id) => id == 'original' ? 'newest' : 'my reply'),
      );
      action(
        'forged',
        PeerMessageActionKind.delete,
        'original',
        8,
        incoming: false,
      );
      expect(h.presentationFor('friend', 'original')?.deleted, false);
      action('delete', PeerMessageActionKind.delete, 'original', 6);
      await h.flush();
      final reopened = PeerHistory(store: store);
      await reopened.load('owner');
      expect(reopened.presentationFor('friend', 'original')?.deleted, true);
      expect(
        reopened.presentationFor('friend', 'original')?.text,
        'Message deleted',
      );
      expect(
        reopened.visibleMessagesFor('friend').last.action?.target,
        'original',
      );
      h.dispose();
      reopened.dispose();
    },
  );

  test('forwardable delivery metadata survives storage and deletion blocks unseen old backfill', () async {
    var time = 2000;
    final store = _Store(), h = PeerHistory(store: store, clock: () => time);
    await h.load('owner');
    final m = PeerMessage(
      id: 'one',
      text: 'hello',
      incoming: false,
      status: DeliveryStatus.pending,
      sentAtMilliseconds: 1000,
      deliveryEnvelope: {
        'version': 2,
        'event': {'messageId': 'one'},
        'payload': '{}',
      },
      courierJobId: 'a' * 32,
    );
    h.add('friend', m);
    await h.flush();
    final loaded = PeerHistory(store: store, clock: () => time);
    await loaded.load('owner');
    expect(
      loaded.messagesFor('friend').single.deliveryEnvelope,
      m.deliveryEnvelope,
    );
    expect(loaded.messagesFor('friend').single.courierJobId, 'a' * 32);
    await loaded.clearConversation('friend');
    expect(loaded.isDeletedDelivery('friend', 'unseen-old', 1500), isTrue);
    expect(loaded.isDeletedDelivery('friend', 'new', 2001), isFalse);
    final reopened = PeerHistory(store: store, clock: () => time);
    await reopened.load('owner');
    expect(reopened.isDeletedDelivery('friend', 'unseen-old', 1500), isTrue);
    h.dispose();
    loaded.dispose();
    reopened.dispose();
  });
  test(
    'flush includes writes appended while an earlier save is pending',
    () async {
      final store = _GatedStore();
      final h = PeerHistory(store: store);
      await h.load('owner');
      h.add('friend', _message('first'));
      await store.firstEntered.future;
      var flushed = false;
      final flush = h.flush().then((_) => flushed = true);
      h.add('friend', _message('second'));
      store.first.complete();
      await store.secondEntered.future;
      await Future<void>.delayed(Duration.zero);
      expect(flushed, isFalse, reason: 'The second save is still blocked');
      store.second.complete();
      await flush;
      expect(flushed, isTrue);
      h.dispose();
    },
  );
  test(
    'restores per-peer history, isolates identities and preserves receipts',
    () async {
      final store = _Store();
      final history = PeerHistory(store: store);
      await history.load('me');
      history.add(
        'ton',
        PeerMessage(
          id: 'one',
          text: 'hello ton',
          incoming: false,
          status: DeliveryStatus.pending,
        ),
      );
      history.add(
        'bob',
        PeerMessage(
          id: 'two',
          text: 'hello bob',
          incoming: true,
          status: DeliveryStatus.delivered,
        ),
      );
      history.setStatus(
        'ton',
        'one',
        DeliveryStatus.delivered,
        receivedAtMilliseconds: 123456789,
      );
      history.setStatus('ton', 'one', DeliveryStatus.sent);
      history.add(
        'ton',
        PeerMessage(
          id: 'one',
          text: 'duplicate',
          incoming: false,
          status: DeliveryStatus.pending,
        ),
      );
      await history.flush();
      history.dispose();

      final reopened = PeerHistory(store: store);
      await reopened.load('me');
      expect(reopened.messagesFor('ton').single.text, 'hello ton');
      expect(
        reopened.messagesFor('ton').single.receivedAtMilliseconds,
        123456789,
      );
      expect(
        reopened.messagesFor('ton').single.status,
        DeliveryStatus.delivered,
      );
      expect(reopened.messagesFor('bob').single.text, 'hello bob');
      await reopened.load('someone-else');
      expect(reopened.messagesFor('ton'), isEmpty);
      reopened.dispose();
    },
  );

  test(
    'legacy incoming timestamp is a receive time, not an invented send time',
    () async {
      final store = _Store();
      store.values['me'] = jsonEncode({
        'version': 1,
        'rooms': {
          'ton': [
            {
              'id': 'legacy',
              'text': 'old',
              'incoming': true,
              'status': 'delivered',
              'sentAtMilliseconds': 123456789,
            },
          ],
        },
      });
      final history = PeerHistory(store: store);
      await history.load('me');
      expect(history.messagesFor('ton').single.sentAtMilliseconds, isNull);
      expect(
        history.messagesFor('ton').single.receivedAtMilliseconds,
        123456789,
      );
      history.dispose();
    },
  );

  test(
    'clearing a conversation persists a tombstone and rejects stale writes',
    () async {
      final store = _Store();
      final history = PeerHistory(store: store);
      await history.load('me');
      final callbackGeneration = history.conversationGeneration('ton');
      history.add('ton', _message('before'));
      await history.clearConversation('ton');
      history.add(
        'ton',
        _message('stale'),
        expectedGeneration: callbackGeneration,
      );
      expect(history.messagesFor('ton'), isEmpty);
      await history.flush();
      history.dispose();

      final reopened = PeerHistory(store: store);
      await reopened.load('me');
      expect(reopened.messagesFor('ton'), isEmpty);
      final newGeneration = reopened.conversationGeneration('ton');
      reopened.add('ton', _message('new'), expectedGeneration: newGeneration);
      expect(reopened.messagesFor('ton').single.id, 'new');
      reopened.dispose();
    },
  );

  test('Windows history survives reopening and is encrypted on disk', () async {
    final directory = await Directory.systemTemp.createTemp(
      'cht-history-test-',
    );
    try {
      final first = NativePeerHistoryStore(directory: directory);
      await first.save('me', 'private history ไทย');
      await first.save('me', 'updated private history ไทย');
      final reopened = NativePeerHistoryStore(directory: directory);
      expect(await reopened.load('me'), 'updated private history ไทย');
      expect(await reopened.load('other'), isNull);
      final bytes = await directory
          .list()
          .where((entry) => entry.path.endsWith('.bin'))
          .cast<File>()
          .first
          .then((file) => file.readAsBytes());
      expect(
        utf8.decode(bytes, allowMalformed: true),
        isNot(contains('private history')),
      );
    } finally {
      await directory.delete(recursive: true);
    }
  }, skip: !Platform.isWindows);
}

class _Store implements PeerHistoryStore {
  final values = <String, String>{};
  @override
  Future<String?> load(String ownerId) async => values[ownerId];
  @override
  Future<void> save(String ownerId, String source) async {
    values[ownerId] = source;
  }
}

class _GatedStore implements PeerHistoryStore {
  final first = Completer<void>(), second = Completer<void>();
  final firstEntered = Completer<void>(), secondEntered = Completer<void>();
  int saves = 0;
  @override
  Future<String?> load(String ownerId) async => null;
  @override
  Future<void> save(String ownerId, String source) async {
    if (++saves == 1) {
      firstEntered.complete();
      await first.future;
    } else if (saves == 2) {
      secondEntered.complete();
      await second.future;
    }
  }
}

PeerMessage _message(String id) => PeerMessage(
  id: id,
  text: id,
  incoming: true,
  status: DeliveryStatus.delivered,
);
