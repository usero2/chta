import 'dart:async';

import 'package:cht/notifications/incoming_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:cht/notifications/notification_settings_tile.dart';

class RecordingBackend implements NotificationBackend {
  bool granted = true;
  int requests = 0;
  bool fail = false;
  Completer<bool>? initialization;
  final shown = <IncomingNotification>[];

  @override
  Future<bool> initialize() async =>
      initialization == null ? granted : await initialization!.future;
  @override
  Future<bool> requestPermissions() async {
    requests++;
    return granted;
  }

  @override
  Future<void> show(IncomingNotification notification) async {
    if (fail) throw StateError('OS unavailable');
    shown.add(notification);
  }
}

void main() {
  late RecordingBackend backend;
  late IncomingNotifications notifications;
  setUp(() {
    backend = RecordingBackend();
    notifications = IncomingNotifications(identityId: 'me', backend: backend);
  });
  tearDown(() => notifications.dispose());

  Future<void> receive(
    String id, {
    String peer = 'friend',
    String? fileName,
    bool incoming = true,
    bool isHistory = false,
    IncomingNotificationKind kind = IncomingNotificationKind.message,
  }) => notifications.notifyIncoming(
    peerId: peer,
    displayName: 'Alice',
    messageId: id,
    fileName: fileName,
    incoming: incoming,
    isHistory: isHistory,
    kind: kind,
  );

  test(
    'initialization never asks permission and disabled events are not replayed',
    () async {
      backend.granted = false;
      await notifications.initialize();
      await receive('1');
      expect(backend.requests, 0);
      expect(backend.shown, isEmpty);
      backend.granted = true;
      expect(await notifications.requestPermissions(), isTrue);
      await receive('1');
      await receive('2');
      expect(backend.shown.map((n) => n.messageId), ['2']);
    },
  );

  test(
    'deduplicates concurrently received IDs within peer and identity',
    () async {
      await Future.wait([
        receive('1'),
        receive('1'),
        receive('1', peer: 'other'),
      ]);
      expect(backend.shown, hasLength(2));
      expect(backend.shown.map((n) => n.identityId), ['me', 'me']);
      expect(backend.shown.map((n) => n.tag).toSet(), hasLength(2));
    },
  );

  test(
    'outgoing, controls and loaded history never produce a notification',
    () async {
      await receive('1', incoming: false);
      await receive('2', isHistory: true);
      await receive('3', kind: IncomingNotificationKind.control);
      await receive('2');
      expect(backend.shown, isEmpty);
      await receive('4');
      expect(backend.shown.single.body, 'New message');
    },
  );

  test(
    'file notification sanitizes file name and uses generic message body',
    () async {
      await receive(
        '1',
        kind: IncomingNotificationKind.file,
        fileName: 'a\nfile.zip',
      );
      expect(backend.shown.single.body, 'Received file: a file.zip');
      expect(backend.shown.single.title, 'Alice');
    },
  );

  test(
    'disposed identity cannot finish pending notification initialization',
    () async {
      backend.initialization = Completer<bool>();
      final pending = receive('1');
      notifications.dispose();
      backend.initialization!.complete(true);
      await pending;
      expect(backend.shown, isEmpty);
    },
  );

  test(
    'OS failure does not break message handling or retry old notifications',
    () async {
      backend.fail = true;
      await receive('1');
      backend.fail = false;
      await receive('1');
      await receive('2');
      expect(backend.shown.map((n) => n.messageId), ['2']);
    },
  );

  testWidgets('settings requests permission only after pressing Enable', (
    tester,
  ) async {
    backend.granted = false;
    await notifications.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NotificationSettingsTile(notifications: notifications),
        ),
      ),
    );
    expect(backend.requests, 0);
    backend.granted = true;
    await tester.tap(find.byKey(const Key('enable-notifications')));
    await tester.pumpAndSettle();
    expect(backend.requests, 1);
    expect(find.byKey(const Key('enable-notifications')), findsNothing);
    expect(find.text('On'), findsOneWidget);
  });
}
