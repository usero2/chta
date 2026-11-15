import 'dart:io';

import 'relay_socket.dart';
import 'relay_websocket_native.dart';

Future<RelaySocket> connect(String endpoint) async {
  final socket = await connectRelayWebSocket(endpoint);
  socket.pingInterval = const Duration(seconds: 20);
  return _Socket(socket);
}

class _Socket implements RelaySocket {
  _Socket(this.socket);
  final WebSocket socket;
  @override
  Stream<String> get frames => socket.map((value) => value as String);
  @override
  void send(String value) {
    if (socket.readyState != WebSocket.open) {
      throw StateError('Relay connection closed');
    }
    socket.add(value);
  }

  @override
  Future<void> close() async {
    try {
      await socket.close().timeout(const Duration(seconds: 2));
    } catch (_) {}
  }
}
