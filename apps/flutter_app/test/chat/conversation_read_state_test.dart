import 'package:cht/chat/conversation_read_state.dart';
import 'package:cht/groups/group_blob_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

class Store implements GroupBlobBridge {
  final values = <(String, String), String>{};

  @override
  Future<String?> loadGroupBlob(String ownerId, String key) async =>
      values[(ownerId, key)];

  @override
  Future<void> saveGroupBlob(String ownerId, String key, String value) async {
    values[(ownerId, key)] = value;
  }

  @override
  Future<void> deleteGroupBlob(String ownerId, String key) async {
    values.remove((ownerId, key));
  }
}

void main() {
  test(
    'local counts survive reopening and handle simultaneous arrivals',
    () async {
      final store = Store();
      var read = ConversationReadState(
        ownerId: 'alice',
        store: store,
        clock: () => 100,
      );
      final rows = [
        (id: 'old', at: 90),
        (id: 'first', at: 105),
        (id: 'next', at: 110),
      ];
      await read.initialize();
      expect(read.unreadCount('did:cht:bob', rows), 2);
      expect(read.unreadCount('group:test', rows), 2);

      read.markRead('did:cht:bob', rows);
      await read.flush();
      expect(read.unreadCount('did:cht:bob', rows), 0);
      expect(read.unreadCount('group:test', rows), 2);

      read = ConversationReadState(
        ownerId: 'alice',
        store: store,
        clock: () => 200,
      );
      await read.initialize();
      expect(
        read.unreadCount('did:cht:bob', [...rows, (id: 'same-time', at: 110)]),
        1,
      );
      expect(read.unreadCount('group:test', rows), 2);

      final other = ConversationReadState(
        ownerId: 'other',
        store: store,
        clock: () => 200,
      );
      await other.initialize();
      expect(other.unreadCount('group:test', rows), 0);
    },
  );
}
