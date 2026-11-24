import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../chat/cache_policy.dart';
import '../delivery/delivery_crypto_bridge.dart';
import '../delivery/local_diagnostics.dart';
import '../groups/group_blob_bridge.dart';
import '../relay/relay_network.dart';
import '../seed/seed_client.dart';
import 'courier_directory.dart';
import 'courier_builder.dart';
import 'courier_journal.dart';
import 'courier_merkle.dart';
import 'courier_models.dart';
import 'courier_policy.dart';
import 'courier_store.dart';
import 'courier_transport.dart';
import 'sender_jobs.dart';

/// One unlocked account owns its host, discovery and durable sender jobs.
/// UI navigation does not create or discard Courier sessions.
class CourierService extends ChangeNotifier {
  CourierService({
    required this.ownerId,
    required this.crypto,
    required this.storage,
    required this.budget,
    required this.network,
    this.seed,
    CourierCarrier? carrier,
    this.canHost = false,
    this.allowLoopback = false,
    int Function()? clock,
    bool Function()? isCurrent,
  }) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
       _isCurrent = isCurrent ?? (() => true) {
    diagnostics = LocalDeliveryDiagnostics(
      owner: ownerId,
      storage: storage,
      isCurrent: () => !_closed && _isCurrent(),
    );
    directory = CourierDirectory(
      crypto: crypto,
      clock: _clock,
      allowLoopback: allowLoopback,
    );
    transport = CourierTransport(
      ownerId: ownerId,
      crypto: crypto,
      carrier: carrier ?? RelayCourierCarrier(network),
      clock: _clock,
      isCurrent: _active,
    );
    jobs = CourierSenderJobs(
      journal: CourierJournal(
        ownerId: ownerId,
        namespace: 'courier_send',
        storage: storage,
        isCurrent: _active,
      ),
      crypto: crypto,
      clock: _clock,
      isCurrent: _active,
    );
    _nodeJournal = CourierJournal(
      ownerId: ownerId,
      namespace: 'courier_node',
      storage: storage,
      isCurrent: _active,
    );
  }
  final String ownerId;
  final DeliveryCryptoBridge crypto;
  final GroupBlobBridge storage;
  final CachePolicy budget;
  final RelayNetwork network;
  final SeedClient? seed;
  final bool canHost, allowLoopback;
  final int Function() _clock;
  final bool Function() _isCurrent;
  late final CourierDirectory directory;
  late final LocalDeliveryDiagnostics diagnostics;
  late final CourierTransport transport;
  late final CourierSenderJobs jobs;
  late final CourierJournal _nodeJournal;
  CourierStore? hostStore;
  String? _nodeState;
  Map<String, Object?>? _certificate, _advertisement;
  Map<String, Object?>? get advertisement =>
      _advertisement == null ? null : Map.unmodifiable(_advertisement!);
  bool _closed = false, _started = false, _manualStop = false;
  bool _closing = false;
  int _lastAdvertisement = 0;
  Future<void>? _refreshing;
  Timer? _timer;
  final _subscriptions = <StreamSubscription<Object?>>[];
  final _trees = <String, CourierMerkleTree>{};
  final _cancelling = <String>{};
  String? error;
  bool _active() => !_closed && !_closing && _isCurrent();
  bool get hosting => _active() && transport.hosting;
  bool get ready => _active() && _started;
  bool get advertised => hosting && _advertisement != null;
  List<CourierNode> get availableForDeposit => directory.nodes
      .where((n) => n.ownerId != ownerId && transport.canReach(n))
      .toList();
  int get availableDepositRoots =>
      availableForDeposit.map((node) => node.ownerId).toSet().length;
  String diagnosticReport() => diagnostics.export(
    seed: seed == null
        ? DiagnosticSeed.unavailable
        : seed!.storageUnavailable
        ? DiagnosticSeed.quotaUnavailable
        : seed!.registered
        ? DiagnosticSeed.connected
        : DiagnosticSeed.connecting,
    activeRoutes: network.activeRouteCount,
    warmRoutes: network.warmRouteCount,
    knownCouriers: directory.nodes.length,
    hosting: hosting,
  );
  Future<void> setCapacityBytes(int bytes) async {
    _guard();
    final store = hostStore;
    if (!canHost || store == null) throw StateError('Courier host unavailable');
    await store.setCapacityBytes(bytes);
    _guard();
    _lastAdvertisement = 0;
    await refresh();
  }

