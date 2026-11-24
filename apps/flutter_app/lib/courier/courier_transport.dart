import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../delivery/delivery_crypto_bridge.dart';
import '../relay/relay_network.dart';
import 'courier_models.dart';
import 'courier_store.dart';

const courierRoutingSession = '636874612d636f75726965722d763100';
String _random(int bytes) =>
    base64UrlEncode(List.generate(bytes, (_) => Random.secure().nextInt(256)))
        .replaceAll('=', '');
String _id() => List.generate(
  16,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();
bool _did(Object? v) =>
    v is String && RegExp(r'^did:cht:[0-9a-f]{64}$').hasMatch(v);

class CourierWireFrame {
  const CourierWireFrame(this.route, this.from, this.body);
  final String route, from;
  final Map<String, Object?> body;
}

abstract interface class CourierCarrier {
  Stream<CourierWireFrame> get frames;
  List<String> get online;
  bool send(String route, String to, Map<String, Object?> body);
  Future<void> close();
}

abstract interface class CourierSelfCarrier {
  bool supportsSelf(String route);
}

/// Adds one protocol consumer; closing it never tears down private chat sockets.
class RelayCourierCarrier implements CourierCarrier, CourierSelfCarrier {
  RelayCourierCarrier(this.network) {
    network.addFrameListener(_frame);
  }
  final RelayNetwork network;
  final _frames = StreamController<CourierWireFrame>.broadcast();
  bool _closed = false;
  void _frame(String route, Map<String, dynamic> v) {
    if (_closed ||
        v['type'] != 'route' ||
        v['session'] != courierRoutingSession ||
        !_did(v['from']) ||
        v['body'] is! Map) {
      return;
    }
    final body = Map<String, Object?>.from(v['body'] as Map);
    if (body['type'] == 'courier-v1') {
      _frames.add(CourierWireFrame(route, v['from'] as String, body));
    }
  }

  @override
  Stream<CourierWireFrame> get frames => _frames.stream;
  @override
  List<String> get online => network.online;
  @override
  bool supportsSelf(String route) => network.supportsCourierSelf(route);
  @override
  bool send(String route, String to, Map<String, Object?> body) =>
      !_closed &&
      network.send(route, {
        'type': 'route',
        'to': to,
        'session': courierRoutingSession,
        'packet': _id(),
        'body': body,
      });
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    network.removeFrameListener(_frame);
    await _frames.close();
  }
}

class CourierResponse {
  const CourierResponse(this.control, this.challenge, {this.bytes});
  final Map<String, Object?> control;
  final String challenge;
  final Uint8List? bytes;
}

class _Exchange {
  _Exchange(
    this.node,
    this.route,
    this.challenge, {
    this.jobId,
    this.isCurrent,
  });
  final String? jobId;
  final bool Function()? isCurrent;
  final CourierNode node;
  final String route;
  String challenge;
  final buffer = Queue<Map<String, Object?>>();
  Completer<Map<String, Object?>>? waiter;
  bool closed = false;
  void add(Map<String, Object?> frame) {
    if (closed) return;
    final w = waiter;
    if (w != null) {
      waiter = null;
      w.complete(frame);
    } else if (buffer.length < 4) {
      buffer.add(frame);
    } else {
      close();
    }
  }

  Future<Map<String, Object?>> next({Duration? timeout}) {
    if (closed) return Future.error(StateError('Courier request closed'));
    if (buffer.isNotEmpty) return Future.value(buffer.removeFirst());
    if (waiter != null) {
      return Future.error(StateError('Concurrent Courier read'));
    }
    final w = Completer<Map<String, Object?>>();
    waiter = w;
    return timeout == null
        ? w.future
        : w.future.timeout(
            timeout,
            onTimeout: () {
              if (identical(waiter, w)) waiter = null;
              throw TimeoutException('Courier fragment timeout');
            },
          );
  }

  void close() {
    if (closed) return;
    closed = true;
    buffer.clear();
    final w = waiter;
    waiter = null;
    w?.completeError(StateError('Courier request closed'));
  }
}

