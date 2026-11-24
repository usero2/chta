import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../chat/cache_policy.dart';
import '../delivery/delivery_crypto_bridge.dart';
import 'courier_journal.dart';
import 'courier_models.dart';
import 'courier_policy.dart';

class CourierLease {
  const CourierLease({
    this.id,
    required this.alreadyStored,
    this.missingParts = const [],
  });
  final String? id;
  final bool alreadyStored;
  final List<int> missingParts;
}

class CourierStoredPackage {
  const CourierStoredPackage(this.bytes, this.metadata);
  final Uint8List bytes;
  final Map<String, Object?> metadata;
}

class _HostJob {
  _HostJob(
    this.key,
    this.sender,
    this.publicKey,
    this.body,
    this.ever,
    this.stored, {
    this.cost = 0,
    this.state = 'active',
    this.until = 0,
  });
  final String key, sender, publicKey;
  final Map<String, Object?> body;
  final IndexBitmap ever, stored;
  final int cost, until;
  final String state;
  int get count => body['count'] as int;
  int get expires => body['expiresAt'] as int;
  String get id => body['jobId'] as String;
  String get mailbox => body['mailbox'] as String;
  int get bucket => body['bucket'] as int;
  _HostJob changed({
    IndexBitmap? ever,
    IndexBitmap? stored,
    int? cost,
    String? state,
    int? until,
  }) => _HostJob(
    key,
    sender,
    publicKey,
    body,
    ever ?? this.ever,
    stored ?? this.stored,
    cost: cost ?? this.cost,
    state: state ?? this.state,
    until: until ?? this.until,
  );
  Map<String, Object?> toJson() => {
    'key': key,
    'sender': sender,
    'publicKey': publicKey,
    'body': body,
    'ever': ever.encoded,
    'stored': stored.encoded,
    'cost': cost,
    'state': state,
    'until': until,
  };
  factory _HostJob.parse(String source) {
    final v = jsonDecode(source) as Map;
    final body = Map<String, Object?>.from(v['body'] as Map);
    final count = body['count'] as int;
    final result = _HostJob(
      v['key'] as String,
      v['sender'] as String,
      v['publicKey'] as String,
      body,
      IndexBitmap.fromEncoded(count, v['ever'] as String),
      IndexBitmap.fromEncoded(count, v['stored'] as String),
      cost: v['cost'] as int,
      state: v['state'] as String,
      until: v['until'] as int,
    );
    if (v.length != 9 ||
        !courierHex(result.key, 64) ||
        result.ever.length >= count ||
        result.cost < 0) {
      throw const FormatException('Invalid Courier job index');
    }
    return result;
  }
}

class _Assembly {
  _Assembly(this.id, this.jobKey, this.offer, this.deadline);
  final String id, jobKey;
  final Map<String, Object?> offer;
  final int deadline;
  final parts = <int, Uint8List>{};
  int get size => offer['cipherBytes'] as int;
  int get index => offer['index'] as int;
  int get count => (size + 8191) ~/ 8192;
  int get cost => CourierPolicy.packageCost(size);
  Map<String, Object?> toJson() => {
    'id': id,
    'jobKey': jobKey,
    'offer': offer,
    'deadline': deadline,
  };
}

/// Stores ciphertext and opaque routing metadata. No recipient keys or plaintext.
class CourierStore {
  CourierStore({
    required this.nodeId,
    required this.journal,
    required this.crypto,
    required this.budget,
    CourierPolicy policy = const CourierPolicy(),
    int Function()? clock,
    bool Function()? isCurrent,
  }) : _policy = policy,
       _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
       _isCurrent = isCurrent ?? (() => true) {
    policy.validate();
    if (!courierHex(nodeId, 64)) {
      throw const FormatException('Invalid host node');
    }
  }
  final String nodeId;
  final CourierJournal journal;
  final DeliveryCryptoBridge crypto;
  final CachePolicy budget;
  CourierPolicy _policy;
  CourierPolicy get policy => _policy;
  final int Function() _clock;
  final bool Function() _isCurrent;
  final _jobs = <String, _HostJob>{}, _assemblies = <String, _Assembly>{};
  final _receipts = <String, Map<String, Object?>>{};
  Future<void>? _initialization;
  Future<void> _tail = Future.value();
  bool _closed = false;
  int _queued = 0, _held = 0;
  int get assemblyCount => _assemblies.length;
  int get jobCount => _jobs.length;
  int get _receiptCost => _receipts.length * CourierPolicy.receiptBytes;
  int get storedBytes =>
      CourierPolicy.metadataBytes * (1 + _jobs.length) +
      _jobs.values.fold<int>(0, (n, j) => n + j.cost) +
      _receiptCost +
      _held;
  int get reservedBytes =>
      storedBytes + _assemblies.values.fold<int>(0, (n, a) => n + a.cost);
  int get availableBytes => max(0, _policy.capacityBytes - reservedBytes);
  String get _budgetKey => 'courier_host_$nodeId';
  void _guard() {
    if (_closed || !_isCurrent()) throw StateError('Courier identity changed');
  }

