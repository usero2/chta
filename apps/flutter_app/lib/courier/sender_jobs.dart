import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../delivery/delivery_crypto_bridge.dart';
import 'courier_journal.dart';
import 'courier_models.dart';
import 'distribution.dart';
import 'sender_job.dart';

class CourierDeposit {
  const CourierDeposit(
    this.jobId,
    this.nodeId,
    this.index,
    this.hash,
    this.bytes,
    this.allocationRevision,
  );
  final String jobId, nodeId, hash;
  final int index, bytes, allocationRevision;
}

class _NodeState {
  _NodeState(this.ever, this.assigned, this.acked, this.ownerId);
  final String ownerId;
  final IndexBitmap ever, assigned, acked;
  Map<String, Object> toJson() => {
    'ever': ever.encoded,
    'assigned': assigned.encoded,
    'acked': acked.encoded,
    'ownerId': ownerId,
  };
  factory _NodeState.empty(int count, String ownerId) => _NodeState(
    IndexBitmap(count),
    IndexBitmap(count),
    IndexBitmap(count),
    ownerId,
  );
  factory _NodeState.parse(int count, String source) {
    final v = jsonDecode(source) as Map;
    if (v.length != 4 ||
        v['ownerId'] is! String ||
        !RegExp(r'^did:cht:[0-9a-f]{64}$').hasMatch(v['ownerId'] as String)) {
      throw const FormatException('Invalid sender node state');
    }
    return _NodeState(
      IndexBitmap.fromEncoded(count, v['ever'] as String),
      IndexBitmap.fromEncoded(count, v['assigned'] as String),
      IndexBitmap.fromEncoded(count, v['acked'] as String),
      v['ownerId'] as String,
    );
  }
}

/// The protected sender outbox remains authoritative until a recipient proof.
class CourierSenderJobs {
  CourierSenderJobs({
    required this.journal,
    required this.crypto,
    int Function()? clock,
    bool Function()? isCurrent,
  }) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
       _isCurrent = isCurrent ?? (() => true);
  final CourierJournal journal;
  final DeliveryCryptoBridge crypto;
  final int Function() _clock;
  final bool Function() _isCurrent;
  final _jobs = <String, CourierSenderJob>{};
  final _nodeCache = <String, _NodeState>{};
  final _preparations = <String>{};
  bool isPreparing(String id) => _preparations.contains(id);
  Future<T> withPreparation<T>(String id, Future<T> Function() action) async {
    _guard();
    if (_preparations.length >= 4 || !_preparations.add(id)) {
      throw StateError('Courier preparation busy');
    }
    try {
      return await action();
    } finally {
      _preparations.remove(id);
    }
  }

  Future<void>? _initialization;
  Future<void> _tail = Future.value();
  int _queued = 0;
  bool _closed = false;
  List<CourierSenderJob> get jobs => List.unmodifiable(_jobs.values);
  CourierSenderJob? find(String id) => _jobs[id];
  void _guard() {
    if (_closed || !_isCurrent()) throw StateError('Courier identity changed');
  }

  Future<T> _queue<T>(Future<T> Function() action) {
    if (_closed || _queued >= 32) {
      return Future.error(StateError('Courier sender busy'));
    }
    _queued++;
    final operation = _tail
        .then((_) async {
          await initialize();
          _guard();
          return action();
        })
        .whenComplete(() => _queued--);
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
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
    await journal.initialize();
    _guard();
    final source = await journal.read('registry');
    _guard();
    if (source == null) return;
    final ids = List<String>.from(jsonDecode(source) as List);
    if (ids.length > 128 ||
        ids.toSet().length != ids.length ||
        ids.any((id) => !courierHex(id, 32))) {
      throw const FormatException('Invalid sender registry');
    }
    final loaded = <String, CourierSenderJob>{};
    for (final id in ids) {
      final text = await journal.read('job_$id');
      _guard();
      if (text == null) throw StateError('Courier sender job missing');
      final job = CourierSenderJob.fromJson(
        Map<String, Object?>.from(jsonDecode(text) as Map),
      );
      if (job.id != id) throw const FormatException('Sender job ID mismatch');
      loaded[id] = job;
    }
    _jobs.addAll(loaded);
  }

