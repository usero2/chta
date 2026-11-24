import 'dart:async';

import 'package:cht/notifications/incoming_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:cht/notifications/notification_settings_tile.dart';
import 'package:cht/groups/group_blob_bridge.dart';

class RecordingBackend implements NotificationBackend {
  bool granted = true;
  int requests = 0;
  bool fail = false;
  bool requestFails = false;
  Completer<bool>? initialization;
  Completer<bool>? permission;
  final shown = <IncomingNotification>[];

  @override
  Future<bool> initialize() async =>
      initialization == null ? granted : await initialization!.future;
  @override
  Future<bool> requestPermissions() async {
    requests++;
    if (requestFails) throw StateError('Synthetic permission API failure');
    return permission == null ? granted : await permission!.future;
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
    'Off suppresses alerts, survives restart and is isolated per identity',
    () async {
      final settings = NotificationBlobs();
      final first = IncomingNotifications(
        identityId: 'owner',
        backend: backend,
        settings: settings,
      );
      await first.initialize();
      expect(first.enabled, isTrue);
      await first.setEnabled(false);
      await first.notifyIncoming(
        peerId: 'friend',
        displayName: 'Fixture',
        messageId: 'muted',
      );
      expect(backend.shown, isEmpty);
      expect(backend.requests, 0);
      first.dispose();
      final resumed = IncomingNotifications(
        identityId: 'owner',
        backend: backend,
        settings: settings,
      );
      final other = IncomingNotifications(
        identityId: 'other',
        backend: backend,
        settings: settings,
      );
      await resumed.initialize();
      await other.initialize();
      expect(resumed.enabled, isFalse);
      expect(other.enabled, isTrue);
      await resumed.setEnabled(true);
      expect(resumed.enabled, isTrue);
      resumed.dispose();
      other.dispose();
    },
  );
  test('Off wins over delayed startup and delayed permission result', () async {
    backend.initialization = Completer<bool>();
    final startup = notifications.initialize();
    final off = notifications.setEnabled(false);
    backend.initialization!.complete(true);
    await Future.wait([startup, off]);
    expect(notifications.enabled, isFalse);
    backend.permission = Completer<bool>();
    final on = notifications.setEnabled(true);
    await notifications.setEnabled(false);
    backend.permission!.complete(true);
    await on;
    expect(notifications.enabled, isFalse);
  });
  test(
    'background permission request does not override an explicit Off choice',
    () async {
      await notifications.initialize();
      await notifications.setEnabled(false);
      expect(await notifications.requestPermissions(), isTrue);
      expect(notifications.enabled, isFalse);
    },
  );
  test('save failure fails closed and can be retried', () async {
    final settings = NotificationBlobs()..fail = true;
    final n = IncomingNotifications(
      identityId: 'owner',
      backend: backend,
      settings: settings,
    );
    await n.initialize();
    await expectLater(n.setEnabled(false), throwsStateError);
    expect(n.enabled, isFalse);
    settings.fail = false;
    await n.setEnabled(true);
    expect(n.enabled, isTrue);
    n.dispose();
  });
  test(
    'permission API error does not reuse an old grant after opting out',
    () async {
      await notifications.initialize();
      await notifications.setEnabled(false);
      backend.requestFails = true;
      await notifications.setEnabled(true);
      expect(notifications.enabled, isFalse);
    },
  );

  test(
    'new permission grant beats an older startup permission snapshot',
    () async {
      backend.initialization = Completer<bool>();
      final startup = notifications.initialize();
      final on = notifications.setEnabled(true);
      await Future<void>.delayed(Duration.zero);
      backend.initialization!.complete(false);
      await Future.wait([startup, on]);
      expect(notifications.enabled, isTrue);
    },
  );

  test(
    'flush includes choices still waiting for startup and storage',
    () async {
      final settings = NotificationBlobs()..saving = Completer<void>();
      backend.initialization = Completer<bool>();
      final n = IncomingNotifications(
        identityId: 'owner',
        backend: backend,
        settings: settings,
      );
      final off = n.setEnabled(false);
      var flushed = false;
      final flushing = n.flush().then((_) => flushed = true);
      await Future<void>.delayed(Duration.zero);
      expect(flushed, isFalse);
      backend.initialization!.complete(true);
      await Future<void>.delayed(Duration.zero);
      expect(flushed, isFalse);
      settings.saving!.complete();
      await Future.wait([off, flushing]);
      n.dispose();
      final resumed = IncomingNotifications(
        identityId: 'owner',
        backend: RecordingBackend(),
        settings: settings,
      );
      await resumed.initialize();
      expect(resumed.enabled, isFalse);
      resumed.dispose();
    },
  );

  test(
    'disposing an owner prevents delayed choices from being saved',
    () async {
      final settings = NotificationBlobs();
      backend.permission = Completer<bool>();
      final n = IncomingNotifications(
        identityId: 'owner',
        backend: backend,
        settings: settings,
      );
      await n.initialize();
      final on = n.setEnabled(true);
      n.dispose();
      backend.permission!.complete(true);
      await on;
      expect(settings.values, isEmpty);
    },
  );

