import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../groups/group_blob_bridge.dart';

/// Immutable protected values, paged indexes and a small two-phase root commit.
/// Only this namespace's unreachable physical copies can be garbage-collected.
class CourierJournal {
  CourierJournal({
    required this.ownerId,
    required this.namespace,
    required this.storage,
    bool Function()? isCurrent,
  }) : isCurrent = isCurrent ?? (() => true) {
    if (!RegExp(r'^courier_[a-z]{1,16}$').hasMatch(namespace)) {
      throw ArgumentError('Invalid Courier storage namespace');
    }
  }
  final String ownerId, namespace;
  final GroupBlobBridge storage;
  final bool Function() isCurrent;
  static const maxValueBytes = 512 * 1024;
  Map<String, String> _refs = {};
  List<String> _pending = [], _garbage = [];
  final _buckets = <String, Map<String, String>>{};
  int _sequence = 0;
  int _queued = 0;
  bool _closed = false;
  Future<void>? _initialization;
  Future<void> _tail = Future.value();
  Object? cleanupError;
  String get _rootKey => '${namespace}_root_v1';
  void _guard() {
    if (_closed || !isCurrent()) throw StateError('Courier identity changed');
  }

  bool _physical(String key) =>
      RegExp('^${namespace}_[0-9a-f]{32}\$').hasMatch(key);
  void _logical(String key) {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(key)) {
      throw const FormatException('Invalid Courier storage key');
    }
  }

  String _bucketId(String key) =>
      sha256.convert(utf8.encode(key)).toString().substring(0, 2);
  String _newPhysical() =>
      '${namespace}_${List.generate(16, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
  Future<T> _queue<T>(Future<T> Function() work) {
    if (_closed || _queued >= 16) {
      return Future.error(StateError('Courier storage busy'));
    }
    _queued++;
    final operation = _tail.then((_) => work()).whenComplete(() => _queued--);
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }

  Map<String, Object> _root({
    Map<String, String>? refs,
    List<String>? pending,
    List<String>? garbage,
    int? sequence,
  }) => {
    'version': 1,
    'buckets': refs ?? _refs,
    'pending': pending ?? _pending,
    'garbage': garbage ?? _garbage,
    'sequence': sequence ?? _sequence,
  };
  Future<void> _writeRoot(Map<String, Object> value) async {
    _guard();
    await storage.saveGroupBlob(ownerId, _rootKey, jsonEncode(value));
    _guard();
  }

  Future<void> initialize() {
    final existing = _initialization;
    if (existing != null) return existing;
    final pending = _initialize();
    _initialization = pending;
    unawaited(
      pending.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          if (identical(_initialization, pending)) _initialization = null;
        },
      ),
    );
    return pending;
  }

  Future<void> _initialize() async {
    _guard();
    final source = await storage.loadGroupBlob(ownerId, _rootKey);
    _guard();
    if (source != null) {
      if (utf8.encode(source).length > 65536) {
        throw const FormatException('Courier root too large');
      }
      final v = jsonDecode(source);
      if (v is! Map ||
          v.length != 5 ||
          v['version'] != 1 ||
          v['buckets'] is! Map ||
          v['pending'] is! List ||
          v['garbage'] is! List ||
          v['sequence'] is! int ||
          v['sequence'] < 0 ||
          v['sequence'] > 9007199254740990) {
        throw const FormatException('Invalid Courier root');
      }
      final refs = Map<String, String>.from(v['buckets'] as Map);
      final pending = List<String>.from(v['pending'] as List),
          garbage = List<String>.from(v['garbage'] as List);
      if (refs.length > 256 ||
          refs.entries.any(
            (e) =>
                !RegExp(r'^[0-9a-f]{2}$').hasMatch(e.key) ||
                !_physical(e.value),
          ) ||
          pending.length > 256 ||
          garbage.length > 256 ||
          [
            ...pending,
            ...garbage,
          ].any((k) => !_physical(k) || refs.containsValue(k))) {
        throw const FormatException('Unsafe Courier root');
      }
      _refs = refs;
      _pending = pending;
      _garbage = garbage;
      _sequence = v['sequence'] as int;
    }
    await _recover();
  }

  Future<void> _recover() async {
    if (_pending.isEmpty && _garbage.isEmpty) return;
    for (final key in {..._pending, ..._garbage}) {
      _guard();
      await storage.deleteGroupBlob(ownerId, key);
      _guard();
    }
    await _writeRoot(_root(pending: [], garbage: []));
    _pending = [];
    _garbage = [];
    cleanupError = null;
  }

  Future<Map<String, String>> _bucket(String id) async {
    if (_buckets[id] case final cached?) return cached;
    final ref = _refs[id];
    if (ref == null) return _buckets[id] = {};
    final source = await storage.loadGroupBlob(ownerId, ref);
    _guard();
    if (source == null || utf8.encode(source).length > maxValueBytes) {
      throw StateError('Courier index missing');
    }
    final decoded = jsonDecode(source);
    if (decoded is! Map || decoded.length > 1024) {
      throw const FormatException('Invalid Courier index');
    }
    final map = Map<String, String>.from(decoded);
    for (final e in map.entries) {
      _logical(e.key);
      if (_bucketId(e.key) != id || !_physical(e.value)) {
        throw const FormatException('Invalid Courier index entry');
      }
    }
    return _buckets[id] = map;
  }

  Future<String?> read(String key) => _queue(() async {
    await initialize();
    _guard();
    _logical(key);
    final ref = (await _bucket(_bucketId(key)))[key];
    if (ref == null) return null;
    final value = await storage.loadGroupBlob(ownerId, ref);
    _guard();
    if (value == null || utf8.encode(value).length > maxValueBytes) {
      throw StateError('Courier value missing');
    }
    return value;
  });
  Future<void> commit(
    Map<String, String> writes,
    Set<String> removes,
  ) => _queue(() async {
    await initialize();
    _guard();
    await _recover();
    if (writes.length + removes.length > 96 ||
        writes.keys.any(removes.contains) ||
        writes.values.any((v) => utf8.encode(v).length > maxValueBytes) ||
        writes.values.fold<int>(0, (n, v) => n + utf8.encode(v).length) >
            4 * 1024 * 1024) {
      throw const FormatException('Courier transaction too large');
    }
    if (writes.isEmpty && removes.isEmpty) return;
    final changed = <String, Map<String, String>>{},
        physicalWrites = <String, String>{},
        garbage = <String>{};
    for (final key in {...writes.keys, ...removes}) {
      _logical(key);
      final bucket = _bucketId(key);
      final page = changed[bucket] ??= Map<String, String>.from(
        await _bucket(bucket),
      );
      if (page[key] case final old?) garbage.add(old);
      if (writes.containsKey(key)) {
        final physical = _newPhysical();
        physicalWrites[physical] = writes[key]!;
        page[key] = physical;
      } else {
        page.remove(key);
      }
      if (page.length > 1024) {
        throw StateError('Courier index capacity reached');
      }
    }
    final refs = Map<String, String>.from(_refs);
    for (final entry in changed.entries) {
      if (refs[entry.key] case final old?) garbage.add(old);
      if (entry.value.isEmpty) {
        refs.remove(entry.key);
      } else {
        final physical = _newPhysical();
        physicalWrites[physical] = jsonEncode(entry.value);
        refs[entry.key] = physical;
      }
    }
    if (physicalWrites.length > 256 ||
        garbage.length > 256 ||
        _sequence >= 9007199254740990) {
      throw StateError('Courier journal capacity reached');
    }
    final staged = physicalWrites.keys.toList();
    await _writeRoot(_root(pending: staged));
    _pending = staged;
    for (final entry in physicalWrites.entries) {
      _guard();
      await storage.saveGroupBlob(ownerId, entry.key, entry.value);
      _guard();
    }
    await _writeRoot(
      _root(
        refs: refs,
        pending: [],
        garbage: garbage.toList(),
        sequence: _sequence + 1,
      ),
    );
    _refs = refs;
    _pending = [];
    _garbage = garbage.toList();
    _sequence++;
    _buckets.addAll(changed);
    try {
      await _recover();
    } catch (error) {
      cleanupError =
          error; /* Commit is already durable; do not retract a valid ACK. */
    }
  });
  void close() {
    _closed = true;
    _buckets.clear();
  }

  Future<void> recover() => _queue(() async {
    await initialize();
    _guard();
    await _recover();
  });
}