  CourierSenderJob _job(String id) =>
      _jobs[id] ?? (throw StateError('Courier job missing'));
  CourierSenderJob _next(CourierSenderJob job, Map<String, Object?> changes) =>
      CourierSenderJob.fromJson({
        ...job.toJson(),
        'revision': job.revision + 1,
        ...changes,
      });
  Future<void> _save(
    CourierSenderJob job, {
    Map<String, String> pages = const {},
    Set<String> deletes = const {},
  }) async {
    await journal.commit({
      ...pages,
      'job_${job.id}': jsonEncode(job.toJson()),
    }, deletes);
    _guard();
    _jobs[job.id] = job;
  }

  Future<void> create(CourierSenderJob job) => _queue(() async {
    if (_jobs.containsKey(job.id)) {
      throw StateError('Courier job already exists');
    }
    if (_jobs.length >= 128) throw StateError('Courier sender queue full');
    if (job.status != CourierJobStatus.preparing || job.expiresAt <= _clock()) {
      throw StateError('Invalid new Courier job');
    }
    await journal.commit({
      'registry': jsonEncode([..._jobs.keys, job.id]),
      'job_${job.id}': jsonEncode(job.toJson()),
    }, {});
    _guard();
    _jobs[job.id] = job;
  });
  static String packageHash(int index, Uint8List bytes) {
    final i = ByteData(4)..setUint32(0, index, Endian.big);
    final value = BytesBuilder(copy: false)
      ..add(utf8.encode('chta courier leaf v1\u0000'))
      ..add(i.buffer.asUint8List())
      ..add(bytes);
    return sha256.convert(value.takeBytes()).toString();
  }

  String _pageKey(String id, int index) => 'packages_${id}_${index ~/ 128}';
  Future<Map<String, dynamic>> _page(String id, int index) async {
    final source = await journal.read(_pageKey(id, index));
    _guard();
    if (source == null) return {};
    final value = Map<String, dynamic>.from(jsonDecode(source) as Map);
    if (value.length > 128) {
      throw const FormatException('Package page too large');
    }
    return value;
  }

  Future<Map<String, dynamic>> _descriptor(
    CourierSenderJob job,
    int index,
  ) async {
    if (index < 0 || index >= job.packageCount || !job.hasPackage(index)) {
      throw StateError('Courier package missing');
    }
    final value = (await _page(job.id, index))['$index'];
    if (value is! Map ||
        (value.length != 2 && value.length != 3) ||
        (value.containsKey('plaintextHash') &&
            (value['plaintextHash'] is! String ||
                !courierHex(value['plaintextHash'] as String, 64))) ||
        value['hash'] is! String ||
        !courierHex(value['hash'] as String, 64) ||
        value['bytes'] is! int ||
        value['bytes'] < 40 ||
        value['bytes'] > courierPackageBytes + 40) {
      throw const FormatException('Invalid package descriptor');
    }
    return Map<String, dynamic>.from(value);
  }

