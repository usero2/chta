import 'dart:async';
import 'dart:collection';

/// Runs one write at a time. Only waiting file chunks can be overtaken.
class PrioritySendQueue {
  final _interactive = Queue<Future<void> Function()>();
  final _bulk = Queue<Future<void> Function()>();
  bool _running = false;

  Future<void> add(Future<void> Function() send, {bool bulk = false}) {
    final completion = Completer<void>();
    (bulk ? _bulk : _interactive).add(() async {
      try {
        await send();
        completion.complete();
      } catch (error, stack) {
        completion.completeError(error, stack);
      }
    });
    if (!_running) {
      _running = true;
      scheduleMicrotask(() => unawaited(_drain()));
    }
    return completion.future;
  }

  Future<void> _drain() async {
    while (_interactive.isNotEmpty || _bulk.isNotEmpty) {
      final next = (_interactive.isNotEmpty ? _interactive : _bulk)
          .removeFirst();
      await next();
    }
    _running = false;
  }
}
