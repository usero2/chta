import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'incoming_notifications.dart';

NotificationBackend createNotificationBackend() => _NativeNotificationBackend();

class _NativeNotificationBackend implements NotificationBackend {
  final _plugin = FlutterLocalNotificationsPlugin();
  Future<bool>? _initialization;
  bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;
  bool get _supported =>
      _isAndroid || defaultTargetPlatform == TargetPlatform.windows;
  AndroidFlutterLocalNotificationsPlugin? get _android => _plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  Future<bool> _prepare() => _initialization ??= _initializePlugin();

  Future<bool> _initializePlugin() async {
    if (!_supported) return false;
    return await _plugin.initialize(
          settings: const InitializationSettings(
            android: AndroidInitializationSettings('ic_notification'),
            windows: WindowsInitializationSettings(
              appName: 'chta',
              appUserModelId: 'app.cht.cht',
              guid: 'c89fd860-5637-47cf-aab2-856a6ce02591',
            ),
          ),
        ) ??
        false;
  }

  @override
  Future<bool> initialize() async {
    if (!await _prepare()) return false;
    if (_isAndroid) {
      return await _android?.areNotificationsEnabled() ?? false;
    }
    return true; // Windows notification settings remain controlled by the OS.
  }

  @override
  Future<bool> requestPermissions() async {
    if (!await _prepare()) return false;
    if (_isAndroid) {
      final android = _android;
      if (android == null) return false;
      // Turning alerts back on can reuse the current OS grant without an
      // Activity-bound permission request.
      if (await android.areNotificationsEnabled() == true) return true;
      return await android.requestNotificationsPermission() ?? false;
    }
    return true;
  }

  @override
  Future<void> show(IncomingNotification notification) => _plugin.show(
    id: int.parse(notification.tag.substring(0, 7), radix: 16),
    title: notification.title,
    body: notification.body,
    notificationDetails: const NotificationDetails(
      android: AndroidNotificationDetails(
        'incoming_chat_v1',
        'Messages and files',
        channelDescription: 'New messages and completed incoming files',
        importance: Importance.high,
        priority: Priority.high,
        visibility: NotificationVisibility.private,
      ),
      windows: WindowsNotificationDetails(),
    ),
  );
}
