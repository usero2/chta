import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../relay/relay_network.dart';
import 'contact_request_transport.dart';

/// Routes the same recipient-sealed contact envelope over live discovery and
/// data sockets. Neither route needs the recipient to have saved the sender.
class RelayContactRequestTransport extends ChangeNotifier
    implements ContactRequestTransport {
  RelayContactRequestTransport({
    required this.ownerId,
    required this.network,
    this.seed,
  }) {
    network.addListener(_notify);
    network.addFrameListener(_receive);
    seed?.addListener(_notify);
    _seedSubscription = seed?.contactRequests.listen(_publish);
    _notify();
  }

  static const _kind = 'contact-request';
  static const _maxEnvelopeBytes = 16384;
  static final _did = RegExp(r'^did:cht:[0-9a-f]{64}$');
  static final _nonce = RegExp(r'^[0-9a-f]{32}$');

  final String ownerId;
  final RelayNetwork network;
  final ContactRequestTransport? seed;
  final _incoming = StreamController<Map<String, Object?>>.broadcast();
  StreamSubscription<Map<String, Object?>>? _seedSubscription;
  bool _closed = false, _seedReady = false, _dataReady = false;

  @override
  bool get registered =>
      !_closed && (seed?.registered == true || network.online.isNotEmpty);

  @override
  Stream<Map<String, Object?>> get contactRequests => _incoming.stream;

  void _notify() {
    if (_closed) return;
    final seedReady = seed?.registered == true;
    final dataReady = network.online.isNotEmpty;
    if (_seedReady == seedReady && _dataReady == dataReady) return;
    _seedReady = seedReady;
    _dataReady = dataReady;
    notifyListeners();
  }

  void _publish(Map<String, Object?> envelope) {
    if (!_closed) _incoming.add(envelope);
  }

  static ({String from, String to, String session, String packet})? _fields(
    Map<String, Object?> envelope,
  ) {
    final from = envelope['from'],
        to = envelope['to'],
        session = envelope['session'],
        id = envelope['id'];
    if (envelope['version'] != 2 ||
        envelope['topic'] != 'contacts' ||
        from is! String ||
        to is! String ||
        from == to ||
        !_did.hasMatch(from) ||
        !_did.hasMatch(to) ||
        session is! String ||
        !_nonce.hasMatch(session) ||
        id is! String ||
        id.length <= 32) {
      return null;
    }
    final packet = id.substring(id.length - 32);
    if (!_nonce.hasMatch(packet)) return null;
    return (from: from, to: to, session: session, packet: packet);
  }

  void _receive(String endpoint, Map<String, dynamic> frame) {
    if (_closed || frame['type'] != 'route') return;
    final body = frame['body'];
    if (body is! Map || body['type'] != _kind) return;
    final envelope = body['envelope'];
    if (envelope is! Map<String, dynamic> ||
        utf8.encode(jsonEncode(envelope)).length > _maxEnvelopeBytes) {
      return;
    }
    final fields = _fields(envelope);
    if (fields == null ||
        fields.from != frame['from'] ||
        fields.to != ownerId ||
        fields.session != frame['session'] ||
        fields.packet != frame['packet']) {
      return;
    }
    // Identity signatures and the recipient box are checked by the controller.
    _publish(envelope);
  }

  @override
  Future<void> sendContactRequest(Map<String, Object?> envelope) async {
    final fields = _fields(envelope);
    if (_closed ||
        fields == null ||
        fields.from != ownerId ||
        utf8.encode(jsonEncode(envelope)).length > _maxEnvelopeBytes) {
      throw const FormatException('Invalid contact setup route');
    }
    final frame = <String, dynamic>{
      'type': 'route',
      'to': fields.to,
      'session': fields.session,
      'packet': fields.packet,
      'body': {'type': _kind, 'envelope': envelope},
    };
    var sent = false;
    // Seed registration does not mean this recipient is reachable via Seed.
    for (final endpoint in network.online.take(3)) {
      if (network.send(endpoint, frame)) sent = true;
    }
    final primary = seed;
    if (primary?.registered == true) {
      try {
        await primary!.sendContactRequest(envelope);
        return;
      } catch (_) {
        if (!sent) rethrow;
      }
    }
    if (!sent) throw StateError('Contact setup route unavailable');
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    network.removeListener(_notify);
    network.removeFrameListener(_receive);
    seed?.removeListener(_notify);
    await _seedSubscription?.cancel();
    await _incoming.close();
    dispose();
  }
}