  void _guard() {
    if (!_active()) throw StateError('Courier identity changed');
  }

  Future<void> start() async {
    _guard();
    if (_started) return;
    await jobs.initialize();
    await _nodeJournal.initialize();
    unawaited(diagnostics.load().catchError((Object _) {}));
    _guard();
    _started = true;
    _subscriptions.add(network.courierRecords.listen(_discovered));
    if (seed != null) {
      _subscriptions.add(seed!.courierRecords.listen(_discovered));
    }
    _timer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => unawaited(refresh().catchError((Object _) {})),
    );
    await refresh();
  }

  void _discovered(List<Object?> records) {
    if (_active()) {
      unawaited(directory.merge(records).catchError((Object _) {}));
    }
  }

  Future<void> setHosting(bool enabled) async {
    _guard();
    if (enabled && !canHost) {
      throw StateError('Courier hosting requires Desktop');
    }
    _manualStop = !enabled;
    if (!enabled) {
      transport.stopHost();
      _advertisement = null;
      final id = _certificate?['nodeId'];
      if (id is String) directory.withdraw(id);
      _publish();
      notifyListeners();
    } else {
      await refresh();
    }
  }

  Future<void> _startHost() async {
    final previous = _nodeState ?? await _nodeJournal.read('state');
    _guard();
    final node = await crypto.deliveryCall('nodeCertificate', {
      'now': _clock(),
      'state': ?previous,
    });
    _guard();
    final state = node['state'] as String,
        cert = Map<String, Object?>.from(node['certificate'] as Map);
    if (cert['ownerId'] != ownerId ||
        cert['nodeId'] is! String ||
        !courierHex(cert['nodeId'] as String, 64)) {
      throw const FormatException('Invalid Courier host certificate');
    }
    // Persist the protected random installation key before advertising any capability.
    await _nodeJournal.commit({'state': state}, {});
    _guard();
    _nodeState = state;
    _certificate = cert;
    if (!_manualStop) directory.allow(cert['nodeId'] as String);
    final store =
        hostStore ??
        CourierStore(
          nodeId: cert['nodeId'] as String,
          journal: CourierJournal(
            ownerId: ownerId,
            namespace: 'courier_host',
            storage: storage,
            isCurrent: _active,
          ),
          crypto: crypto,
          budget: budget,
          clock: _clock,
          isCurrent: _active,
        );
    hostStore = store;
    await transport.startHost(
      nodeState: state,
      certificate: cert,
      store: store,
    );
    _guard();
    if (_manualStop) {
      transport.stopHost();
      return;
    }
    _lastAdvertisement = 0;
  }

  List<String> get _routes => transport.carrier.online
      .where((url) {
        try {
          return (allowLoopback
                  ? normalizeRelayUrl(url)
                  : normalizePublicRelayUrl(url)) ==
              url;
        } catch (_) {
          return false;
        }
      })
      .take(8)
      .toList();
  void _publish() {
    if (!_active()) return;
    final catalog = directory.batch();
    network.publishCouriers(catalog);
    seed?.publishCouriers(catalog);
  }

  Future<void> refresh() {
    if (!_active()) {
      transport.stopHost();
      _advertisement = null;
      return Future.value();
    }
    if (!_started) return Future.value();
    return _refreshing ??= () async {
      try {
        directory.prune();
        if (canHost && !_manualStop && !transport.hosting) await _startHost();
        _guard();
        if (hosting) {
          await hostStore!.expire();
          _guard();
          final routes = _routes;
          if (routes.isNotEmpty &&
              (_advertisement == null ||
                  _clock() - _lastAdvertisement >= 30000 ||
                  jsonEncode((_advertisement!['body'] as Map)['routes']) !=
                      jsonEncode(routes))) {
            final ad = await crypto.deliveryCall('signControl', {
              'nodeState': _nodeState,
              'kind': 'advertisement',
              'challenge': 'A' * 43,
              'body': {
                'version': 1,
                'nodeId': _certificate!['nodeId'],
                'ownerId': ownerId,
                'routes': routes,
                'maxPackageBytes': courierPackageBytes,
                'freeBytes': max(
                  0,
                  hostStore!.availableBytes - CourierPolicy.metadataBytes,
                ),
              },
              'now': _clock(),
              'expiresAt': _clock() + 90000,
            });
            _guard();
            if (!_manualStop && hosting) {
              _advertisement = ad;
              _lastAdvertisement = _clock();
              await directory.merge([ad]);
            }
          } else if (routes.isEmpty && _advertisement != null) {
            _advertisement = null;
            final id = _certificate?['nodeId'];
            if (id is String) {
              directory.withdraw(id);
              directory.allow(id);
            }
          }
        }
        _guard();
        await jobs.expire();
        await collectTerminal();
        _publish();
        error = null;
      } catch (_) {
        if (_active()) {
          error = 'Courier unavailable';
          diagnostics.count(DeliveryMetric.failure);
        }
      } finally {
        _refreshing = null;
        if (_active()) notifyListeners();
      }
    }();
  }

  Future<CourierMerkleTree> _tree(String id) async {
    final old = _trees.remove(id);
    if (old != null) {
      _trees[id] = old;
      return old;
    }
    final tree = await CourierMerkleTree.build(await jobs.packageHashes(id));
    _guard();
    if (_trees.length >= 4) _trees.remove(_trees.keys.first);
    _trees[id] = tree;
    return tree;
  }

  Future<void> collectTerminal() async {
    _guard();
    await jobs.journal.recover();
    _guard();
    for (final key
        in budget.courierReservationKeys
            .where(
              (key) => RegExp(r'^courier_send_[0-9a-f]{32}$').hasMatch(key),
            )
            .toList()) {
      final id = key.substring('courier_send_'.length);
      if (jobs.find(id) == null && !jobs.isPreparing(id)) {
        await budget.resizeCourierReservation(key, 0, 0, afterCleanup: true);
        _guard();
      }
    }
    for (final job in jobs.jobs.where((j) => j.terminal).toList()) {
      if (jobs.find(job.id) == null) continue;
      if (job.status == CourierJobStatus.cancelled &&
          job.nodeIds.isNotEmpty &&
          job.expiresAt > _clock()) {
        _forwardCancellation(job.id);
        continue;
      }
      final forget =
              job.expiresAt + CourierPolicy.retentionMilliseconds <= _clock(),
          key = CourierBuilder.reservationKey(job.id);
      if (forget ||
          job.readyCount > 0 ||
          job.nodeIds.isNotEmpty ||
          budget.entrySize(key) > CourierPolicy.metadataBytes) {
        await jobs.purge(job.id, forget: forget);
        _guard();
        _trees.remove(job.id);
        await budget.resizeCourierReservation(
          key,
          forget ? 0 : CourierPolicy.metadataBytes,
          forget ? 0 : CourierPolicy.metadataBytes,
          afterCleanup: true,
        );
        _guard();
      }
    }
  }

  Future<void> cancel(String id) async {
    _guard();
    transport.cancelJob(id);
    if (jobs.find(id) == null) return;
    await jobs.cancel(id);
    _forwardCancellation(id);
  }

  void _forwardCancellation(String id) {
    final job = jobs.find(id);
    if (!_active() ||
        job == null ||
        job.status != CourierJobStatus.cancelled ||
        _cancelling.length >= 2 ||
        !_cancelling.add(id)) {
      return;
    }
    unawaited(() async {
      try {
        for (final node in directory.nodes.where(
          (n) => job.nodeIds.contains(n.nodeId) && transport.canReach(n),
        )) {
          if (!_active() ||
              jobs.find(id)?.status != CourierJobStatus.cancelled) {
            return;
          }
          try {
            await transport.request(node, kind: 'cancel', body: {'jobId': id});
            _guard();
            await jobs.acknowledgeCancellation(id, node.nodeId);
          } catch (_) {
            if (!_active()) return;
          }
        }
      } finally {
        _cancelling.remove(id);
      }
    }());
  }

  Future<void> forgetDelivered(String id) async {
    _guard();
    final job = jobs.find(id);
    if (job == null) return;
    // The caller first persisted an authenticated live or Courier recipient ACK.
    if (!job.terminal) await jobs.cancel(id);
    await jobs.purge(id, forget: true);
    _guard();
    _trees.remove(id);
    await budget.resizeCourierReservation(
      CourierBuilder.reservationKey(id),
      0,
      0,
      afterCleanup: true,
    );
  }

  /// Resume only committed allocations; a storage proof is never Delivered.
  Future<int> deposit(
    String id, {
    int limit = 4,
    bool Function()? isCurrent,
  }) async {
    _guard();
    if (limit < 1 || limit > 16) {
      throw const FormatException('Invalid deposit batch');
    }
    final nodes = availableForDeposit;
    await jobs.allocate(id, nodes, replicas: nodes.length >= 3 ? 2 : 1);
    _guard();
    final pending = await jobs.pendingDeposits(id, limit: limit);
    if (pending.isEmpty) return 0;
    final tree = await _tree(id);
    var stored = 0;
    for (final p in pending) {
      _guard();
      final job = jobs.find(id);
      if (job == null ||
          job.status != CourierJobStatus.depositing ||
          isCurrent?.call() == false) {
        break;
      }
      final node = nodes.where((n) => n.nodeId == p.nodeId).firstOrNull;
      if (node == null) continue;
      try {
        final bytes = await jobs.readPackage(id, p.index);
        _guard();
        final result = await transport.request(
          node,
          kind: 'store',
          body: {
            'nodeId': node.nodeId,
            'jobId': id,
            'mailbox': job.mailbox,
            'bucket': job.mailboxBucket,
            'count': job.packageCount,
            'index': p.index,
            'cipherBytes': bytes.length,
            'hash': p.hash,
            'root': tree.root,
            'proof': tree.proof(p.index),
            'manifestHash': job.manifestHash,
            'manifest': job.manifest,
            'expiresAt': job.expiresAt,
            'allocationRevision': p.allocationRevision,
          },
          upload: bytes,
          isCurrent: () =>
              _active() &&
              jobs.find(id)?.status == CourierJobStatus.depositing &&
              isCurrent?.call() != false,
        );
        _guard();
        await jobs.recordStorageAck(
          id,
          nodeId: node.nodeId,
          challenge: result.challenge,
          control: result.control,
        );
        stored++;
      } catch (_) {
        if (!_active()) rethrow;
        error = 'Courier unavailable';
      }
    }
    if (_active()) notifyListeners();
    return stored;
  }

  Future<List<Map<String, Object?>>> pickup(
    CourierNode node, {
    required int bucket,
    int cursor = 0,
  }) async {
    _guard();
    final result = await transport.request(
      node,
      kind: 'pickup',
      body: {'bucket': bucket, 'action': 'list', 'cursor': cursor},
    );
    _guard();
    final value = jsonDecode(utf8.decode(result.bytes!));
    if (value is! List || value.length > 16) {
      throw const FormatException('Invalid Courier mailbox page');
    }
    final records = <Map<String, Object?>>[];
    for (final v in value) {
      final m = Map<String, Object?>.from(v as Map);
      if (m.length != 10 ||
          m['jobKey'] is! String ||
          !courierHex(m['jobKey'] as String, 64) ||
          m['jobId'] is! String ||
          !courierHex(m['jobId'] as String, 32) ||
          m['count'] is! int ||
          m['root'] is! String ||
          !courierHex(m['root'] as String, 64) ||
          m['manifestHash'] is! String ||
          !courierHex(m['manifestHash'] as String, 64)) {
        throw const FormatException('Invalid Courier mailbox item');
      }
      final bitmap = IndexBitmap.fromEncoded(
        m['count'] as int,
        m['available'] as String,
      );
      if (bitmap.length >= bitmap.count) {
        throw const FormatException('Unsafe Courier allocation');
      }
      final checked = await crypto.deliveryCall('inspectManifest', {
        'manifest': m['manifest'],
        'now': _clock(),
      });
      _guard();
      if (checked['manifestHash'] != m['manifestHash'] ||
          checked['jobId'] != m['jobId'] ||
          checked['mailbox'] != m['mailbox'] ||
          checked['expiresAt'] != m['expiresAt']) {
        throw const FormatException('Courier manifest mismatch');
      }
      records.add(m);
    }
    return records;
  }

  Future<CourierStoredPackage> readPackage(
    CourierNode node,
    Map<String, Object?> item, {
    required int bucket,
    required int index,
  }) async {
    _guard();
    final result = await transport.request(
      node,
      kind: 'pickup',
      body: {
        'bucket': bucket,
        'action': 'package',
        'jobKey': item['jobKey'],
        'index': index,
      },
    );
    _guard();
    final metadata = Map<String, Object?>.from(
          (result.control['body'] as Map)['package'] as Map,
        ),
        bytes = result.bytes!;
    if (metadata['index'] != index ||
        metadata['count'] != item['count'] ||
        metadata['root'] != item['root'] ||
        bytes.length > courierPackageBytes + 40) {
      throw const FormatException('Courier package mismatch');
    }
    await crypto.deliveryCall('verifyPackage', {
      'index': index,
      'count': metadata['count'],
      'ciphertext': base64UrlEncode(bytes).replaceAll('=', ''),
      'hash': metadata['hash'],
      'root': metadata['root'],
      'proof': metadata['proof'],
    });
    _guard();
    return CourierStoredPackage(bytes, metadata);
  }

  Future<List<Map<String, Object?>>> receipts(
    CourierNode node,
    int bucket, {
    int cursor = 0,
  }) async {
    _guard();
    final result = await transport.request(
      node,
      kind: 'pickup',
      body: {'bucket': bucket, 'action': 'receipts', 'cursor': cursor},
    );
    _guard();
    final list = jsonDecode(utf8.decode(result.bytes!));
    if (list is! List || list.length > 16) {
      throw const FormatException('Invalid Courier receipts');
    }
    return list.map((v) => Map<String, Object?>.from(v as Map)).toList();
  }

  Future<void> depositReceipt(
    CourierNode node,
    Map<String, Object?> receipt,
  ) async {
    _guard();
    await transport.request(
      node,
      kind: 'pickup',
      body: {
        'bucket': _clock() ~/ CourierPolicy.retentionMilliseconds,
        'action': 'receipt',
        'receipt': receipt,
      },
    );
    _guard();
  }

  Future<void> acknowledgeReceipt(
    CourierNode node,
    Map<String, Object?> receipt,
    int bucket,
  ) async {
    _guard();
    final body = receipt['body'] as Map;
    await transport.request(
      node,
      kind: 'pickup',
      body: {
        'bucket': bucket,
        'action': 'receipt-ack',
        'jobId': body['jobId'],
        'manifestHash': body['manifestHash'],
        'recipientId': receipt['signerId'],
      },
    );
    _guard();
  }

  Future<void> close() async {
    if (_closed || _closing) return;
    _closing = true;
    transport.stopHost();
    _timer?.cancel();
    await diagnostics.flush().catchError((Object _) {});
    _closed = true;
    diagnostics.close();
    _advertisement = null;
    for (final s in _subscriptions) {
      await s.cancel();
    }
    _subscriptions.clear();
    await transport.close();
    hostStore?.close();
    jobs.close();
    _nodeJournal.close();
    directory.close();
    _trees.clear();
    dispose();
  }
}