class _Inbound {
  _Inbound(
    this.id,
    this.from,
    this.route,
    this.clientNonce,
    this.nonce,
    this.until,
  );
  final String id, from, route, clientNonce, nonce;
  final int until;
  bool authorized = false;
  String? lease;
  Map<String, Object?>? offer;
  final acks = <int, Completer<void>>{};
  void close() {
    for (final w in acks.values) {
      if (!w.isCompleted) w.completeError(StateError('Courier host stopped'));
    }
    acks.clear();
  }
}

/// Public authenticated ciphertext transport. Neither side needs a friend entry
/// for a carrier. Content authorization remains in Rust and the receive adapter.
class CourierTransport {
  CourierTransport({
    required this.ownerId,
    required this.crypto,
    required this.carrier,
    int Function()? clock,
    this.timeout = const Duration(seconds: 90),
    this.partTimeout = const Duration(seconds: 3),
    bool Function()? isCurrent,
  }) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
       _isCurrent = isCurrent ?? (() => true) {
    if (!_did(ownerId)) throw const FormatException('Invalid Courier owner');
    _subscription = carrier.frames.listen(_receive);
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _prune());
  }
  final String ownerId;
  final DeliveryCryptoBridge crypto;
  final CourierCarrier carrier;
  final int Function() _clock;
  final bool Function() _isCurrent;
  final Duration timeout;
  final Duration partTimeout;
  late final StreamSubscription<CourierWireFrame> _subscription;
  late final Timer _timer;
  final _outbound = <String, _Exchange>{}, _inbound = <String, _Inbound>{};
  final _control = Queue<CourierWireFrame>(), _bulk = Queue<CourierWireFrame>();
  bool _closed = false, _draining = false;
  int _generation = 0, _routeCursor = 0, _downloads = 0, _uploads = 0;
  String? _nodeState, _nodeId;
  CourierStore? _store;
  bool get hosting => !_closed && _store != null && _isCurrent();
  int get activeRequests => _outbound.length;
  List<String> _routesFor(CourierNode node) =>
      hosting && node.nodeId == _nodeId && node.ownerId == ownerId
      ? ['local-courier']
      : carrier.online
            .where(
              (route) =>
                  node.routes.contains(route) &&
                  (node.ownerId != ownerId ||
                      (carrier is CourierSelfCarrier &&
                          (carrier as CourierSelfCarrier).supportsSelf(route))),
            )
            .toList();
  bool canReach(CourierNode node) =>
      node.eligible(_clock()) && _routesFor(node).isNotEmpty;
  void cancelJob(String id) {
    for (final key in _outbound.keys.toList()) {
      final exchange = _outbound[key]!;
      if (exchange.jobId == id) {
        _outbound.remove(key);
        exchange.close();
      }
    }
  }

  void _guard() {
    if (_closed || !_isCurrent()) throw StateError('Courier identity changed');
  }

  Future<void> startHost({
    required String nodeState,
    required Map<String, Object?> certificate,
    required CourierStore store,
  }) async {
    _guard();
    if (certificate['ownerId'] != ownerId ||
        certificate['nodeId'] != store.nodeId) {
      throw const FormatException('Courier host identity mismatch');
    }
    final generation = _generation;
    await store.initialize();
    _guard();
    if (generation != _generation) return;
    stopHost();
    _nodeState = nodeState;
    _nodeId = store.nodeId;
    _store = store;
  }

  void stopHost() {
    _generation++;
    _store = null;
    _nodeState = null;
    _nodeId = null;
    for (final s in _inbound.values) {
      s.close();
    }
    _inbound.clear();
  }

  void _prune() {
    for (final s in _inbound.values.toList()) {
      if (s.until <= _clock()) {
        _inbound.remove(s.id);
        s.close();
      }
    }
  }

  bool _send(
    String route,
    String to,
    String node,
    String id,
    String op,
    Map<String, Object?> data, {
    required bool toHost,
  }) {
    if (_closed || !_isCurrent()) return false;
    final body = <String, Object?>{
      'type': 'courier-v1',
      'target': toHost ? 'host' : 'client',
      'nodeId': node,
      'requestId': id,
      'op': op,
      ...data,
    };
    if (route == 'local-courier') {
      if (to != ownerId || node != _nodeId || !hosting) return false;
      scheduleMicrotask(() => _receive(CourierWireFrame(route, ownerId, body)));
      return true;
    }
    return carrier.send(route, to, body);
  }

  void _receive(CourierWireFrame frame) {
    if (_closed ||
        !_isCurrent() ||
        !_did(frame.from) ||
        frame.body['type'] != 'courier-v1' ||
        !['host', 'client'].contains(frame.body['target']) ||
        frame.body['requestId'] is! String ||
        !courierHex(frame.body['requestId'] as String, 32) ||
        frame.body['nodeId'] is! String ||
        !courierHex(frame.body['nodeId'] as String, 64) ||
        utf8.encode(jsonEncode(frame.body)).length > 16384) {
      return;
    }
    final bulk = ['uploadPart', 'resultPart'].contains(frame.body['op']);
    final queue = bulk ? _bulk : _control;
    if (queue.length >= (bulk ? 64 : 16)) return;
    queue.add(frame);
    if (!_draining) unawaited(_drain());
  }

  Future<void> _drain() async {
    _draining = true;
    var controls = 0;
    try {
      while (!_closed && (_control.isNotEmpty || _bulk.isNotEmpty)) {
        final queue = _control.isNotEmpty && (controls < 8 || _bulk.isEmpty)
            ? _control
            : _bulk;
        if (identical(queue, _control)) {
          controls++;
        } else {
          controls = 0;
        }
        try {
          await _frame(queue.removeFirst());
        } catch (_) {
          /* Invalid public traffic cannot tear down private sessions. */
        }
      }
    } finally {
      _draining = false;
    }
  }

  Future<void> _frame(CourierWireFrame f) async {
    _guard();
    final b = f.body,
        id = b['requestId'] as String,
        node = b['nodeId'] as String;
    final out = _outbound[id];
    if (b['target'] == 'client' &&
        out != null &&
        out.node.nodeId == node &&
        out.node.ownerId == f.from &&
        out.route == f.route) {
      if (b['op'] == 'control') {
        final c = Map<String, Object?>.from(b['control'] as Map);
        final v = await crypto.deliveryCall('verifyControl', {
          'control': c,
          'expectedSigner': node,
          'challenge': out.challenge,
          'now': _clock(),
        });
        _guard();
        if (_outbound[id] != out ||
            (v['certificate'] as Map)['ownerId'] != out.node.ownerId ||
            !['challenge', 'stored'].contains(v['kind'])) {
          return;
        }
        final body = v['body'] as Map;
        if (body['requestId'] != id) return;
        if (body['phase'] == 'hello') {
          final nonce = body['nonce'];
          if (nonce is! String ||
              !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(nonce)) {
            return;
          }
          out.challenge = nonce;
        }
        out.add({'op': 'control', 'control': c});
      } else if (b['op'] == 'partAck' || b['op'] == 'resultPart') {
        out.add(b);
      }
      return;
    }
    if (b['target'] != 'host' || !hosting || node != _nodeId) return;
    final store = _store!, generation = _generation;
    bool current() =>
        hosting && _generation == generation && identical(store, _store);
    if (b['op'] == 'hello') {
      _prune();
      if (_inbound.containsKey(id) ||
          _inbound.length >= 16 ||
          _inbound.values.where((s) => s.from == f.from).length >= 4) {
        return;
      }
      final nonce = b['nonce'];
      if (nonce is! String || !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(nonce)) {
        return;
      }
      final s = _Inbound(
        id,
        f.from,
        f.route,
        nonce,
        _random(32),
        _clock() + 120000,
      );
      _inbound[id] = s;
      await _reply(s, 'challenge', {
        'phase': 'hello',
        'nonce': s.nonce,
      }, challenge: nonce);
      return;
    }
    final s = _inbound[id];
    if (s == null ||
        s.from != f.from ||
        s.route != f.route ||
        s.until <= _clock()) {
      return;
    }
    if (b['op'] == 'partAck') {
      final w = s.acks[b['index']];
      if (w != null && !w.isCompleted) w.complete();
      return;
    }
    try {
      if (b['op'] == 'request') {
        if (s.authorized) return;
        s.authorized =
            true; // Consume before asynchronous signature/storage work.
        final control = Map<String, Object?>.from(b['control'] as Map);
        final verified = await crypto.deliveryCall('verifyControl', {
          'control': control,
          'expectedSigner': f.from,
          'challenge': s.nonce,
          'now': _clock(),
        });
        if (!current()) return;
        final body = Map<String, Object?>.from(verified['body'] as Map);
        if (verified['kind'] == 'store') {
          final lease = await store.acceptOffer(
            from: f.from,
            control: control,
            challenge: s.nonce,
          );
          if (!current()) return;
          s.offer = body;
          s.lease = lease.id;
          if (lease.alreadyStored) {
            await _reply(s, 'stored', {
              'phase': 'stored',
              'jobId': body['jobId'],
              'index': body['index'],
              'hash': body['hash'],
              'allocationRevision': body['allocationRevision'],
            });
            _finish(s);
          } else {
            await _reply(s, 'challenge', {
              'phase': 'ready',
              'lease': lease.id,
              'missingParts': lease.missingParts,
            });
          }
        } else if (verified['kind'] == 'cancel') {
          await store.cancel(
            from: f.from,
            control: control,
            challenge: s.nonce,
          );
          if (current()) {
            _respond(
              s,
              Uint8List.fromList(utf8.encode('{"ok":true}')),
              generation,
            );
          }
        } else if (verified['kind'] == 'pickup') {
          Uint8List bytes;
          Map<String, Object?>? details;
          switch (body['action']) {
            case 'list':
              bytes = Uint8List.fromList(
                utf8.encode(
                  jsonEncode(
                    await store.listMailbox(
                      from: f.from,
                      control: control,
                      challenge: s.nonce,
                    ),
                  ),
                ),
              );
            case 'package':
              final package = await store.readPackageDetails(
                from: f.from,
                control: control,
                challenge: s.nonce,
              );
              bytes = package.bytes;
              details = package.metadata;
            case 'receipts':
              bytes = Uint8List.fromList(
                utf8.encode(
                  jsonEncode(
                    await store.listReceipts(
                      from: f.from,
                      control: control,
                      challenge: s.nonce,
                    ),
                  ),
                ),
              );
            case 'receipt':
              final receipt = Map<String, Object?>.from(body['receipt'] as Map);
              await store.recordReceipt(
                from: f.from,
                control: receipt,
                challenge: receipt['challenge'] as String,
              );
              bytes = Uint8List.fromList(utf8.encode('{"ok":true}'));
            case 'receipt-ack':
              await store.acknowledgeReceipt(
                from: f.from,
                control: control,
                challenge: s.nonce,
              );
              bytes = Uint8List.fromList(utf8.encode('{"ok":true}'));
            default:
              throw const FormatException('Invalid Courier pickup action');
          }
          if (current()) _respond(s, bytes, generation, details: details);
        } else {
          throw const FormatException('Wrong Courier role');
        }
      } else if (b['op'] == 'uploadPart' && s.authorized && s.lease != null) {
        if (b['lease'] != s.lease) throw StateError('Wrong Courier lease');
        final bytes = _decodePart(b['bytes']);
        await store.writePart(s.lease!, s.from, b['index'] as int, bytes);
        if (current()) {
          _send(s.route, s.from, node, id, 'partAck', {
            'index': b['index'],
          }, toHost: false);
        }
      } else if (b['op'] == 'commit' && s.authorized && s.lease != null) {
        if (b['lease'] != s.lease) throw StateError('Wrong Courier lease');
        final ack = await store.commitPackage(s.lease!);
        if (!current()) return;
        await _reply(s, 'stored', {'phase': 'stored', ...ack});
        _finish(s);
      }
    } catch (_) {
      if (current()) {
        try {
          await _reply(s, 'challenge', {
            'phase': 'error',
            'code': 'unavailable',
          });
        } catch (_) {}
        _finish(s);
      }
    }
  }

  Uint8List _decodePart(Object? value) {
    if (value is! String || value.length > 10923) {
      throw const FormatException('Courier fragment too large');
    }
    final bytes = base64Url.decode(base64Url.normalize(value));
    if (bytes.isEmpty ||
        bytes.length > 8192 ||
        base64UrlEncode(bytes).replaceAll('=', '') != value) {
      throw const FormatException('Invalid Courier fragment');
    }
    return bytes;
  }

  Future<void> _reply(
    _Inbound s,
    String kind,
    Map<String, Object?> body, {
    String? challenge,
  }) async {
    final state = _nodeState, node = _nodeId, generation = _generation;
    if (!hosting || state == null || node == null) return;
    final now = _clock();
    final c = await crypto.deliveryCall('signControl', {
      'nodeState': state,
      'kind': kind,
      'challenge': challenge ?? s.nonce,
      'body': {'requestId': s.id, ...body},
      'now': now,
      'expiresAt': now + 120000,
    });
    if (!hosting || generation != _generation || _inbound[s.id] != s) return;
    if (!_send(s.route, s.from, node, s.id, 'control', {
      'control': c,
    }, toHost: false)) {
      throw StateError('Courier route unavailable');
    }
  }

  void _finish(_Inbound s) {
    if (_inbound[s.id] == s) _inbound.remove(s.id);
    s.close();
  }

  void _respond(
    _Inbound s,
    Uint8List bytes,
    int generation, {
    Map<String, Object?>? details,
  }) {
    if (bytes.length > 1024 * 1024 || _downloads >= 4) {
      unawaited(
        _reply(s, 'challenge', {
          'phase': 'error',
          'code': 'busy',
        }).whenComplete(() => _finish(s)).catchError((Object _) {}),
      );
      return;
    }
    _downloads++;
    unawaited(() async {
      try {
        final count = (bytes.length + 8191) ~/ 8192;
        await _reply(s, 'challenge', {
          'phase': 'result',
          'bytes': bytes.length,
          'hash': sha256.convert(bytes).toString(),
          'parts': count,
          'package': ?details,
        });
        for (var i = 0; i < count; i++) {
          if (!hosting || generation != _generation || _inbound[s.id] != s) {
            throw StateError('Courier host stopped');
          }
          final data = base64UrlEncode(
            Uint8List.sublistView(
              bytes,
              i * 8192,
              min((i + 1) * 8192, bytes.length),
            ),
          ).replaceAll('=', '');
          var acked = false;
          for (var attempt = 0; attempt < 3 && !acked; attempt++) {
            final w = Completer<void>();
            s.acks[i] = w;
            if (!_send(s.route, s.from, _nodeId!, s.id, 'resultPart', {
              'index': i,
              'bytes': data,
            }, toHost: false)) {
              throw StateError('Courier route unavailable');
            }
            try {
              await w.future.timeout(partTimeout);
              acked = true;
            } on TimeoutException {
              /* Retry only this bounded fragment. */
            } finally {
              s.acks.remove(i);
            }
          }
          if (!acked) throw TimeoutException('Courier fragment ACK timeout');
          await Future<void>.delayed(Duration.zero);
        }
      } catch (_) {
        /* A client retry reconstructs from protected packages. */
      } finally {
        _downloads--;
        _finish(s);
      }
    }());
  }

  Future<Map<String, Object?>> _controlResult(_Exchange x) async {
    while (true) {
      final frame = await x.next();
      if (frame['op'] != 'control') continue;
      final c = Map<String, Object?>.from(frame['control'] as Map);
      if ((c['body'] as Map)['phase'] == 'error') {
        throw StateError('Courier unavailable');
      }
      return c;
    }
  }

  Future<CourierResponse> request(
    CourierNode node, {
    required String kind,
    required Map<String, Object?> body,
    Uint8List? upload,
    bool Function()? isCurrent,
  }) async {
    _guard();
    if (_outbound.length >= 16 ||
        (upload != null && _uploads >= 4) ||
        !node.eligible(_clock()) ||
        !['store', 'pickup', 'cancel'].contains(kind)) {
      throw StateError('Courier request unavailable');
    }
    final routes = _routesFor(node);
    if (routes.isEmpty) throw StateError('Courier route unavailable');
    if (upload != null &&
        (upload.length < 40 || upload.length > courierPackageBytes + 40)) {
      throw const FormatException('Invalid Courier package size');
    }
    final id = _id(),
        x = _Exchange(
          node,
          routes[_routeCursor++ % routes.length],
          _random(32),
          jobId: body['jobId'] as String?,
          isCurrent: isCurrent,
        );
    _outbound[id] = x;
    if (upload != null) _uploads++;
    try {
      return await _request(id, x, kind, body, upload).timeout(timeout);
    } finally {
      _outbound.remove(id);
      x.close();
      if (upload != null) _uploads--;
    }
  }

  Future<CourierResponse> _request(
    String id,
    _Exchange x,
    String kind,
    Map<String, Object?> body,
    Uint8List? upload,
  ) async {
    void send(String op, Map<String, Object?> data) {
      _guard();
      if (_outbound[id] != x ||
          x.isCurrent?.call() == false ||
          !_send(
            x.route,
            x.node.ownerId,
            x.node.nodeId,
            id,
            op,
            data,
            toHost: true,
          )) {
        throw StateError('Courier route unavailable');
      }
    }

    send('hello', {'nonce': x.challenge});
    final hello = await _controlResult(x);
    if ((hello['body'] as Map)['phase'] != 'hello') {
      throw const FormatException('Missing Courier challenge');
    }
    final now = _clock();
    final c = await crypto.deliveryCall('signControl', {
      'kind': kind,
      'challenge': x.challenge,
      'body': body,
      'now': now,
      'expiresAt': now + 120000,
    });
    send('request', {'control': c});
    var result = await _controlResult(x);
    if ((result['body'] as Map)['phase'] == 'ready') {
      if (upload == null || kind != 'store') {
        throw const FormatException('Unexpected upload request');
      }
      final b = result['body'] as Map, lease = b['lease'];
      final count = (upload.length + 8191) ~/ 8192;
      final missing = List<int>.from(b['missingParts'] as List);
      if (lease is! String ||
          !courierHex(lease, 32) ||
          missing.length > 33 ||
          missing.toSet().length != missing.length ||
          missing.any((i) => i < 0 || i >= count)) {
        throw const FormatException('Invalid upload plan');
      }
      for (final index in missing) {
        final part = base64UrlEncode(
          Uint8List.sublistView(
            upload,
            index * 8192,
            min((index + 1) * 8192, upload.length),
          ),
        ).replaceAll('=', '');
        var acked = false;
        for (var attempt = 0; attempt < 3 && !acked; attempt++) {
          send('uploadPart', {'lease': lease, 'index': index, 'bytes': part});
          try {
            final ack = await x.next(timeout: partTimeout);
            if (ack['op'] == 'control') {
              throw StateError('Courier upload rejected');
            }
            acked = ack['op'] == 'partAck' && ack['index'] == index;
          } on TimeoutException {
            /* Retry a fragment, not the entire file. */
          }
        }
        if (!acked) throw TimeoutException('Courier upload ACK timeout');
        await Future<void>.delayed(Duration.zero);
      }
      send('commit', {'lease': lease});
      result = await _controlResult(x);
    }
    if (result['kind'] == 'stored') return CourierResponse(result, x.challenge);
    final b = result['body'] as Map;
    if (b['phase'] != 'result' ||
        b['bytes'] is! int ||
        b['bytes'] < 0 ||
        b['bytes'] > 1024 * 1024 ||
        b['parts'] != (b['bytes'] + 8191) ~/ 8192 ||
        b['hash'] is! String ||
        !courierHex(b['hash'] as String, 64)) {
      throw const FormatException('Invalid Courier response size');
    }
    final builder = BytesBuilder(copy: false);
    var index = 0;
    while (index < b['parts']) {
      final frame = await x.next();
      if (frame['op'] != 'resultPart') continue;
      if (frame['index'] is! int ||
          (frame['index'] as int) < 0 ||
          (frame['index'] as int) > index) {
        throw const FormatException('Invalid response fragment order');
      }
      final bytes = _decodePart(frame['bytes']);
      if (frame['index'] == index) {
        if (bytes.length != min(8192, (b['bytes'] as int) - index * 8192)) {
          throw const FormatException('Truncated Courier response');
        }
        builder.add(bytes);
        index++;
      }
      send('partAck', {'index': frame['index']});
    }
    final bytes = builder.takeBytes();
    if (bytes.length != b['bytes'] ||
        sha256.convert(bytes).toString() != b['hash']) {
      throw const FormatException('Courier response hash mismatch');
    }
    return CourierResponse(result, x.challenge, bytes: bytes);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    stopHost();
    _timer.cancel();
    for (final x in _outbound.values) {
      x.close();
    }
    _outbound.clear();
    _control.clear();
    _bulk.clear();
    await _subscription.cancel();
    await carrier.close();
  }
}
