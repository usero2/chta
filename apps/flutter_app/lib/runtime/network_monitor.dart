import 'network_monitor_stub.dart'
    if (dart.library.io) 'network_monitor_native.dart'
    if (dart.library.js_interop) 'network_monitor_web.dart'
    as platform;

class NetworkObservation {
  const NetworkObservation({
    required this.available,
    required this.fingerprint,
  });
  final bool available;
  final String fingerprint;
}

abstract interface class NetworkMonitor {
  Stream<NetworkObservation> get changes;
  Future<NetworkObservation?> check();
  Future<void> close();
}

NetworkMonitor createNetworkMonitor() => platform.createMonitor();
