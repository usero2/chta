import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../groups/group_blob_bridge.dart';
import 'peer_history_store.dart';

/// Immutable encrypted room pages; the small manifest is the commit point.
class RoomHistoryStore implements IncrementalPeerHistoryStore {
  RoomHistoryStore({required this.legacy, required this.blobs});
  final PeerHistoryStore legacy;
  final GroupBlobBridge blobs;
  static const indexKey = 'peer_history_index_v1';
  static const _previousKey = 'peer_history_previous_index_v1';
  static const maxPageBytes = 512 * 1024;
  static const _pageMessages = 128;
  Future<void> _tail = Future.value();
  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  @override
  Future<String?> load(String ownerId) => _serial(() async {
    final source = await blobs.loadGroupBlob(ownerId, indexKey);
    if (source == null) return legacy.load(ownerId);
    final index = _Index.parse(source);
    final rooms = <String, Object?>{};
    for (final entry in index.rooms.entries) {
      final messages = <Object?>[];
      for (final key in entry.value) {
        final page = await blobs.loadGroupBlob(ownerId, key);
        if (page == null ||
            'history_room_${sha256.convert(utf8.encode(page))}' != key) {
          throw const FormatException(
            'A saved conversation page is missing or damaged',
          );
        }
        final value = jsonDecode(page);
        if (value is! Map ||
            value['version'] != 1 ||
            value['messages'] is! List ||
            (value['messages'] as List).length > _pageMessages ||
            utf8.encode(page).length > maxPageBytes) {
          throw const FormatException('Invalid saved conversation page');
        }
        messages.addAll(value['messages'] as List);
      }
      rooms[entry.key] = messages;
    }
    return jsonEncode({...jsonDecode(index.metadata) as Map, 'rooms': rooms});
  });

  @override
  Future<void> save(String ownerId, String source) {
    final value = jsonDecode(source) as Map<String, dynamic>;
    final rooms = value.remove('rooms') as Map<String, dynamic>;
    return _serial(
      () => _save(ownerId, jsonEncode(value), {
        for (final entry in rooms.entries) entry.key: jsonEncode(entry.value),
      }, replace: true),
    );
  }

  @override
  Future<void> saveChanges(
    String ownerId,
    String metadata,
    Map<String, String?> rooms,
  ) => _serial(() => _save(ownerId, metadata, rooms));

  Future<void> _save(
    String owner,
    String metadata,
    Map<String, String?> changes, {
    bool replace = false,
  }) async {
    final decodedMetadata = jsonDecode(metadata);
    if (decodedMetadata is! Map ||
        ![5,6].contains(decodedMetadata['version']) ||
        decodedMetadata.containsKey('rooms')) {
      throw const FormatException('Invalid history metadata');
    }
    final priorSource = await blobs.loadGroupBlob(owner, indexKey);
    final prior = priorSource == null ? null : _Index.parse(priorSource);
    final rooms = <String, List<String>>{
      if (!replace && prior != null) ...prior.rooms,
    };
    final initial = <String, String?>{};
    if (prior == null && !replace) {
      final old = await legacy.load(owner);
      if (old != null) {
        final history = jsonDecode(old) as Map<String, dynamic>;
        for (final entry
            in (history['rooms'] as Map<String, dynamic>).entries) {
          final messages = (entry.value as List).map((item) {
            final message = Map<String, dynamic>.from(item as Map);
            if (history['version'] == 1 && message['incoming'] == true) {
              message['receivedAtMilliseconds'] = message['sentAtMilliseconds'];
              message['sentAtMilliseconds'] = null;
            }
            return message;
          }).toList();
          initial[entry.key] = jsonEncode(messages);
        }
      }
    }
    final existing = prior?.keys ?? <String>{};
    for (final entry in {...initial, ...changes}.entries) {
      if (entry.value == null) {
        rooms.remove(entry.key);
        continue;
      }
      final messages = jsonDecode(entry.value!) as List;
      final keys = <String>[];
      var page = <Object?>[];
      final headerBytes = utf8
          .encode(jsonEncode({'version': 1, 'messages': []}))
          .length;
      var pageBytes = headerBytes;
      Future<void> publish() async {
        if (page.isEmpty) return;
        final encoded = jsonEncode({'version': 1, 'messages': page});
        if (utf8.encode(encoded).length > maxPageBytes) {
          throw const FormatException(
            'A message is too large for history storage',
          );
        }
        final key = 'history_room_${sha256.convert(utf8.encode(encoded))}';
        if (!existing.contains(key)) {
          await blobs.saveGroupBlob(owner, key, encoded);
        }
        keys.add(key);
        page = [];
        pageBytes = headerBytes;
      }

      for (final message in messages) {
        final messageBytes = utf8.encode(jsonEncode(message)).length;
        if (page.length >= _pageMessages ||
            (page.isNotEmpty && pageBytes + messageBytes + 1 > maxPageBytes)) {
          await publish();
        }
        pageBytes += messageBytes + (page.isEmpty ? 0 : 1);
        page.add(message);
      }
      await publish();
      rooms[entry.key] = keys;
    }
    final index = _Index(metadata, rooms);
    _Index? older;
    try {
      final olderSource = await blobs.loadGroupBlob(owner, _previousKey);
      older = olderSource == null ? null : _Index.parse(olderSource);
    } catch (_) {
      // Unknown backup pages are retained; cleanup must not block a healthy
      // current commit. The current index above still fails closed.
    }
    if (priorSource != null) {
      await blobs.saveGroupBlob(owner, _previousKey, priorSource);
    }
    await blobs.saveGroupBlob(owner, indexKey, index.encode());
    // Readers and writes share this queue. Retain the previous committed pages
    // and untouched legacy history; only older, unreferenced generated pages go.
    final retained = {...index.keys, ...?prior?.keys};
    for (final key in older?.keys ?? <String>{}) {
      if (!retained.contains(key)) {
        try {
          await blobs.deleteGroupBlob(owner, key);
        } catch (_) {
          /* Cleanup cannot invalidate a durable commit. */
        }
      }
    }
  }
}

class _Index {
  _Index(this.metadata, this.rooms);
  final String metadata;
  final Map<String, List<String>> rooms;
  Set<String> get keys => rooms.values.expand((keys) => keys).toSet();
  String encode() =>
      jsonEncode({'version': 1, 'metadata': metadata, 'rooms': rooms});
  static _Index parse(String source) {
    final value = jsonDecode(source);
    if (value is! Map ||
        value['version'] != 1 ||
        value['metadata'] is! String ||
        value['rooms'] is! Map) {
      throw const FormatException('Invalid conversation index');
    }
    final metadata = jsonDecode(value['metadata'] as String);
    if (metadata is! Map ||
        ![5,6].contains(metadata['version']) ||
        metadata.containsKey('rooms')) {
      throw const FormatException('Invalid history metadata');
    }
    final rooms = <String, List<String>>{};
    for (final entry in (value['rooms'] as Map).entries) {
      if (entry.key is! String || entry.value is! List) {
        throw const FormatException('Invalid conversation index');
      }
      final keys = <String>[];
      for (final key in entry.value as List) {
        if (key is! String ||
            !RegExp(r'^history_room_[0-9a-f]{64}$').hasMatch(key)) {
          throw const FormatException('Invalid conversation page');
        }
        keys.add(key);
      }
      rooms[entry.key as String] = keys;
    }
    return _Index(value['metadata'] as String, rooms);
  }
}
