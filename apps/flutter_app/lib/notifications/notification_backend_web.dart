import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'incoming_notifications.dart';

NotificationBackend createNotificationBackend() => _WebNotificationBackend();

class _WebNotificationBackend implements NotificationBackend {
  @override
  Future<bool> initialize() async => web.Notification.permission == 'granted';

  @override
  Future<bool> requestPermissions() async =>
      (await web.Notification.requestPermission().toDart).toDart == 'granted';

  @override
  Future<void> show(IncomingNotification notification) async {
    if (web.Notification.permission != 'granted') return;
    // Browser/OS support varies (notably mobile browsers). The service treats
    // unsupported Notification constructors as an optional delivery failure.
    web.Notification(
      notification.title,
      web.NotificationOptions(body: notification.body, tag: notification.tag),
    );
  }
}