  Future<T> _queue<T>(Future<T> Function() work) {
    if (_closed || _queued >= _policy.maxRequests) {
      return Future.error(StateError('Courier busy'));
    }
    _queued++;
    final task = _tail
        .then((_) async {
          await initialize();
          _guard();
          return work();
        })
        .whenComplete(() => _queued--);
    _tail = task.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return task;
  }

  Future<void> initialize() {
    final old = _initialization;
    if (old != null) return old;
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

  Map<String, Object?> _meta({
    Iterable<String>? jobs,
    Iterable<String>? leases,
    int? held,
    Map<String, Map<String, Object?>>? receipts,
    CourierPolicy? policy,
  }) => {
    'version': 1,
    'nodeId': nodeId,
    'jobs': (jobs ?? _jobs.keys).toList(),
    'leases': (leases ?? _assemblies.keys).toList(),
    'held': held ?? _held,
    'receipts': receipts ?? _receipts,
    'policy': (policy ?? _policy).toJson(),
  };
  Future<void> _initialize() async {
    await budget.initialize();
    await journal.initialize();
    _guard();
    final source = await journal.read('registry');
    _guard();
    if (source != null) {
      final meta = jsonDecode(source) as Map;
      if (meta['version'] != 1 ||
          meta['nodeId'] != nodeId ||
          meta.length != 7) {
        throw const FormatException('Invalid Courier host registry');
      }
      final ids = List<String>.from(meta['jobs'] as List),
          leases = List<String>.from(meta['leases'] as List);
      if (ids.length > 1024 ||
          ids.toSet().length != ids.length ||
          ids.any((id) => !courierHex(id, 64)) ||
          leases.length > 4 ||
          leases.any((id) => !courierHex(id, 32))) {
        throw const FormatException('Courier host count limit');
      }
      _policy = CourierPolicy.fromJson(
        Map<String, dynamic>.from(meta['policy'] as Map),
      );
      for (final id in ids) {
        final text = await journal.read('job_$id');
        _guard();
        if (text == null) throw StateError('Courier job metadata missing');
        final job = _HostJob.parse(text);
        if (job.key != id) {
          throw const FormatException('Courier job key mismatch');
        }
        _jobs[id] = job;
      }
      final receipts = Map<String, Map<String, Object?>>.from(
        (meta['receipts'] as Map).map(
          (k, v) => MapEntry(k, Map<String, Object?>.from(v as Map)),
        ),
      );
      if (receipts.length > 512 ||
          receipts.entries.any(
            (e) =>
                !courierHex(e.key, 64) ||
                e.value['expiresAt'] is! int ||
                e.value['sender'] is! String ||
                e.value['mailbox'] is! String ||
                !courierHex(e.value['mailbox'] as String, 64),
          )) {
        throw const FormatException('Invalid receipt registry');
      }
      _receipts.addAll(receipts);
      // RAM fragments are never acknowledged as stored. A restart retries at most 256 KiB.
      if (leases.isNotEmpty || (meta['held'] as int) != 0) {
        await journal.commit(
          {'registry': jsonEncode(_meta(leases: [], held: 0))},
          {for (final id in leases) 'lease_$id'},
        );
      }
    }
    for (final job in _jobs.values.toList()) {
      if (job.state != 'active' && job.stored.length > 0) {
        await _cleanupTombstone(job);
      }
    }
    await journal.recover();
    _guard();
    await budget.resizeCourierReservation(
      _budgetKey,
      reservedBytes,
      storedBytes,
      afterCleanup: true,
    );
  }

  String _jobKey(String from, String id) =>
      sha256.convert(utf8.encode('$from\u0000$id')).toString();
  String _randomId() => List.generate(
    16,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  Future<Map<String, Object?>> _verify(
    String from,
    Map<String, Object?> control,
    String challenge,
    String kind,
  ) async {
    final value = await crypto.deliveryCall('verifyControl', {
      'control': control,
      'expectedSigner': from,
      'challenge': challenge,
      'now': _clock(),
    });
    _guard();
    if (value['kind'] != kind) {
      throw const FormatException('Wrong Courier control role');
    }
    return value;
  }

  void _admit(int cost, String sender, {bool newJob = false}) {
    final tenant =
        CourierPolicy.metadataBytes *
            _jobs.values.where((j) => j.sender == sender).length +
        _jobs.values
            .where((j) => j.sender == sender)
            .fold<int>(0, (n, j) => n + j.cost) +
        _assemblies.values
            .where((a) => _jobs[a.jobKey]?.sender == sender)
            .fold<int>(0, (n, a) => n + a.cost) +
        _receipts.values.where((r) => r['sender'] == sender).length *
            CourierPolicy.receiptBytes;
    if (reservedBytes + cost > _policy.capacityBytes ||
        tenant + cost > _policy.perDepositorBytes) {
      throw StateError('Courier capacity reached');
    }
    if (newJob &&
        (_jobs.length >= _policy.maxJobs ||
            _jobs.values.where((j) => j.sender == sender).length >=
                _policy.maxJobsPerDepositor)) {
      throw StateError('Courier job limit reached');
    }
  }

  Future<void> _syncBudget() async {
    await journal.recover();
    _guard();
    if (_held != 0) {
      await journal.commit({'registry': jsonEncode(_meta(held: 0))}, {});
      if (journal.cleanupError != null) return;
      _held = 0;
    }
    await budget.resizeCourierReservation(
      _budgetKey,
      reservedBytes,
      storedBytes,
      afterCleanup: true,
    );
  }

  Future<CourierLease> acceptOffer({
    required String from,
    required Map<String, Object?> control,
    required String challenge,
  }) => _queue(() async {
    final verified = await _verify(from, control, challenge, 'store');
    final b = Map<String, dynamic>.from(verified['body'] as Map);
    final now = _clock(), day = CourierPolicy.retentionMilliseconds;
    if (b.length != 14 ||
        b['nodeId'] != nodeId ||
        b['jobId'] is! String ||
        !courierHex(b['jobId'] as String, 32) ||
        b['mailbox'] is! String ||
        !courierHex(b['mailbox'] as String, 64) ||
        b['bucket'] is! int ||
        b['bucket'] < now ~/ day - 1 ||
        b['bucket'] > now ~/ day ||
        b['count'] is! int ||
        b['count'] < 2 ||
        b['count'] > courierMaxPackages ||
        b['index'] is! int ||
        b['index'] < 0 ||
        b['index'] >= b['count'] ||
        b['cipherBytes'] is! int ||
        b['cipherBytes'] < 40 ||
        b['cipherBytes'] > courierPackageBytes + 40 ||
        b['expiresAt'] is! int ||
        b['expiresAt'] <= now ||
        b['expiresAt'] > now + day ||
        b['allocationRevision'] is! int ||
        b['allocationRevision'] < 1 ||
        b['allocationRevision'] > 9007199254740990 ||
        b['hash'] is! String ||
        !courierHex(b['hash'] as String, 64) ||
        b['root'] is! String ||
        !courierHex(b['root'] as String, 64) ||
        b['manifestHash'] is! String ||
        !courierHex(b['manifestHash'] as String, 64) ||
        b['proof'] is! List ||
        (b['proof'] as List).length > 16 ||
        (b['proof'] as List).any((h) => h is! String || !courierHex(h, 64))) {
      throw const FormatException('Invalid Courier offer');
    }
    final inspected = await crypto.deliveryCall('inspectManifest', {
      'manifest': b['manifest'],
      'now': now,
    });
    _guard();
    if (inspected['jobId'] != b['jobId'] ||
        inspected['mailbox'] != b['mailbox'] ||
        inspected['expiresAt'] != b['expiresAt'] ||
        inspected['manifestHash'] != b['manifestHash']) {
      throw const FormatException('Manifest offer mismatch');
    }
    final key = _jobKey(from, b['jobId'] as String), existing = _jobs[key];
    if (existing != null &&
        (existing.state != 'active' ||
            existing.body['manifestHash'] != b['manifestHash'] ||
            existing.count != b['count'] ||
            existing.expires != b['expiresAt'] ||
            existing.body['root'] != b['root'] ||
            existing.bucket != b['bucket'])) {
      throw StateError('Courier job conflict or tombstone');
    }
    final job =
        existing ??
        _HostJob(
          key,
          from,
          verified['publicKey'] as String,
          Map.unmodifiable(b),
          IndexBitmap(b['count'] as int),
          IndexBitmap(b['count'] as int),
        );
    final index = b['index'] as int;
    if (job.stored.contains(index)) {
      final d = await _descriptor(job, index);
      if (d['hash'] != b['hash'] || d['bytes'] != b['cipherBytes']) {
        throw StateError('Stored package conflict');
      }
      return const CourierLease(alreadyStored: true);
    }
    final active = _assemblies.values
        .where((a) => a.jobKey == key && a.index == index)
        .firstOrNull;
    if (active != null) {
      if (active.offer['hash'] != b['hash']) {
        throw StateError('Assembly conflict');
      }
      return CourierLease(
        id: active.id,
        alreadyStored: false,
        missingParts: [
          for (var i = 0; i < active.count; i++)
            if (!active.parts.containsKey(i)) i,
        ],
      );
    }
    if (_assemblies.length >= _policy.maxAssemblies) {
      throw StateError('Courier assemblies busy');
    }
    if (job.ever.length + (job.ever.contains(index) ? 0 : 1) >= job.count) {
      throw StateError('A Courier cannot hold a complete job');
    }
    final cost =
        CourierPolicy.packageCost(b['cipherBytes'] as int) +
        (existing == null ? CourierPolicy.metadataBytes : 0);
    _admit(cost, from, newJob: existing == null);
    await budget.resizeCourierReservation(
      _budgetKey,
      reservedBytes + cost,
      storedBytes,
    );
    _guard();
    final lease = _Assembly(
      _randomId(),
      key,
      Map.unmodifiable(b),
      min(now + 60000, job.expires),
    );
    final updated = job.changed(ever: job.ever.copy()..mark(index));
    try {
      await journal.commit({
        'registry': jsonEncode(
          _meta(
            jobs: {..._jobs.keys, key},
            leases: [..._assemblies.keys, lease.id],
          ),
        ),
        'job_$key': jsonEncode(updated.toJson()),
        'lease_${lease.id}': jsonEncode(lease.toJson()),
      }, {});
    } catch (_) {
      try {
        await _syncBudget();
      } catch (_) {}
      rethrow;
    }
    _guard();
    _jobs[key] = updated;
    _assemblies[lease.id] = lease;
    return CourierLease(
      id: lease.id,
      alreadyStored: false,
      missingParts: List.generate(lease.count, (i) => i),
    );
  });
  Future<void> writePart(
    String leaseId,
    String from,
    int index,
    Uint8List bytes,
  ) => _queue(() async {
    final a = _assemblies[leaseId];
    if (a == null ||
        a.deadline <= _clock() ||
        _jobs[a.jobKey]?.sender != from ||
        index < 0 ||
        index >= a.count ||
        bytes.length != (index == a.count - 1 ? a.size - index * 8192 : 8192)) {
      throw StateError('Invalid Courier fragment');
    }
    final before = a.parts[index];
    if (before != null) {
      if (base64UrlEncode(before) != base64UrlEncode(bytes)) {
        throw StateError('Conflicting fragment');
      }
      return;
    }
    a.parts[index] = Uint8List.fromList(bytes);
  });
  String _pageKey(String key, int index) => 'parts_${key}_${index ~/ 128}';
  Future<Map<String, dynamic>> _page(String key, int index) async {
    final text = await journal.read(_pageKey(key, index));
    _guard();
    if (text == null) return {};
    final v = Map<String, dynamic>.from(jsonDecode(text) as Map);
    if (v.length > 128) {
      throw const FormatException('Host package page too large');
    }
    return v;
  }

  Future<Map<String, dynamic>> _descriptor(_HostJob job, int index) async {
    final page = await _page(job.key, index), d = page['$index'];
    if (d is! Map ||
        d['hash'] is! String ||
        !courierHex(d['hash'] as String, 64) ||
        d['bytes'] is! int ||
        d['bytes'] < 40 ||
        d['bytes'] > courierPackageBytes + 40 ||
        d['cost'] != CourierPolicy.packageCost(d['bytes'] as int)) {
      throw StateError('Stored package metadata missing');
    }
    return Map<String, dynamic>.from(d);
  }

  Future<Map<String, Object?>> commitPackage(String leaseId) =>
      _queue(() async {
        final a = _assemblies[leaseId];
        if (a == null || a.deadline <= _clock() || a.parts.length != a.count) {
          throw StateError('Courier package incomplete');
        }
        final job = _jobs[a.jobKey]!;
        final bytes = BytesBuilder(copy: false);
        for (var i = 0; i < a.count; i++) {
          final part = a.parts[i];
          if (part == null) throw StateError('Courier fragment missing');
          bytes.add(part);
        }
        final cipher = bytes.takeBytes();
        await crypto.deliveryCall('verifyPackage', {
          'index': a.index,
          'count': job.count,
          'ciphertext': base64UrlEncode(cipher).replaceAll('=', ''),
          'hash': a.offer['hash'],
          'root': job.body['root'],
          'proof': a.offer['proof'],
        });
        _guard();
        final page = await _page(job.key, a.index);
        page['${a.index}'] = {
          'hash': a.offer['hash'],
          'bytes': a.size,
          'cost': a.cost,
          'proof': a.offer['proof'],
        };
        final updated = job.changed(
          stored: job.stored.copy()..mark(a.index),
          cost: job.cost + a.cost,
        );
        await journal.commit(
          {
            'job_${job.key}': jsonEncode(updated.toJson()),
            'cipher_${job.key}_${a.index}': base64UrlEncode(cipher)
                .replaceAll('=', ''),
            _pageKey(job.key, a.index): jsonEncode(page),
            'registry': jsonEncode(
              _meta(leases: _assemblies.keys.where((id) => id != leaseId)),
            ),
          },
          {'lease_$leaseId'},
        );
        _guard();
        _jobs[job.key] = updated;
        _assemblies.remove(leaseId);
        budget.noteWritten(_budgetKey, storedBytes);
        return {
          'jobId': job.id,
          'index': a.index,
          'hash': a.offer['hash'],
          'allocationRevision': a.offer['allocationRevision'],
        };
      });
  String _mailbox(String public, int bucket) => sha256
      .convert(
        utf8.encode(
          'chta courier mailbox v1\u0000${jsonEncode([public, bucket])}',
        ),
      )
      .toString();
  Future<Map<String, Object?>> _pickup(
    String from,
    Map<String, Object?> control,
    String challenge,
    String action,
  ) async {
    final c = await _verify(from, control, challenge, 'pickup');
    final body = Map<String, dynamic>.from(c['body'] as Map);
    if (body['action'] != action ||
        body['bucket'] is! int ||
        body['bucket'] < 0 ||
        body['bucket'] >
            9007199254740991 ~/ CourierPolicy.retentionMilliseconds ||
        body['mailbox'] !=
            _mailbox(c['publicKey'] as String, body['bucket'] as int)) {
      throw StateError('Unauthorized mailbox');
    }
    return body;
  }

  Future<List<Map<String, Object?>>> listMailbox({
    required String from,
    required Map<String, Object?> control,
    required String challenge,
  }) => _queue(() async {
    final b = await _pickup(from, control, challenge, 'list');
    final cursor = b['cursor'] ?? 0;
    if (cursor is! int || cursor < 0 || cursor > 1024) {
      throw const FormatException('Invalid mailbox cursor');
    }
    final jobs =
        _jobs.values
            .where(
              (j) =>
                  j.mailbox == b['mailbox'] &&
                  j.bucket == b['bucket'] &&
                  j.state == 'active' &&
                  j.expires > _clock() &&
                  j.stored.length > 0,
            )
            .toList()
          ..sort((a, b) => a.key.compareTo(b.key));
    return jobs
        .skip(cursor)
        .take(16)
        .map(
          (j) => <String, Object?>{
            'jobKey': j.key,
            'jobId': j.id,
            'mailbox': j.mailbox,
            'count': j.count,
            'expiresAt': j.expires,
            'root': j.body['root'],
            'manifestHash': j.body['manifestHash'],
            'manifest': j.body['manifest'],
            'from': j.sender,
            'available': j.stored.encoded,
          },
        )
        .toList();
  });
  Future<Uint8List> readPackage({
    required String from,
    required Map<String, Object?> control,
    required String challenge,
  }) async => (await readPackageDetails(
    from: from,
    control: control,
    challenge: challenge,
  )).bytes;
  Future<CourierStoredPackage> readPackageDetails({
    required String from,
    required Map<String, Object?> control,
    required String challenge,
  }) => _queue(() async {
    final b = await _pickup(from, control, challenge, 'package');
    final key = b['jobKey'];
    if (key is! String || !courierHex(key, 64)) {
      throw const FormatException('Invalid pickup job');
    }
    final job = _jobs[key];
    if (job == null ||
        job.mailbox != b['mailbox'] ||
        job.bucket != b['bucket'] ||
        job.state != 'active' ||
        job.expires <= _clock() ||
        b['index'] is! int ||
        !job.stored.contains(b['index'] as int)) {
      throw StateError('Package unavailable');
    }
    final index = b['index'] as int,
        d = await _descriptor(job, index),
        text = await journal.read('cipher_${job.key}_$index');
    _guard();
    if (text == null) throw StateError('Ciphertext missing');
    final bytes = base64Url.decode(base64Url.normalize(text));
    await crypto.deliveryCall('verifyPackage', {
      'index': index,
      'count': job.count,
      'ciphertext': text,
      'hash': d['hash'],
      'root': job.body['root'],
      'proof': d['proof'],
    });
    _guard();
    return CourierStoredPackage(bytes, {
      'index': index,
      'count': job.count,
      'hash': d['hash'],
      'root': job.body['root'],
      'proof': d['proof'],
    });
  });
  Future<void> _cleanupTombstone(_HostJob job) async {
    final indices = [
      for (var i = 0; i < job.count; i++)
        if (job.stored.contains(i)) i,
    ];
    for (var start = 0; start < indices.length; start += 64) {
      await journal.commit(
        {},
        indices.skip(start).take(64).map((i) => 'cipher_${job.key}_$i').toSet(),
      );
      _guard();
    }
    final pages = indices.map((i) => i ~/ 128).toSet().toList();
    for (var start = 0; start < pages.length; start += 64) {
      await journal.commit(
        {},
        pages
            .skip(start)
            .take(64)
            .map((page) => _pageKey(job.key, page * 128))
            .toSet(),
      );
      _guard();
    }
    await journal.recover();
    _guard();
    final cleared = job.changed(stored: IndexBitmap(job.count), cost: 0);
    await journal.commit({
      'job_${job.key}': jsonEncode(cleared.toJson()),
      'registry': jsonEncode(_meta(held: _held + job.cost)),
    }, {});
    _guard();
    _jobs[job.key] = cleared;
    _held += job.cost;
    await _syncBudget();
  }

  Future<void> _removePayload(_HostJob job, String state) async {
    final leases = _assemblies.values
        .where((a) => a.jobKey == job.key)
        .toList();
    final updated = job.changed(
      state: state,
      until: _clock() + CourierPolicy.retentionMilliseconds,
    );
    final held = _held + leases.fold<int>(0, (n, a) => n + a.cost);
    await journal.commit(
      {
        'job_${job.key}': jsonEncode(updated.toJson()),
        'registry': jsonEncode(
          _meta(
            held: held,
            leases: _assemblies.keys.where(
              (id) => !leases.any((a) => a.id == id),
            ),
          ),
        ),
      },
      {for (final a in leases) 'lease_${a.id}'},
    );
    _guard();
    _jobs[job.key] = updated;
    _held = held;
    for (final a in leases) {
      _assemblies.remove(a.id);
    }
    await _cleanupTombstone(updated);
  }

  Future<void> cancel({
    required String from,
    required Map<String, Object?> control,
    required String challenge,
  }) => _queue(() async {
    final c = await _verify(from, control, challenge, 'cancel');
    final body = c['body'] as Map;
    final id = body['jobId'];
    if (id is! String || !courierHex(id, 32)) {
      throw const FormatException('Invalid cancellation');
    }
    final job = _jobs[_jobKey(from, id)];
    if (job == null) return;
    if (job.state != 'active') {
      if (job.stored.length > 0) await _cleanupTombstone(job);
      return;
    }
    await _removePayload(job, 'cancelled');
  });
  Future<void> recordReceipt({
    required String from,
    required Map<String, Object?> control,
    required String challenge,
  }) => _queue(() async {
    final c = await _verify(from, control, challenge, 'receipt');
    final b = c['body'] as Map;
    final matching = _jobs.values
        .where(
          (j) =>
              j.id == b['jobId'] &&
              j.body['manifestHash'] == b['manifestHash'] &&
              j.mailbox == _mailbox(c['publicKey'] as String, j.bucket),
        )
        .toList();
    if (matching.length != 1) {
      throw StateError('Unauthorized recipient receipt');
    }
    final job = matching.single;
    if (b['receivedAt'] is! int || b['receivedAt'] > job.expires + 300000) {
      throw StateError('Receipt limit or time mismatch');
    }
    final id = sha256
        .convert(utf8.encode('${job.key}\u0000${b['manifestHash']}\u0000$from'))
        .toString();
    if (_receipts.containsKey(id)) {
      if (job.state == 'active') await _removePayload(job, 'received');
      return;
    }
    if (_receipts.length >= 512) throw StateError('Receipt limit reached');
    final bucket = _clock() ~/ CourierPolicy.retentionMilliseconds;
    final record = <String, Object?>{
      'mailbox': _mailbox(job.publicKey, bucket),
      'bucket': bucket,
      'expiresAt': _clock() + CourierPolicy.retentionMilliseconds,
      'jobKey': job.key,
      'sender': job.sender,
    };
    _admit(CourierPolicy.receiptBytes, job.sender);
    await budget.resizeCourierReservation(
      _budgetKey,
      reservedBytes + CourierPolicy.receiptBytes,
      storedBytes,
    );
    await journal.commit({
      'receipt_$id': jsonEncode(c),
      'registry': jsonEncode(_meta(receipts: {..._receipts, id: record})),
    }, {});
    _guard();
    _receipts[id] = record;
    await _removePayload(job, 'received');
  });
  Future<List<Map<String, Object?>>> listReceipts({
    required String from,
    required Map<String, Object?> control,
    required String challenge,
  }) => _queue(() async {
    final b = await _pickup(from, control, challenge, 'receipts');
    final cursor = b['cursor'] ?? 0;
    if (cursor is! int || cursor < 0 || cursor > 512) {
      throw const FormatException('Invalid receipt cursor');
    }
    final result = <Map<String, Object?>>[];
    final entries =
        _receipts.entries
            .where(
              (entry) =>
                  entry.value['mailbox'] == b['mailbox'] &&
                  entry.value['bucket'] == b['bucket'] &&
                  (entry.value['expiresAt'] as int) > _clock(),
            )
            .toList()
          ..sort((a, b) => a.key.compareTo(b.key));
    for (final entry in entries.skip(cursor).take(16)) {
      final text = await journal.read('receipt_${entry.key}');
      _guard();
      if (text == null) throw StateError('Courier receipt missing');
      result.add(Map<String, Object?>.from(jsonDecode(text) as Map));
      if (result.length == 16) break;
    }
    return result;
  });
  Future<void> acknowledgeReceipt({
    required String from,
    required Map<String, Object?> control,
    required String challenge,
  }) => _queue(() async {
    final b = await _pickup(from, control, challenge, 'receipt-ack');
    if (b['jobId'] is! String ||
        !courierHex(b['jobId'] as String, 32) ||
        b['manifestHash'] is! String ||
        !courierHex(b['manifestHash'] as String, 64) ||
        b['recipientId'] is! String ||
        !RegExp(r'^did:cht:[0-9a-f]{64}$')
            .hasMatch(b['recipientId'] as String)) {
      throw const FormatException('Invalid receipt acknowledgement');
    }
    final key = _jobKey(from, b['jobId'] as String),
        id = sha256
            .convert(
              utf8.encode(
                '$key\u0000${b['manifestHash']}\u0000${b['recipientId']}',
              ),
            )
            .toString(),
        entry = _receipts[id];
    if (entry == null) return;
    if (entry['sender'] != from ||
        entry['mailbox'] != b['mailbox'] ||
        entry['bucket'] != b['bucket']) {
      throw StateError('Unauthorized receipt acknowledgement');
    }
    final next = {..._receipts}..remove(id),
        held = _held + CourierPolicy.receiptBytes;
    await journal.commit(
      {'registry': jsonEncode(_meta(receipts: next, held: held))},
      {'receipt_$id'},
    );
    _guard();
    _receipts.remove(id);
    _held = held;
    await _syncBudget();
  });
  Future<void> expire() => _queue(() async {
    for (final a in _assemblies.values.toList()) {
      if (a.deadline > _clock()) continue;
      await journal.commit(
        {
          'registry': jsonEncode(
            _meta(
              leases: _assemblies.keys.where((id) => id != a.id),
              held: _held + a.cost,
            ),
          ),
        },
        {'lease_${a.id}'},
      );
      _guard();
      _held += a.cost;
      _assemblies.remove(a.id);
    }
    for (final job in _jobs.values.toList()) {
      if (job.state == 'active' &&
          _receipts.values.any((r) => r['jobKey'] == job.key)) {
        await _removePayload(job, 'received');
      } else if (job.state == 'active' && job.expires <= _clock()) {
        await _removePayload(job, 'expired');
      } else if (job.state != 'active' && job.stored.length > 0) {
        await _cleanupTombstone(job);
      }
    }
    final expiredReceipts = _receipts.entries
        .where((e) => (e.value['expiresAt'] as int) <= _clock())
        .map((e) => e.key)
        .toSet();
    for (var offset = 0; offset < expiredReceipts.length; offset += 64) {
      final batch = expiredReceipts.skip(offset).take(64).toSet();
      final next = {..._receipts}..removeWhere((k, _) => batch.contains(k));
      final held = _held + batch.length * CourierPolicy.receiptBytes;
      await journal.commit(
        {'registry': jsonEncode(_meta(receipts: next, held: held))},
        {for (final id in batch) 'receipt_$id'},
      );
      _guard();
      _receipts
        ..clear()
        ..addAll(next);
      _held = held;
    }
    final expiredJobs = _jobs.values
        .where(
          (j) =>
              j.state != 'active' &&
              j.stored.length == 0 &&
              j.until <= _clock(),
        )
        .map((j) => j.key)
        .toSet();
    for (var offset = 0; offset < expiredJobs.length; offset += 64) {
      final batch = expiredJobs.skip(offset).take(64).toSet();
      final held = _held + batch.length * CourierPolicy.metadataBytes;
      await journal.commit(
        {
          'registry': jsonEncode(
            _meta(
              jobs: _jobs.keys.where((k) => !batch.contains(k)),
              held: held,
            ),
          ),
        },
        {for (final id in batch) 'job_$id'},
      );
      _guard();
      _jobs.removeWhere((k, _) => batch.contains(k));
      _held = held;
    }
    await _syncBudget();
  });
  Future<void> setCapacityBytes(int bytes) => _queue(() async {
    final p = CourierPolicy(
      capacityBytes: bytes,
      perDepositorBytes: min(bytes, _policy.perDepositorBytes),
    );
    p.validate();
    await journal.commit({'registry': jsonEncode(_meta(policy: p))}, {});
    _guard();
    _policy = p;
  });
  void close() {
    _closed = true;
    _assemblies.clear();
    journal.close();
  }
}
