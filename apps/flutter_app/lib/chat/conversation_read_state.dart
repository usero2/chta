import 'dart:async';
import 'dart:convert';

import '../groups/group_blob_bridge.dart';

typedef IncomingChatMarker = ({String id, int at});

class ConversationReadState {
  ConversationReadState({
    required this.ownerId,
    this.store,
    int Function()? clock,
  }) : _baseline = (clock ?? _now)();

  static int _now() => DateTime.now().millisecondsSinceEpoch;
  static const _key = 'conversation-read-state-v1';
  final String ownerId;
  final GroupBlobBridge? store;
  final _rooms = <String, _ReadCursor>{};
  int _baseline;
  Future<void> _writes = Future.value();
  bool _loaded = false;
  bool _canWrite = false;
  String? _saved;

  Future<void> initialize() async {
    try {
      final source = await store?.loadGroupBlob(ownerId, _key);
      if (source != null) {
        final value = jsonDecode(source) as Map<String, dynamic>;
        final rooms = value['rooms'] as Map<String, dynamic>;
        final restored = {
          for (final room in rooms.entries)
            room.key: _ReadCursor(
              room.value['at'] as int,
              (room.value['ids'] as List).cast<String>().toSet(),
            ),
        };
        _baseline = value['baseline'] as int;
        _rooms.addAll(restored);
        _saved = source;
      }
      _canWrite = true;
    } catch (_) {
      // Keep the session usable without replacing cursors we could not load.
    }
    _loaded = true;
    await flush();
  }

  int unreadCount(String room, Iterable<IncomingChatMarker> messages) {
    final cursor = _rooms[room];
    return messages.where((message) {
      if (message.at <= _baseline) return false;
      return cursor == null ||
          message.at > cursor.at ||
          message.at == cursor.at && !cursor.ids.contains(message.id);
    }).length;
  }

  void markRead(String room, Iterable<IncomingChatMarker> messages) {
    if (!_loaded) return;
    final old = _rooms[room];
    var latest = old?.at ?? _baseline;
    var ids = {...?old?.ids};
    var changed = false;
    for (final message in messages) {
      if (message.at <= _baseline || message.at < latest) continue;
      if (message.at > latest) {
        latest = message.at;
        ids = {message.id};
        changed = true;
      } else if (ids.add(message.id)) {
        changed = true;
      }
    }
    if (!changed) return;
    _rooms[room] = _ReadCursor(latest, ids);
    unawaited(flush());
  }

  Future<void> flush() {
    final storage = store;
    if (!_canWrite || storage == null) return Future.value();
    return _writes = _writes.then((_) async {
      final source = jsonEncode({
        'baseline': _baseline,
        'rooms': {
          for (final room in _rooms.entries)
            room.key: {'at': room.value.at, 'ids': room.value.ids.toList()},
        },
      });
      if (source == _saved) return;
      try {
        await storage.saveGroupBlob(ownerId, _key, source);
        _saved = source;
      } catch (_) {
        // Keep the in-memory cursor and retry on the next save or app pause.
      }
    });
  }
}

class _ReadCursor {
  const _ReadCursor(this.at, this.ids);
  final int at;
  final Set<String> ids;
}
