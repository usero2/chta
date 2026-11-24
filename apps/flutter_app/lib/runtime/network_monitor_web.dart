import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'network_monitor.dart';

@JS('navigator.connection')
external web.EventTarget? get _connection;
@JS('navigator.connection.type')
external JSString? get _networkType;

NetworkMonitor createMonitor() => _Monitor();

class _Monitor implements NetworkMonitor {
  late final _events = StreamController<NetworkObservation>.broadcast(
    onListen: _start,
  );
  final _subscriptions = <StreamSubscription<web.Event>>[];
  JSFunction? _change;
  web.EventTarget? _information;
  bool _closed = false;
  @override
  Stream<NetworkObservation> get changes => _events.stream;
  void _start() {
    void emit() {
      if (!_closed) {
        _events.add(_snapshot());
      }
    }

    _subscriptions.add(
      web.EventStreamProviders.onlineEvent
          .forTarget(web.window)
          .listen((_) => emit()),
    );
    _subscriptions.add(
      web.EventStreamProviders.offlineEvent
          .forTarget(web.window)
          .listen((_) => emit()),
    );
    _information = _connection;
    _change = ((web.Event _) => emit()).toJS;
    _information?.addEventListener('change', _change);
    _events.add(_snapshot());
  }

  NetworkObservation _snapshot() {
    var type = 'unknown';
    try {
      if (_information != null) type = _networkType?.toDart ?? 'unknown';
    } catch (_) {
      /* Not every browser exposes its transport type. */
    }
    return NetworkObservation(
      available: web.window.navigator.onLine,
      fingerprint: 'browser-${web.window.navigator.onLine}-$type',
    );
  }

  @override
  Future<NetworkObservation?> check() async => _snapshot();
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _information?.removeEventListener('change', _change);
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    await _events.close();
  }
}
