import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'relay_socket.dart';

Future<RelaySocket> connect(String endpoint) async {
  final socket = _Socket(web.WebSocket(endpoint));
  try {
    await socket.ready.future.timeout(const Duration(seconds: 8));
  } catch (_) {
    await socket.close();
    rethrow;
  }
  return socket;
}

class _Socket implements RelaySocket {
  _Socket(this.socket) {
    socket.onopen = ((web.Event _) {
      if (!ready.isCompleted) ready.complete();
    }).toJS;
    socket.onmessage = ((web.MessageEvent event) {
      if (event.data.isA<JSString>()) {
        controller.add((event.data as JSString).toDart);
      }
    }).toJS;
    socket.onerror = ((web.Event _) {
      if (!ready.isCompleted) {
        ready.completeError(StateError('Relay WebSocket failed'));
      } else {
        controller.addError(StateError('Relay WebSocket failed'));
      }
    }).toJS;
    socket.onclose = ((web.CloseEvent _) {
      if (!ready.isCompleted) {
        ready.completeError(StateError('Relay connection closed'));
      }
      unawaited(controller.close());
    }).toJS;
  }
  final web.WebSocket socket;
  final ready = Completer<void>();
  final controller = StreamController<String>();
  @override
  Stream<String> get frames => controller.stream;
  @override
  void send(String value) {
    if (socket.readyState != web.WebSocket.OPEN) {
      throw StateError('Relay connection closed');
    }
    socket.send(value.toJS);
  }

  @override
  Future<void> close() async {
    socket.close();
  }
}
