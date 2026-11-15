import 'dart:async';

import 'package:cht/account/account_controller.dart';
import 'package:cht/account/account_models.dart';
import 'package:cht/account/android_session_bridge.dart';
import 'package:cht/account/desktop_identity_bridge.dart';
import 'package:cht/app.dart';
import 'package:cht/chat/chat_controller.dart';
import 'package:cht/chat/chat_models.dart';
import 'package:cht/chat/peer_history.dart';
import 'package:cht/chat/peer_history_store.dart';
import 'package:cht/core/core_bridge.dart';
import 'package:cht/p2p/connection_page.dart';
import 'package:cht/profile/profile_store.dart';
import 'package:cht/routing/app_router.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'resumed identity restores its saved page from the launch route',
    (tester) async {
      final fixture = await _mount(tester, savedRoute: '/profile');
      expect(fixture.router.path, '/profile');
      expect(find.byKey(const Key('profile-name')), findsOneWidget);
      fixture.router.go('/contacts');
      await tester.pumpAndSettle();
      await fixture.controller.flushSessionWrites();
      expect(fixture.bridge.prefs.lastRoute, '/contacts');
    },
  );

  testWidgets('saved page does not replace a valid incoming chat route', (
    tester,
  ) async {
    final fixture = await _mount(
      tester,
      savedRoute: '/profile',
      initialPath: '/chats/general',
    );
    expect(fixture.router.path, '/chats/general');
    await fixture.controller.flushSessionWrites();
    expect(fixture.bridge.prefs.lastRoute, '/chats/general');
  });

  testWidgets('profile disables PIN after saving its current page', (
    tester,
  ) async {
    final fixture = await _mount(
      tester,
      pinRequired: true,
      initialPath: '/profile',
    );
    expect(find.byKey(const Key('profile-pin-lock')), findsOneWidget);
    fixture.bridge.calls.clear();
    await tester.tap(find.byKey(const Key('profile-pin-lock')));
    await tester.pumpAndSettle();
    expect(fixture.controller.pinLockEnabled, isFalse);
    expect(fixture.bridge.calls, ['route:/profile', 'pin:false']);
    expect(fixture.bridge.prefs.lastRoute, '/profile');
  });

  for (final pinRequired in [true, false]) {
    testWidgets('root Back flushes the page and exits with PIN $pinRequired', (
      tester,
    ) async {
      final fixture = await _mount(
        tester,
        pinRequired: pinRequired,
        initialPath: '/profile',
      );
      final exits = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'SystemNavigator.pop') exits.add('exit');
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      fixture.bridge.routeGate = Completer<void>();
      await tester.binding.handlePopRoute();
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(exits, isEmpty);
      expect(fixture.controller.status, AccountStatus.ready);
      fixture.bridge.routeGate!.complete();
      await tester.pumpAndSettle();
      expect(exits, ['exit']);
      expect(
        fixture.controller.status,
        pinRequired ? AccountStatus.chooseIdentity : AccountStatus.ready,
      );
      expect(fixture.bridge.active, !pinRequired);
      if (!pinRequired) expect(fixture.bridge.prefs.lastRoute, '/profile');
    });
  }

  testWidgets('root Back waits for pending peer history before locking', (
    tester,
  ) async {
    final historyStore = _HistoryStore();
    final fixture = await _mount(
      tester,
      pinRequired: true,
      initialPath: '/profile',
      historyStore: historyStore,
    );
    final history = tester
        .widget<ConnectionPage>(
          find.byType(ConnectionPage, skipOffstage: false),
        )
        .peerHistory!;
    historyStore.saveGate = Completer<void>();
    history.add(
      'did:cht:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      PeerMessage(
        id: 'pending',
        text: 'Save before closing',
        incoming: false,
        status: DeliveryStatus.sent,
      ),
    );
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(fixture.controller.status, AccountStatus.ready);
    historyStore.saveGate!.complete();
    await tester.pumpAndSettle();
    expect(historyStore.saved, contains('Save before closing'));
    expect(fixture.controller.status, AccountStatus.chooseIdentity);
  });

  testWidgets(
    'Home and external activity lifecycle transitions keep the session',
    (tester) async {
      final fixture = await _mount(
        tester,
        pinRequired: true,
        initialPath: '/profile',
      );
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
        await tester.pump();
      }
      expect(fixture.controller.status, AccountStatus.ready);
      expect(fixture.router.path, '/profile');
      expect(fixture.bridge.active, isTrue);
    },
  );

  testWidgets('Back closes a pushed page without locking the root session', (
    tester,
  ) async {
    final fixture = await _mount(
      tester,
      pinRequired: true,
      initialPath: '/profile',
    );
    unawaited(
      Navigator.of(tester.element(find.byKey(const Key('profile-name')))).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Temporary page')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Temporary page'), findsNothing);
    expect(fixture.controller.status, AccountStatus.ready);
  });

  testWidgets('explicit Lock app revokes an unlocked remembered session', (
    tester,
  ) async {
    final fixture = await _mount(tester, initialPath: '/profile');
    await tester.ensureVisible(find.byKey(const Key('lock-app')));
    await tester.tap(find.byKey(const Key('lock-app')));
    await tester.pumpAndSettle();
    expect(fixture.controller.status, AccountStatus.chooseIdentity);
    expect(fixture.bridge.active, isFalse);
    expect(fixture.bridge.remembered, isFalse);
  });

  testWidgets('other platforms do not show Android session controls', (
    tester,
  ) async {
    await _mount(tester, initialPath: '/profile', supported: false);
    expect(find.byKey(const Key('profile-pin-lock')), findsNothing);
    expect(find.byKey(const Key('lock-app')), findsNothing);
  });
}

