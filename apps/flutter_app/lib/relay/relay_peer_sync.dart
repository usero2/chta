import 'dart:async';
import 'dart:convert';

import 'relay_network.dart';

/// A versioned control envelope carried by the existing encrypted peer channel.
/// Reserved IDs keep catalogs out of chat history, attachments and receipts.
class RelayPeerSync {
  RelayPeerSync(this.network, {required this.send}) {
    network.addListener(_changed);
  }
  final RelayNetwork network;
  final Future<void> Function(String id, String text) send;
  static const _prefix = 'cht-control-relays-';
  static bool isControlId(String? id) => id?.startsWith(_prefix) == true;
  Timer? _timer;
  String? _peer;
  String? _sent;
  int _generation = 0;
  int _counter = 0;
  int _failures = 0;
  bool _closed = false;
  bool _sending = false;

  void updateSession(String? peer, {required bool authenticated}) {
    final selected = authenticated ? peer : null;
    if (_peer == selected) return;
    _peer = selected;
    _generation++;
    _sent = null;
    _failures = 0;
    _timer?.cancel();
    _changed();
  }

  void _changed() {
    if (_closed || _peer == null || _timer?.isActive == true) return;
    _timer = Timer(
      const Duration(milliseconds: 500),
      () => unawaited(_flush()),
    );
  }

  Future<void> _flush() async {
    if (_closed || _peer == null || _sending) return;
    final generation = _generation;
    final catalog = network.peerCatalog();
    final fingerprint = jsonEncode(catalog);
    if (fingerprint == _sent) return;
    _sending = true;
    try {
      var batch = <dynamic>[];
      var urls = catalog['urls'];
      Future<void> transmit() async {
        if (_closed || generation != _generation || _peer == null) return;
        await send(
          '$_prefix'
          'v1-${DateTime.now().microsecondsSinceEpoch}-${_counter++}',
          jsonEncode({...catalog, 'urls': urls, 'relays': batch}),
        );
        urls = <String>[];
        batch = [];
      }

      for (final record in catalog['relays'] as List) {
        if (utf8.encode(jsonEncode(record)).length > 4096) continue;
        if (batch.length == 64 ||
            utf8
                    .encode(
                      jsonEncode({
                        ...catalog,
                        'urls': urls,
                        'relays': [...batch, record],
                      }),
                    )
                    .length >
                10000) {
          await transmit();
        }
        batch.add(record);
      }
      if (batch.isNotEmpty || (catalog['relays'] as List).isEmpty) {
        await transmit();
      }
      if (generation == _generation) {
        _sent = fingerprint;
        _failures = 0;
      }
    } catch (_) {
      if (generation == _generation) _failures++;
    } finally {
      _sending = false;
      if (!_closed &&
          _peer != null &&
          (_sent != jsonEncode(network.peerCatalog()))) {
        if (_failures > 0) {
          _timer?.cancel();
          _timer = Timer(
            Duration(seconds: _failures < 4 ? 5 * (1 << (_failures - 1)) : 60),
            () => unawaited(_flush()),
          );
        } else {
          _changed();
        }
      }
    }
  }

  Future<void> receive(String id, String text) async {
    if (_closed ||
        _peer == null ||
        !id.startsWith('${_prefix}v1-') ||
        text.length > 12000 ||
        utf8.encode(text).length > 12000) {
      return;
    }
    try {
      final value = jsonDecode(text);
      if (value is Map<String, dynamic>) await network.mergePeerCatalog(value);
    } catch (_) {
      /* Malformed discovery metadata cannot affect the chat. */
    }
  }

  void dispose() {
    _closed = true;
    _generation++;
    _timer?.cancel();
    network.removeListener(_changed);
  }
}
