import 'relay_socket_stub.dart'
    if (dart.library.io) 'relay_socket_native.dart'
    if (dart.library.js_interop) 'relay_socket_web.dart'
    as platform;

abstract interface class RelaySocket {
  Stream<String> get frames;
  void send(String value);
  Future<void> close();
}

Future<RelaySocket> openRelaySocket(String endpoint) =>
    platform.connect(endpoint);
