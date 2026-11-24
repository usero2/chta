import 'dart:async';

/// One account wake-up source, with immediate coalesced event work.
class AccountScheduler {
  AccountScheduler({required this.hasWork, required this.tick});
  final bool Function() hasWork;
  final Future<void> Function() tick;
  Timer? _timer;
  bool _closed = false, _scheduled = false, _running = false, _again = false;
  void request() {
    if (_closed) return;
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
          _timer = Timer(Duration(seconds: hasWork() ? 1 : 5), request);
        }
      }
    }
  }

  void close() {
    _closed = true;
    _timer?.cancel();
  }
}