  Future<String?> preparedPlaintextHash(String id, int index) => _queue(
    () async =>
        (await _descriptor(_job(id), index))['plaintextHash'] as String?,
  );
  Future<void> stagePackage(
    String id,
    int index,
    Uint8List ciphertext, {
    String? plaintextHash,
  }) => _queue(() async {
    final job = _job(id);
    if (job.terminal ||
        job.manifest != null ||
        job.status == CourierJobStatus.paused ||
        index < 0 ||
        index >= job.packageCount ||
        ciphertext.length < 40 ||
        ciphertext.length > courierPackageBytes + 40 ||
        (plaintextHash != null && !courierHex(plaintextHash, 64))) {
      throw StateError('Courier job cannot prepare this package');
    }
    final hash = packageHash(index, ciphertext);
    if (job.hasPackage(index)) {
      final previous = await _descriptor(job, index);
      if (previous['hash'] != hash ||
          (plaintextHash != null &&
              previous['plaintextHash'] != plaintextHash)) {
        throw StateError('Courier package is immutable');
      }
      return;
    }
    final page = await _page(id, index);
    page['$index'] = {
      'hash': hash,
      'bytes': ciphertext.length,
      'plaintextHash': ?plaintextHash,
    };
    final ready = IndexBitmap.fromEncoded(job.packageCount, job.readyEncoded)
      ..mark(index);
    await _save(
      _next(job, {'ready': ready.encoded}),
      pages: {
        'cipher_${id}_$index': base64UrlEncode(ciphertext).replaceAll('=', ''),
        _pageKey(id, index): jsonEncode(page),
      },
    );
  });
  Future<List<String>> packageHashes(String id) => _queue(() async {
    final job = _job(id);
    if (job.readyCount != job.packageCount) {
      throw StateError('Courier preparation incomplete');
    }
    final result = <String>[];
    for (var page = 0; page < job.packageCount; page += 128) {
      final entries = await _page(id, page);
      for (var i = page; i < page + 128 && i < job.packageCount; i++) {
        final descriptor = entries['$i'];
        if (descriptor is! Map ||
            descriptor['hash'] is! String ||
            !courierHex(descriptor['hash'] as String, 64)) {
          throw StateError('Courier package missing');
        }
        result.add(descriptor['hash'] as String);
      }
    }
    return result;
  });
  Future<Uint8List> readPackage(String id, int index) => _queue(() async {
    final job = _job(id);
    if (job.status != CourierJobStatus.depositing ||
        job.expiresAt <= _clock()) {
      throw StateError('Courier job is not depositing');
    }
    final d = await _descriptor(job, index),
        source = await journal.read('cipher_${id}_$index');
    _guard();
    if (source == null) throw StateError('Courier package missing');
    final bytes = base64Url.decode(base64Url.normalize(source));
    if (bytes.length != d['bytes'] || packageHash(index, bytes) != d['hash']) {
      throw StateError('Courier spool damaged');
    }
    return bytes;
  });
  Future<void> setManifest(
    String id,
    Map<String, Object?> manifest,
    String hash,
    String merkleRoot,
  ) => _queue(() async {
    final job = _job(id);
    if (job.manifest != null) {
      if (job.manifestHash == hash &&
          jsonEncode(job.manifest) == jsonEncode(manifest)) {
        return;
      }
      throw StateError('Courier manifest is immutable');
    }
    if (job.readyCount != job.packageCount ||
        job.terminal ||
        job.status == CourierJobStatus.paused ||
        !courierHex(hash, 64) ||
        !courierHex(merkleRoot, 64) ||
        manifest.length != 5 ||
        manifest['version'] != 1 ||
        manifest['jobId'] != id ||
        manifest['mailbox'] != job.mailbox ||
        manifest['expiresAt'] != job.expiresAt ||
        manifest['box'] is! String ||
        (manifest['box'] as String).length > 21846) {
      throw const FormatException('Invalid Courier manifest');
    }
    await _save(
      _next(job, {
        'manifest': manifest,
        'manifestHash': hash,
        'merkleRoot': merkleRoot,
        'status': CourierJobStatus.waitingForNodes.name,
      }),
    );
  });
  String _nodeKey(String job, String node) => 'node_${job}_$node';
  Future<_NodeState> _node(CourierSenderJob job, String node) async {
    final key = _nodeKey(job.id, node);
    if (_nodeCache[key] case final cached?) return cached;
    final source = await journal.read(key);
    _guard();
    if (source == null && job.nodeIds.contains(node)) {
      throw StateError('Courier allocation page missing');
    }
    if (source == null) throw StateError('Courier allocation missing');
    final state = _NodeState.parse(job.packageCount, source);
    _cacheNode(key, state);
    return state;
  }