  test('lock pauses new choices across the entire delayed flush', () async {
    await notifications.initialize();
    await notifications.setEnabled(false);
    final delayedHistory = Completer<void>();
    final locking = notifications.withChangesPaused(() async {
      await notifications.flush();
      await delayedHistory.future;
    });
    await Future<void>.delayed(Duration.zero);
    expect(notifications.canChange, isFalse);
    await notifications.setEnabled(true);
    expect(notifications.enabled, isFalse);
    expect(backend.requests, 0);
    delayedHistory.complete();
    await locking;
    expect(notifications.canChange, isTrue);
    await notifications.setEnabled(true);
    expect(notifications.enabled, isTrue);
  });

  test(
    'an event received while Off stays suppressed across delayed startup',
    () async {
      backend.initialization = Completer<bool>();
      final off = notifications.setEnabled(false);
      final muted = receive('muted-before-on');
      final on = notifications.setEnabled(true);
      backend.initialization!.complete(true);
      await Future.wait([off, muted, on]);
      expect(notifications.enabled, isTrue);
      expect(backend.shown, isEmpty);
      await receive('muted-before-on');
      await receive('new-after-on');
      expect(backend.shown.map((n) => n.messageId), ['new-after-on']);
    },
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

  test('large Markdown notifications never read the attachment', () async {
    await notifications.setShowMessagePreview(true);
    var reads = 0;
    await notifications.notifyIncoming(
      peerId: 'friend',
      displayName: 'Alice',
      messageId: 'large-markdown',
      kind: IncomingNotificationKind.file,
      fileName: 'message content.md',
      markdownSize: 2 * 1024 * 1024,
      loadMarkdown: () async {
        reads++;
        throw StateError('Must not open a large file for a notification');
      },
    );
    expect(reads, 0);
    expect(backend.shown.single.body, 'New message');
  });

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

  testWidgets('settings toggle requests permission only when switched On', (
    tester,
  ) async {
    notifications.dispose();
    notifications = IncomingNotifications(identityId: 'me', backend: backend);
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
    expect(find.byKey(const Key('notifications-toggle')), findsOneWidget);
    await tester.tap(find.byKey(const Key('notifications-toggle')));
    await tester.pumpAndSettle();
    expect(backend.requests, 1);
    expect(find.text('On'), findsOneWidget);
    await tester.tap(find.byKey(const Key('notifications-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('Off'), findsOneWidget);
    expect(notifications.enabled, isFalse);
    expect(backend.requests, 1);
  });
  testWidgets('denied permission leaves the toggle off', (tester) async {
    notifications.dispose();
    notifications = IncomingNotifications(identityId: 'me', backend: backend);
    backend.granted = false;
    await notifications.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NotificationSettingsTile(notifications: notifications),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('notifications-toggle')));
    await tester.pumpAndSettle();
    expect(notifications.enabled, isFalse);
    expect(find.text('Off'), findsOneWidget);
    expect(
      find.text('Allow notifications in system settings.'),
      findsOneWidget,
    );
  });
  for (final malformed in [false, true]) {
    testWidgets(
      'preference load error is visible and recoverable (malformed=$malformed)',
      (tester) async {
        final settings = NotificationBlobs()..loadFails = !malformed;
        if (malformed) {
          settings.values['me/notification-settings-v1'] = '{broken';
        }
        notifications.dispose();
        notifications = IncomingNotifications(
          identityId: 'me',
          backend: backend,
          settings: settings,
        );
        await notifications.initialize();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: NotificationSettingsTile(notifications: notifications),
            ),
          ),
        );
        expect(find.text('Off'), findsOneWidget);
        expect(
          find.text('Notifications are unavailable. Try again.'),
          findsOneWidget,
        );
        settings.loadFails = false;
        await tester.tap(find.byKey(const Key('notifications-toggle')));
        await tester.pumpAndSettle();
        expect(find.text('On'), findsOneWidget);
        expect(
          find.text('Notifications are unavailable. Try again.'),
          findsNothing,
        );
      },
    );
  }
}

class NotificationBlobs implements GroupBlobBridge {
  final values = <String, String>{};
  bool fail = false;
  bool loadFails = false;
  Completer<void>? saving;
  @override
  Future<String?> loadGroupBlob(String owner, String key) async {
    if (loadFails) throw StateError('Synthetic load failure');
    return values['$owner/$key'];
  }

  @override
  Future<void> saveGroupBlob(String owner, String key, String value) async {
    await saving?.future;
    if (fail) throw StateError('Synthetic storage failure');
    values['$owner/$key'] = value;
  }

  @override
  Future<void> deleteGroupBlob(String owner, String key) async {
    values.remove('$owner/$key');
  }
}
