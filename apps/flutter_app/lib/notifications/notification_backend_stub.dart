import 'incoming_notifications.dart';

NotificationBackend createNotificationBackend() => _UnsupportedBackend();

class _UnsupportedBackend implements NotificationBackend {
  @override
  Future<bool> initialize() async => false;
  @override
  Future<bool> requestPermissions() async => false;
  @override
  Future<void> show(IncomingNotification notification) async {}
}