  void _cacheNode(String key, _NodeState state) {
    _nodeCache.remove(key);
    _nodeCache[key] = state;
    while (_nodeCache.length > 256) {
      _nodeCache.remove(_nodeCache.keys.first);
    }
  }

  Future<void> allocate(
    String id,
    List<CourierNode> nodes, {
    int replicas = 1,
  }) => _queue(() async {
    final job = _job(id);
    if (job.terminal ||
        job.status == CourierJobStatus.paused ||
        job.status == CourierJobStatus.stored) {
      return;
    }
    if (job.manifest == null || job.readyCount != job.packageCount) {
      throw StateError('Prepare Courier packages first');
    }
    final previous = <String, _NodeState>{
      for (final node in job.nodeIds) node: await _node(job, node),
    };
    final sizes = <int>[];
    for (var page = 0; page < job.packageCount; page += 128) {
      final entries = await _page(id, page);
      for (var i = page; i < page + 128 && i < job.packageCount; i++) {
        sizes.add((entries['$i'] as Map)['bytes'] as int);
      }
    }
    final plan = DistributionPlan.allocate(
      count: job.packageCount,
      nodes: nodes,
      everAssigned: previous.map((k, v) => MapEntry(k, v.ever)),
      storedOnNodes: previous.map((k, v) => MapEntry(k, v.acked)),
      routingRoots: previous.map((k, v) => MapEntry(k, v.ownerId)),
      packageSizes: sizes,
      now: _clock(),
      replicas: replicas,
    );
    if (!plan.canDeposit) {
      if (job.status != CourierJobStatus.waitingForNodes) {
        await _save(
          _next(job, {'status': CourierJobStatus.waitingForNodes.name}),
        );
      }
      return;
    }
    final states = <String, _NodeState>{};
    for (final entry in plan.assignments.entries) {
      final old =
          previous[entry.key] ??
          _NodeState.empty(
            job.packageCount,
            nodes.firstWhere((n) => n.nodeId == entry.key).ownerId,
          );
      states[entry.key] = _NodeState(
        plan.everAssigned[entry.key]!,
        entry.value,
        old.acked.copy(),
        old.ownerId,
      );
    }
    final same =
        job.activeNodeIds.toSet().length == states.length &&
        job.activeNodeIds.every(
          (node) =>
              states[node]?.assigned.encoded ==
              previous[node]?.assigned.encoded,
        );
    if (same && job.status == CourierJobStatus.depositing ||
        same && job.status == CourierJobStatus.stored) {
      return;
    }
    final next = _next(job, {
      'nodeIds': plan.everAssigned.keys.toList(),
      'activeNodeIds': states.keys.toList(),
      'allocationRevision': job.allocationRevision + 1,
      'status': CourierJobStatus.depositing.name,
    });
    await _save(
      next,
      pages: {
        for (final entry in states.entries)
          _nodeKey(id, entry.key): jsonEncode(entry.value.toJson()),
      },
    );
    for (final entry in states.entries) {
      _cacheNode(_nodeKey(id, entry.key), entry.value);
    }
  });
  Future<List<CourierDeposit>> pendingDeposits(String id, {int limit = 16}) =>
      _queue(() async {
        final job = _job(id);
        if (job.status != CourierJobStatus.depositing ||
            job.expiresAt <= _clock()) {
          return [];
        }
        if (limit < 1 || limit > 64 || job.activeNodeIds.length < 2) {
          throw StateError('Unsafe Courier dispatch');
        }
        final states = <String, _NodeState>{
          for (final n in job.activeNodeIds) n: await _node(job, n),
        };
        for (final s in states.values) {
          if (s.ever.length >= job.packageCount ||
              s.assigned.length >= job.packageCount) {
            throw StateError('Unsafe Courier allocation');
          }
        }
        final positions = {for (final n in states.keys) n: 0},
            result = <CourierDeposit>[];
        var more = true;
        while (result.length < limit && more) {
          more = false;
          for (final entry in states.entries) {
            var index = positions[entry.key]!;
            while (index < job.packageCount &&
                (!entry.value.assigned.contains(index) ||
                    entry.value.acked.contains(index))) {
              index++;
            }
            positions[entry.key] = index + 1;
            if (index >= job.packageCount) continue;
            more = true;
            final d = await _descriptor(job, index);
            result.add(
              CourierDeposit(
                id,
                entry.key,
                index,
                d['hash'] as String,
                d['bytes'] as int,
                job.allocationRevision,
              ),
            );
            if (result.length == limit) break;
          }
        }
        return result;
      });
  Future<bool> _allStored(
    CourierSenderJob job, {
    String? changedNode,
    _NodeState? changed,
  }) async {
    if (job.activeNodeIds.length < 2) return false;
    final rows = <_NodeState>[];
    for (final n in job.activeNodeIds) {
      final state = n == changedNode ? changed! : await _node(job, n);
      if (state.assigned.length == 0 ||
          state.assigned.length >= job.packageCount ||
          state.ever.length >= job.packageCount) {
        throw StateError('Unsafe Courier allocation');
      }
      if (state.assigned.intersectionLength(state.acked) !=
          state.assigned.length) {
        return false;
      }
      rows.add(state);
    }
    final covered = IndexBitmap(job.packageCount);
    for (final row in rows) {
      covered.merge(row.assigned);
    }
    return covered.length == job.packageCount;
  }

