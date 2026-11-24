import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import 'network_monitor.dart';

NetworkMonitor createMonitor() => _Monitor();

class _Monitor implements NetworkMonitor {
  late final _events = StreamController<NetworkObservation>.broadcast(
    onListen: _start,
    onCancel: _stop,
  );
  StreamSubscription<dynamic>? _native;
  Timer? _timer;
  bool _closed = false;
  @override
  Stream<NetworkObservation> get changes => _events.stream;
  void _start() {
    if (_closed) return;
    if (Platform.isAndroid) {
      _native = const EventChannel('app.cht/network')
          .receiveBroadcastStream()
          .listen((value) {
            if (!_closed && value is Map && value['fingerprint'] is String) {
              _events.add(
                NetworkObservation(
                  available: value['available'] == true,
                  fingerprint: value['fingerprint'] as String,
                ),
              );
            }
          }, onError: (Object _) {});
    } else {
      _timer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => unawaited(_sample()),
      );
    }
    unawaited(_sample());
  }

  Future<void> _sample() async {
    final state = await check();
    if (!_closed && _events.hasListener && state != null) _events.add(state);
  }

  @override
  Future<NetworkObservation?> check() async {
    try {
      if (Platform.isAndroid) {
        final state = await const MethodChannel('app.cht/platform')
            .invokeMapMethod<String, dynamic>('networkState');
        if (state?['fingerprint'] is String) {
          return NetworkObservation(
            available: state?['available'] == true,
            fingerprint: state!['fingerprint'] as String,
          );
        }
        return null;
      }
      final interfaces = await NetworkInterface.list();
      final addresses = [
        for (final interface in interfaces)
          for (final address in interface.addresses)
            '${interface.name}:${address.address}',
      ]..sort();
      return NetworkObservation(
        available: addresses.isNotEmpty,
        fingerprint: sha256
            .convert(utf8.encode(addresses.join('|')))
            .toString(),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _stop() async {
    _timer?.cancel();
    _timer = null;
    await _native?.cancel();
    _native = null;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _stop();
    await _events.close();
  }
}
