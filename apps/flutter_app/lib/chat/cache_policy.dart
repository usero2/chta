import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../groups/group_blob_bridge.dart';
import 'attachment_ref.dart';
import 'cache_space.dart';

class CachePolicyException implements Exception {
  const CachePolicyException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Logical reservations include pending jobs; no user file is auto-evicted.
class CachePolicy extends ChangeNotifier {
  CachePolicy({
    required this.ownerId,
    this.settings,
    Future<int?> Function()? availableSpace,
  }) : availableSpace = availableSpace ?? availableCacheSpace;
  static const gib = 1024 * 1024 * 1024;
  static const freeSpaceReserve = 256 * 1024 * 1024;
  static const _key = 'attachment_cache_budget_v1';
  final String ownerId;
  final GroupBlobBridge? settings;
  final Future<int?> Function() availableSpace;
  int limitBytes = 20 * gib;
  int get reservedBytes =>
      _entries.values.fold(0, (total, e) => total + e.size);
  int get _pendingBytes =>
      _entries.values.fold(0, (total, e) => total + e.size - e.written);
  final _entries = <String, _Entry>{};
  Future<void>? _initialization;
  Future<void> _tail = Future.value();
  bool _disposed = false, ready = false;
  int _progressRevision = 0, _savedProgressRevision = 0;
  final _writtenRevisions = <String, int>{};
  bool get _dirty => _progressRevision != _savedProgressRevision;
  int _pausedChanges = 0;
  bool get canChange => !_disposed && _pausedChanges == 0;
  Future<void> withChangesPaused(Future<void> Function() action) async {
    _pausedChanges++;
    _notify();
    try {
      await action();
    } finally {
      _pausedChanges--;
      _notify();
    }
  }

