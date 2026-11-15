import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'incoming_notifications.dart';

NotificationBackend createNotificationBackend() => _NativeNotificationBackend();

class _NativeNotificationBackend implements NotificationBackend {
  final _plugin = FlutterLocalNotificationsPlugin();
  Future<bool>? _initialization;
  bool get _supported => Platform.isAndroid || Platform.isWindows;

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
    if (Platform.isAndroid) {
      return await _plugin
              .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin
              >()
              ?.areNotificationsEnabled() ??
          false;
    }
    return true; // Windows notification settings remain controlled by the OS.
  }

  @override
  Future<bool> requestPermissions() async {
    if (!await _prepare()) return false;
    if (Platform.isAndroid) {
      return await _plugin
              .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin
              >()
              ?.requestNotificationsPermission() ??
          false;
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
