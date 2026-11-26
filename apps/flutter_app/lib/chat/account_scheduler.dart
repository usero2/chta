import 'dart:async';

/// One account wake-up source, with immediate coalesced event work.
class AccountScheduler {
  AccountScheduler({required this.hasWork, required this.tick});
  final bool Function() hasWork;
  final Future<void> Function() tick;
  Timer? _timer;
  int _idleSeconds = 5;
  bool _closed = false, _scheduled = false, _running = false, _again = false;
  void request() {
    if (_closed) return;
    _idleSeconds = 5;
    _timer?.cancel();
    _timer = null;
    if (_running) {
      _again = true;
      return;
    }
    if (_scheduled) return;
    _scheduled = true;
    scheduleMicrotask(() {
      _scheduled = false;
      unawaited(_run());
    });
  }

  Future<void> _run() async {
    if (_closed || _running) return;
    _running = true;
    _again = false;
    try {
      await tick();
    } finally {
      _running = false;
      if (!_closed) {
        if (_again) {
          request();
        } else {
          final active = hasWork();
          if (active) _idleSeconds = 5;
          _timer = Timer(Duration(seconds: active ? 1 : _idleSeconds), () {
            _timer = null;
            if (_idleSeconds < 15) _idleSeconds += 5;
            unawaited(_run());
          });
        }
      }
    }
  }

  void close() {
    _closed = true;
    _timer?.cancel();
  }
}
