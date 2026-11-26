import 'dart:async';

import 'network_monitor.dart';

/// Connectivity only schedules authenticated recovery; it never marks delivery.
class NetworkRecovery {
  NetworkRecovery({
    required this.isCurrent,
    required this.recover,
    this.debounce = const Duration(milliseconds: 800),
  });
  final bool Function() isCurrent;
  final Future<void> Function() recover;
  final Duration debounce;
  NetworkObservation? _last;
  Timer? _timer;
  bool _closed = false, _running = false, _pending = false;
  bool get _active => !_closed && isCurrent();
  void observe(NetworkObservation state) {
    if (!_active) return;
    final before = _last;
    _last = state;
    if (!state.available) {
      _timer?.cancel();
      _timer = null;
      _pending = false;
      return;
    }
    if (before != null &&
        (!before.available || before.fingerprint != state.fingerprint)) {
      _schedule();
    }
  }

  void resume() {
    if (_last?.available != false) _schedule();
  }

  void _schedule() {
    if (!_active) return;
    _pending = true;
    if (_running || _timer != null) return;
    _timer = Timer(debounce, () {
      _timer = null;
      unawaited(_run());
    });
  }

  Future<void> _run() async {
    if (!_active || _last?.available == false || _running) return;
    _running = true;
    _pending = false;
    try {
      await recover();
    } catch (_) {
      /* Transports retain their normal backoff. */
    } finally {
      _running = false;
      if (_pending && _active && _last?.available != false) _schedule();
    }
  }

  void dispose() {
    _closed = true;
    _timer?.cancel();
  }
}