  Future<void> recordStorageAck(
    String id, {
    required String nodeId,
    required String challenge,
    required Map<String, Object?> control,
  }) => _queue(() async {
    final job = _job(id);
    if (job.terminal || job.expiresAt <= _clock()) return;
    if (!job.activeNodeIds.contains(nodeId)) {
      throw StateError('Unknown allocation node');
    }
    final verified = await crypto.deliveryCall('verifyControl', {
      'control': control,
      'expectedSigner': nodeId,
      'challenge': challenge,
      'now': _clock(),
    });
    _guard();
    final body = verified['body'];
    if (verified['kind'] != 'stored' ||
        body is! Map ||
        body['jobId'] != id ||
        body['allocationRevision'] != job.allocationRevision ||
        body['index'] is! int) {
      throw const FormatException('Invalid storage ACK');
    }
    final index = body['index'] as int, state = await _node(job, nodeId);
    if (!state.assigned.contains(index) ||
        (await _descriptor(job, index))['hash'] != body['hash']) {
      throw const FormatException('Storage ACK package mismatch');
    }
    if (state.acked.contains(index)) return;
    final updated = _NodeState(
      state.ever.copy(),
      state.assigned.copy(),
      state.acked.copy()..mark(index),
      state.ownerId,
    );
    final all = await _allStored(job, changedNode: nodeId, changed: updated);
    final next = _next(job, {
      'status': job.status == CourierJobStatus.paused
          ? job.status.name
          : all
          ? CourierJobStatus.stored.name
          : job.status.name,
    });
    await _save(
      next,
      pages: {_nodeKey(id, nodeId): jsonEncode(updated.toJson())},
    );
    _cacheNode(_nodeKey(id, nodeId), updated);
  });
  Future<void> recordReceipt(String id, Map<String, Object?> control) =>
      _queue(() async {
        final job = _job(id);
        final verified = await crypto.deliveryCall('verifyControl', {
          'control': control,
          'expectedSigner': job.peerId,
          'challenge': job.receiptChallenge,
          'now': _clock(),
        });
        _guard();
        final body = verified['body'];
        if (verified['kind'] != 'receipt' ||
            body is! Map ||
            body['jobId'] != id ||
            body['messageId'] != job.messageId ||
            body['manifestHash'] != job.manifestHash ||
            job.manifestHash == null ||
            body['receivedAt'] is! int ||
            body['receivedAt'] < 0 ||
            body['receivedAt'] > 9007199254740991 ||
            body['receivedAt'] > _clock() + 300000) {
          throw const FormatException('Invalid recipient receipt');
        }
        if (job.status == CourierJobStatus.delivered) return;
        await _save(
          _next(job, {
            'status': CourierJobStatus.delivered.name,
            'receivedAt': body['receivedAt'],
          }),
        );
      });
  Future<void> pause(String id) => _queue(() async {
    final job = _job(id);
    if (!job.terminal && job.status != CourierJobStatus.paused) {
      await _save(_next(job, {'status': CourierJobStatus.paused.name}));
    }
  });
  Future<void> resume(String id) => _queue(() async {
    final job = _job(id);
    if (job.status != CourierJobStatus.paused) return;
    final status = job.manifest == null
        ? CourierJobStatus.preparing
        : await _allStored(job)
        ? CourierJobStatus.stored
        : job.activeNodeIds.length >= 2
        ? CourierJobStatus.depositing
        : CourierJobStatus.waitingForNodes;
    await _save(_next(job, {'status': status.name}));
  });
  Future<void> cancel(String id) => _queue(() async {
    final job = _job(id);
    if (!job.terminal) {
      await _save(
        _next(job, {
          'status': CourierJobStatus.cancelled.name,
          'cancelled': true,
        }),
      );
    }
  });
  Future<void> expire() => _queue(() async {
    for (final job in _jobs.values.toList()) {
      if (!job.terminal && job.expiresAt <= _clock()) {
        await _save(_next(job, {'status': CourierJobStatus.expired.name}));
      }
    }
  });

