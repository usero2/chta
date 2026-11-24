import 'dart:async';
import 'dart:convert';

import '../delivery/delivery_crypto_bridge.dart';
import '../relay/relay_network.dart';
import 'courier_models.dart';

/// Untrusted discovery hints become usable only after root + device verification.
class CourierDirectory {
  CourierDirectory({
    required this.crypto,
    int Function()? clock,
    this.allowLoopback = false,
  }) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);
  final DeliveryCryptoBridge crypto;
  final int Function() _clock;
  final bool allowLoopback;
  final _nodes = <String, CourierNode>{},
      _records = <String, Map<String, Object?>>{};
  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;
  bool _closed = false;
  int _queued = 0, _cursor = 0;
  final _withdrawn = <String>{};
  void withdraw(String id) {
    if (_closed) return;
    _withdrawn.add(id);
    _nodes.remove(id);
    _records.remove(id);
    _changes.add(null);
  }

  void allow(String id) => _withdrawn.remove(id);
  Future<void> _tail = Future.value();
  List<CourierNode> get nodes =>
      List.unmodifiable(_nodes.values.where((n) => n.eligible(_clock())));
  List<Map<String, Object?>> batch([int count = 8]) {
    prune();
    final records = _records.values.toList();
    if (records.isEmpty) return [];
    count = count.clamp(0, 8).clamp(0, records.length);
    final result = <Map<String, Object?>>[];
    for (var i = 0; i < count; i++) {
      final r = records[(_cursor + i) % records.length];
      if (utf8.encode(jsonEncode([...result, r])).length > 12000) break;
      result.add(Map<String, Object?>.from(r));
    }
    _cursor = (_cursor + result.length) % records.length;
    return result;
  }

  void prune() {
    if (_closed) return;
    final old = _nodes.length;
    _nodes.removeWhere((_, n) => !n.eligible(_clock()));
    _records.removeWhere((id, _) => !_nodes.containsKey(id));
    if (old != _nodes.length) _changes.add(null);
  }

  Future<void> merge(List<Object?> records) {
    if (_closed) return Future.value();
    if (records.length > 8 || _queued >= 8) {
      return Future.error(StateError('Courier discovery busy'));
    }
    _queued++;
    final work = _tail
        .then((_) async {
          prune();
          for (final value in records) {
            if (_closed) return;
            try {
              if (value is! Map ||
                  utf8.encode(jsonEncode(value)).length > 4096) {
                continue;
              }
              final c = Map<String, Object?>.from(value);
              final id = c['signerId'];
              if (id is! String ||
                  !courierHex(id, 64) ||
                  c['challenge'] != 'A' * 43 ||
                  c['kind'] != 'advertisement') {
                continue;
              }
              final verified = await crypto.deliveryCall('verifyControl', {
                'control': c,
                'expectedSigner': id,
                'challenge': 'A' * 43,
                'now': _clock(),
              });
              if (_closed) return;
              if (_withdrawn.contains(id)) continue;
              final b = verified['body'] as Map,
                  cert = Map<String, Object?>.from(
                    verified['certificate'] as Map,
                  );
              final owner = cert['ownerId'],
                  issued = verified['issuedAt'],
                  expiry = verified['expiresAt'];
              if (b.length != 6 ||
                  b['version'] != 1 ||
                  b['nodeId'] != id ||
                  b['ownerId'] != owner ||
                  cert['nodeId'] != id ||
                  owner is! String ||
                  !RegExp(r'^did:cht:[0-9a-f]{64}$').hasMatch(owner) ||
                  issued is! int ||
                  expiry is! int ||
                  issued > _clock() + 30000 ||
                  expiry <= _clock() ||
                  expiry <= issued ||
                  expiry - issued > 900000 ||
                  b['freeBytes'] is! int ||
                  b['freeBytes'] < 0 ||
                  b['freeBytes'] > 1024 * 1024 * 1024 * 1024 ||
                  b['maxPackageBytes'] != courierPackageBytes ||
                  b['routes'] is! List) {
                continue;
              }
              final routes = List<String>.from(b['routes'] as List);
              if (routes.isEmpty ||
                  routes.length > 8 ||
                  routes.toSet().length != routes.length ||
                  routes.any(
                    (url) =>
                        (allowLoopback
                            ? normalizeRelayUrl(url)
                            : normalizePublicRelayUrl(url)) !=
                        url,
                  )) {
                continue;
              }
              final old = _records[id];
              if (old != null && (old['issuedAt'] as int) >= issued) continue;
              if (old == null &&
                  (_nodes.length >= 256 ||
                      _nodes.values.where((n) => n.ownerId == owner).length >=
                          8)) {
                continue;
              }
              _records[id] = Map.unmodifiable(c);
              _nodes[id] = CourierNode.verified(
                nodeId: id,
                ownerId: owner,
                certificate: cert,
                routes: routes,
                expiresAt: expiry,
                freeBytes: b['freeBytes'] as int,
              );
              _changes.add(null);
            } catch (_) {
              /* One invalid hint cannot disconnect private chat or poison other records. */
            }
          }
        })
        .whenComplete(() => _queued--);
    _tail = work.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return work;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _nodes.clear();
    _records.clear();
    _withdrawn.clear();
    unawaited(_changes.close());
  }
}
