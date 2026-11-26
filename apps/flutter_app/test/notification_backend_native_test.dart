import 'package:cht/notifications/incoming_notifications.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const android = TargetPlatformVariant({TargetPlatform.android});
  const channel = MethodChannel('dexterous.com/flutter/local_notifications');

  testWidgets('Android On restores alerts with an existing OS grant', (
    tester,
  ) async {
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    final messenger = tester.binding.defaultBinaryMessenger;
    final shown = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'initialize':
        case 'areNotificationsEnabled':
          return true;
        case 'requestNotificationsPermission':
          throw PlatformException(code: 'permission_request_in_progress');
        case 'show':
          shown.add(call.arguments['title'] as String);
          return null;
        default:
          throw MissingPluginException(call.method);
      }
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final notifications = IncomingNotifications(identityId: 'owner');
    addTearDown(notifications.dispose);

    await notifications.initialize();
    expect(notifications.enabled, isTrue);
    expect(await notifications.setEnabled(false), isFalse);
    await notifications.notifyIncoming(
      peerId: 'peer',
      displayName: 'Muted alert',
      messageId: '1',
    );
    expect(await notifications.setEnabled(true), isTrue);
    await notifications.notifyIncoming(
      peerId: 'peer',
      displayName: 'Restored alert',
      messageId: '2',
    );

    expect(shown, ['Restored alert']);
  }, variant: android);

  testWidgets('Android On requests permission after the OS grant is revoked', (
    tester,
  ) async {
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    final messenger = tester.binding.defaultBinaryMessenger;
    var granted = true;
    var requests = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'initialize':
          return true;
        case 'areNotificationsEnabled':
          return granted;
        case 'requestNotificationsPermission':
          requests++;
          return granted;
        default:
          throw MissingPluginException(call.method);
      }
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final notifications = IncomingNotifications(identityId: 'owner');
    addTearDown(notifications.dispose);

    await notifications.initialize();
    expect(notifications.enabled, isTrue);
    await notifications.setEnabled(false);
    granted = false;

    expect(await notifications.setEnabled(true), isFalse);
    expect(requests, 1);
  }, variant: android);
}
