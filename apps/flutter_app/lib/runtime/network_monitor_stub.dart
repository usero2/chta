import 'network_monitor.dart';

NetworkMonitor createMonitor() => _Monitor();

class _Monitor implements NetworkMonitor {
  @override
  Stream<NetworkObservation> get changes => const Stream.empty();
  @override
  Future<NetworkObservation?> check() async => null;
  @override
  Future<void> close() async {}
}