  Future<void> acknowledgeCancellation(String id, String nodeId) =>
      _queue(() async {
        final job = _jobs[id];
        if (job == null ||
            job.status != CourierJobStatus.cancelled ||
            !job.nodeIds.contains(nodeId)) {
          return;
        }
        final next = _next(job, {
          'nodeIds': job.nodeIds.where((n) => n != nodeId).toList(),
          'activeNodeIds': job.activeNodeIds.where((n) => n != nodeId).toList(),
        });
        await _save(next, deletes: {_nodeKey(id, nodeId)});
        _nodeCache.remove(_nodeKey(id, nodeId));
      });

  /// Only terminal private spools are reclaimed. Original attachments/history
  /// are separate stores. Keep minimal proof state until its bounded tombstone expires.
  Future<void> purge(String id, {bool forget = false}) => _queue(() async {
    final job = _job(id);
    if (!job.terminal) throw StateError('Courier job is still active');
    final indices = [
      for (var i = 0; i < job.packageCount; i++)
        if (job.hasPackage(i)) i,
    ];
    for (var start = 0; start < indices.length; start += 64) {
      await journal.commit(
        {},
        indices.skip(start).take(64).map((i) => 'cipher_${id}_$i').toSet(),
      );
      _guard();
    }
    final keys = <String>{
      for (final i in indices) _pageKey(id, i),
      for (final node in job.nodeIds) _nodeKey(id, node),
    }.toList();
    for (var start = 0; start < keys.length; start += 64) {
      await journal.commit({}, keys.skip(start).take(64).toSet());
      _guard();
    }
    await journal.recover();
    _guard();
    if (forget) {
      await journal.commit(
        {'registry': jsonEncode(_jobs.keys.where((key) => key != id).toList())},
        {'job_$id'},
      );
      _guard();
      _jobs.remove(id);
    } else if (job.readyCount != 0 || job.nodeIds.isNotEmpty) {
      await _save(
        _next(job, {
          'ready': IndexBitmap(job.packageCount).encoded,
          'nodeIds': <String>[],
          'activeNodeIds': <String>[],
        }),
      );
    }
    await journal.recover();
    _guard();
    _nodeCache.removeWhere((key, _) => key.startsWith('node_${id}_'));
  });
  void close() {
    _closed = true;
    _nodeCache.clear();
    journal.close();
  }
}
