import 'relay_socket.dart';

Future<RelaySocket> connect(String endpoint) =>
    Future.error(UnsupportedError('WebSocket is unavailable'));