  String? error;
  static String referenceKey(AttachmentRef ref) =>
      ref.isChunked ? 'chunk_${ref.chunkedId}' : 'blob_${ref.digest}';
  int entrySize(String key) => _entries[key]?.size ?? 0;
  int entryWritten(String key) => _entries[key]?.written ?? 0;
  Iterable<String> get courierReservationKeys=>List<String>.unmodifiable(_entries.keys.where((key)=>key.startsWith('courier_')));
  void _guard() {
    if (_disposed) throw const CachePolicyException('Identity changed');
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() {
    if (_initialization case final pending?) return pending;
    final pending = _load();
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

  Future<void> _load() async {
    try {
      final source = await settings?.loadGroupBlob(ownerId, _key);
      _guard();
      if (source != null) {
        final value = jsonDecode(source);
        if (value is! Map ||
            value['version'] != 1 ||
            value['limitBytes'] is! int ||
            value['limitBytes'] < gib ||
            value['limitBytes'] > 1024 * gib ||
            value['entries'] is! Map) {
          throw const FormatException('Invalid cache settings');
        }
        final entries = <String, _Entry>{};
        for (final entry in (value['entries'] as Map).entries) {
          if (entry.key is! String ||
              !RegExp(r'^[A-Za-z0-9_-]{1,128}$')
                  .hasMatch(entry.key as String)) {
            throw const FormatException('Invalid cache entry');
          }
          entries[entry.key as String] = _Entry.parse(entry.value);
        }
        _entries.addAll(entries);
        limitBytes = value['limitBytes'] as int;
      }
      ready = true;
      error = null;
      _notify();
    } catch (_) {
      error = 'Could not load cache settings. Try again.';
      _notify();
      throw CachePolicyException(error!);
    }
  }

  Future<void> _queue(Future<void> Function() action) {
    final result = _tail.then((_) async {
      _guard();
      await initialize();
      _guard();
      await action();
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> _save(Map<String, _Entry> entries, int limit) async {
    _guard();
    final revision = _progressRevision;
    try {
      await settings?.saveGroupBlob(
        ownerId,
        _key,
        jsonEncode({
          'version': 1,
          'limitBytes': limit,
          'entries': {for (final e in entries.entries) e.key: e.value.json()},
        }),
      );
      _guard();
      // Progress can arrive while the protected settings write is awaiting I/O.
      // Merge it into the candidate without treating it as durably saved yet.
      if (revision != _progressRevision) {
        for (final key in _entries.keys.toList()) {
          if ((_writtenRevisions[key] ?? 0) <= revision) continue;
          final live = _entries[key]!;
          final candidate = entries[key];
          if (candidate == null) {
            entries[key] = live;
          } else if (live.written > candidate.written) {
            entries[key] = _Entry(
              candidate.size < live.written ? live.written : candidate.size,
              live.written,
            );
          }
        }
      }
      _savedProgressRevision = revision;
    } catch (_) {
      throw const CachePolicyException(
        'Could not save cache settings. Try again.',
      );
    }
  }

  Future<void> setLimitGiB(int value) {
    if (!canChange) {
      return Future.error(const CachePolicyException('Settings are locked.'));
    }
    return _queue(() async {
      if (value < 1 || value > 1024) {
        throw const CachePolicyException('Choose 1–1024 GB.');
      }
      await _save(_entries, value * gib);
      limitBytes = value * gib;
      error = null;
      _notify();
    });
  }

  Future<void> reserve(
    String key,
    int size, {
    bool recheckSpace = true,
    bool expandRetained = false,
  }) => _queue(() async {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(key) ||
        size < 0 ||
        size > 1024 * gib) {
      throw const CachePolicyException('Invalid cached file.');
    }
    final before = _entries[key];
    if (before != null &&
        before.size != size &&
        !(expandRetained &&
            before.size < size &&
            before.written == before.size)) {
      throw const CachePolicyException('Cached file size changed.');
    }
    final additional = size - (before?.size ?? 0);
    if (additional > 0 && reservedBytes + additional > limitBytes) {
      error = 'Cache limit reached. Change it in Profile.';
      _notify();
      throw CachePolicyException(error!);
    }
    final free = additional > 0 || recheckSpace ? await availableSpace() : null;
    _guard();
    if (free != null &&
        (additional > 0 || before?.written != size) &&
        free < _pendingBytes + additional + freeSpaceReserve) {
      error = 'Not enough storage. Free some space and retry.';
      _notify();
      throw CachePolicyException(error!);
    }
    if (before != null && additional == 0) return;
    final candidate = {..._entries, key: _Entry(size, before?.written ?? 0)};
    await _save(candidate, limitBytes);
    _entries[key] = candidate[key]!;
    error = null;
    _notify();
  });

  /// Aggregate Courier storage includes durable data and reserved assemblies.
  /// The caller proves physical cleanup before lowering either counter.
  Future<void> resizeCourierReservation(
    String key,
    int size,
    int written, {
    bool afterCleanup = false,
  }) => _queue(() async {
    final before = _entries[key];
    if (!key.startsWith('courier_') ||
        !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(key) ||
        size < 0 ||
        size > 1024 * gib ||
        written < 0 ||
        written > size ||
        (!afterCleanup &&
            before != null &&
            (size < before.size || written < before.written))) {
      throw const CachePolicyException('Invalid Courier reservation.');
    }
    final extra = size - (before?.size ?? 0);
    if (extra > 0 && reservedBytes + extra > limitBytes) {
      throw const CachePolicyException('Cache limit reached.');
    }
    final free = extra > 0 ? await availableSpace() : null;
    _guard();
    if (free != null && free < _pendingBytes + extra + freeSpaceReserve) {
      throw const CachePolicyException('Not enough storage.');
    }
    if (before?.size == size && before?.written == written) return;
    final candidate = {..._entries};
    if (size == 0) {
      candidate.remove(key);
    } else {
      candidate[key] = _Entry(size, written);
    }
    await _save(candidate, limitBytes);
    if (candidate[key] case final entry?) {
      _entries[key] = entry;
    } else {
      _entries.remove(key);
      _writtenRevisions.remove(key);
    }
    error = null;
    _notify();
  });

  /// A failed unpublished group import retains its existing encrypted pieces,
  /// but no longer reserves the portion that was never cached.
  Future<void> retainCached(String key) => _queue(() async {
    final entry = _entries[key];
    if (entry == null || entry.written == entry.size) return;
    final candidate = {..._entries};
    if (entry.written == 0) {
      candidate.remove(key);
    } else {
      candidate[key] = _Entry(entry.written, entry.written);
    }
    await _save(candidate, limitBytes);
    if (candidate[key] case final kept?) {
      _entries[key] = kept;
    } else {
      _entries.remove(key);
    }
    _notify();
  });
  Future<void> accountExisting(String key, int size, int written) =>
      _queue(() async {
        final previous = _entries[key];
        if (size < 0 ||
            written < 0 ||
            written > size ||
            !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(key)) {
          throw const CachePolicyException('Invalid cache entry.');
        }
        if (previous != null && previous.size != size) {
          throw const CachePolicyException('Cached file size changed.');
        }
        if (previous != null && previous.written >= written) return;
        final candidate = {..._entries, key: _Entry(size, written)};
        await _save(candidate, limitBytes);
        _entries[key] = candidate[key]!;
        _notify();
      });
  void noteWritten(String key, int bytes) {
    if (_disposed) return;
    final entry = _entries[key];
    if (entry != null && bytes > entry.written) {
      _entries[key] = _Entry(entry.size, bytes.clamp(0, entry.size));
      _writtenRevisions[key] = ++_progressRevision;
    }
  }

  Future<void> complete(String key) => _queue(() async {
    final entry = _entries[key];
    if (entry == null) return;
    final candidate = {..._entries, key: _Entry(entry.size, entry.size)};
    await _save(candidate, limitBytes);
    _entries[key] = candidate[key]!;
    error = null;
    _notify();
  });
  Future<void> release(String key) => _queue(() async {
    final candidate = {..._entries}..remove(key);
    await _save(candidate, limitBytes);
    if (candidate[key] case final live?) {
      _entries[key] = live;
    } else {
      _entries.remove(key);
      _writtenRevisions.remove(key);
    }
    _notify();
  });
  Future<void> reconcile(
    Iterable<({AttachmentRef ref, bool complete})> references,
  ) => _queue(() async {
    final candidate = {..._entries};
    var changed = false;
    for (final record in references) {
      final key = referenceKey(record.ref), previous = candidate[key];
      final size = record.ref.size;
      if (previous == null || record.complete && previous.written < size) {
        candidate[key] = _Entry(
          size,
          record.complete ? size : (previous?.written ?? 0),
        );
        changed = true;
      }
    }
    if (!changed) return;
    await _save(candidate, limitBytes);
    _entries
      ..clear()
      ..addAll(candidate);
    _notify();
  });
  Future<void> flush() async {
    // Catch one overlapping write without occupying an account's scheduler for
    // an entire active transfer. Further progress keeps its dirty revision.
    for (var pass = 0; pass < 2; pass++) {
      if (_dirty && !_disposed) {
        await _queue(() async {
          await _save(_entries, limitBytes);
        });
      }
      while (true) {
        final pending = _tail;
        await pending;
        if (identical(pending, _tail)) break;
      }
      if (!_dirty || _disposed) return;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class _Entry {
  const _Entry(this.size, this.written);
  final int size, written;
  Map<String, Object?> json() => {'size': size, 'written': written};
  static _Entry parse(Object? value) {
    if (value is! Map ||
        value['size'] is! int ||
        value['written'] is! int ||
        value['size'] < 0 ||
        value['size'] > 1024 * CachePolicy.gib ||
        value['written'] < 0 ||
        value['written'] > value['size']) {
      throw const FormatException('Invalid cache reservation');
    }
    return _Entry(value['size'] as int, value['written'] as int);
  }
}
