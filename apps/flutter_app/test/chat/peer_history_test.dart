import 'dart:io';
import 'dart:convert';

import 'package:cht/chat/peer_history.dart';
import 'package:cht/chat/peer_history_store.dart';
import 'package:cht/chat/peer_history_store_native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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

PeerMessage _message(String id) => PeerMessage(
  id: id,
  text: id,
  incoming: true,
  status: DeliveryStatus.delivered,
);