Future<
  ({AccountController controller, AppRouter router, _SessionBridge bridge})
>
_mount(
  WidgetTester tester, {
  bool pinRequired = false,
  String? savedRoute,
  String initialPath = '/identity',
  bool supported = true,
  _HistoryStore? historyStore,
}) async {
  tester.view.physicalSize = const Size(1100, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final bridge = _SessionBridge(
    prefs: SessionPreferences(pinRequired: pinRequired, lastRoute: savedRoute),
    supported: supported,
  );
  final controller = AccountController(bridge);
  final router = AppRouter(initialPath: initialPath);
  await tester.pumpWidget(
    ChtApp(
      controller: ChatController(coreBridge: bridge),
      coreBridge: bridge,
      accountController: controller,
      router: router,
      peerHistoryStore: historyStore ?? _HistoryStore(),
    ),
  );
  await tester.pumpAndSettle();
  return (controller: controller, router: router, bridge: bridge);
}

const _owner =
    'did:cht:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _identity = IdentityView(
  id: _owner,
  rootPublicKey: 'root',
  noiseStaticPublicKey: 'noise',
  derivationVersion: 1,
);

class _SessionBridge
    implements AppBridge, DesktopIdentityBridge, AndroidSessionBridge {
  _SessionBridge({required this.prefs, required this.supported});
  SessionPreferences prefs;
  final bool supported;
  bool active = true;
  bool remembered = true;
  Completer<void>? routeGate;
  final calls = <String>[];
  @override
  bool get supportsRememberedSession => supported;
  @override
  Future<IdentityView?> resumeIdentity() async => _identity;
  @override
  Future<SessionPreferences> sessionPreferences() async => prefs;
  @override
  Future<SessionPreferences> setPinLock(String ownerId, bool required) async {
    calls.add('pin:$required');
    remembered = !required;
    return prefs = SessionPreferences(
      pinRequired: required,
      lastRoute: prefs.lastRoute,
    );
  }

  @override
  Future<void> saveSessionRoute(String ownerId, String path) async {
    await routeGate?.future;
    calls.add('route:$path');
    prefs = SessionPreferences(pinRequired: prefs.pinRequired, lastRoute: path);
  }

  @override
  Future<bool> hasIdentity() async => active;
  @override
  Future<IdentityView> identity() async => _identity;
  @override
  Future<List<SavedIdentityView>> savedIdentities() async => const [
    SavedIdentityView(identityId: _owner, displayName: 'Fixture'),
  ];
  @override
  Future<void> lockIdentity() async {
    calls.add('lock');
    active = false;
    remembered = false;
  }

  @override
  Future<StoredProfile> loadDesktopProfile() async => const StoredProfile();
  @override
  Future<List<ContactView>> contacts() async => [];
  @override
  Future<String> contactCard({
    String displayName = '',
    String avatar = '',
  }) async => '{}';
  @override
  Future<String> version() async => 'test';
  @override
  Future<ChatSnapshot> loadSnapshot() async => ChatSnapshot(
    schemaVersion: 1,
    conversations: [
      ConversationView(
        id: 'general',
        title: 'General',
        preview: '',
        updatedAtMilliseconds: 1,
        messages: [],
      ),
    ],
  );
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _HistoryStore implements PeerHistoryStore {
  Completer<void>? saveGate;
  String? saved;
  @override
  Future<String?> load(String ownerId) async => null;
  @override
  Future<void> save(String ownerId, String source) async {
    await saveGate?.future;
    saved = source;
  }
}
