import 'package:cht/account/account_controller.dart';
import 'package:cht/account/account_models.dart';
import 'package:cht/account/desktop_identity_bridge.dart';
import 'package:cht/app.dart';
import 'package:cht/chat/chat_controller.dart';
import 'package:cht/chat/chat_models.dart';
import 'package:cht/chat/peer_history_store.dart';
import 'package:cht/core/core_bridge.dart';
import 'package:cht/profile/profile_store.dart';
import 'package:cht/routing/app_router.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'an active migrated browser identity enters PIN setup on startup',
    (tester) async {
      final bridge = _DesktopFake()
        ..legacy = true
        ..activeId = _alice;
      final controller = AccountController(bridge);
      await tester.pumpWidget(
        ChtApp(
          controller: ChatController(coreBridge: bridge),
          coreBridge: bridge,
          accountController: controller,
          router: AppRouter(initialPath: '/profile'),
          peerHistoryStore: _HistoryStore(),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.status, AccountStatus.pinSetup);
      expect(find.text('Set a PIN'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'legacy browser identity can set a PIN without losing its profile',
    (tester) async {
      final bridge = _DesktopFake()..legacy = true;
      final controller = AccountController(bridge);
      await tester.pumpWidget(
        ChtApp(
          controller: ChatController(coreBridge: bridge),
          coreBridge: bridge,
          accountController: controller,
          router: AppRouter(initialPath: '/identity'),
          peerHistoryStore: _HistoryStore(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('login-pin')), findsNothing);
      await tester.ensureVisible(
        find.byKey(const Key('unlock-saved-identity')),
      );
      await tester.tap(find.byKey(const Key('unlock-saved-identity')));
      await tester.pumpAndSettle();
      expect(controller.status, AccountStatus.pinSetup);
      expect(find.text('Set a PIN'), findsOneWidget);
      expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('identity-name')))
            .controller!
            .text,
        'Alice',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'choose an identity, reject wrong PIN, then unlock and switch accounts',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = _DesktopFake();
      final router = AppRouter(initialPath: '/identity');
      await tester.pumpWidget(
        ChtApp(
          controller: ChatController(coreBridge: bridge),
          coreBridge: bridge,
          accountController: AccountController(bridge),
          router: router,
          peerHistoryStore: _HistoryStore(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Choose an identity'), findsOneWidget);
      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('Bob'), findsOneWidget);
      expect(find.byKey(const Key('restore-recovery-1')), findsNothing);
      await tester.tap(find.byKey(Key('saved-identity-$_bob')));
      await tester.enterText(find.byKey(const Key('login-pin')), '000000');
      await tester.tap(find.byKey(const Key('unlock-saved-identity')));
      await tester.pumpAndSettle();
      expect(find.text('Incorrect PIN'), findsOneWidget);
      expect(bridge.activeId, isNull);
      await tester.enterText(find.byKey(const Key('login-pin')), '222222');
      await tester.tap(find.byKey(const Key('unlock-saved-identity')));
      await tester.pumpAndSettle();
      expect(bridge.activeId, _bob);
      router.go('/profile');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('profile-name')))
            .controller!
            .text,
        'Bob',
      );
      await tester.tap(find.byKey(const Key('switch-identity')));
      await tester.pumpAndSettle();
      expect(bridge.activeId, isNull);
      expect(find.text('Choose an identity'), findsOneWidget);
      await tester.tap(find.byKey(Key('saved-identity-$_alice')));
      await tester.enterText(find.byKey(const Key('login-pin')), '111111');
      await tester.tap(find.byKey(const Key('unlock-saved-identity')));
      await tester.pumpAndSettle();
      router.go('/profile');
      await tester.pumpAndSettle();
      expect(bridge.activeId, _alice);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('profile-name')))
            .controller!
            .text,
        'Alice',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'restoring another identity requires matching PINs before saving it',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = _DesktopFake();
      final controller = AccountController(bridge);
      await tester.pumpWidget(
        ChtApp(
          controller: ChatController(coreBridge: bridge),
          coreBridge: bridge,
          accountController: controller,
          router: AppRouter(initialPath: '/identity'),
          peerHistoryStore: _HistoryStore(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('restore-another-identity')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('restore-recovery-24')), findsOneWidget);
      await controller.restoreIdentity('test recovery fixture');
      await tester.pumpAndSettle();
      expect(find.text('Set a PIN'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('identity-name')), 'Charlie');
      await tester.enterText(find.byKey(const Key('setup-pin')), '123456');
      await tester.enterText(find.byKey(const Key('confirm-pin')), '654321');
      await tester.tap(find.byKey(const Key('save-identity-pin')));
      await tester.pumpAndSettle();
      expect(find.text('PINs do not match.'), findsOneWidget);
      expect(bridge.pins.containsKey(_charlie), isFalse);
      await tester.enterText(find.byKey(const Key('confirm-pin')), '123456');
      await tester.tap(find.byKey(const Key('save-identity-pin')));
      await tester.pumpAndSettle();
      expect(controller.status, AccountStatus.ready);
      expect(bridge.pins[_charlie], '123456');
      expect((await bridge.savedIdentities()).last.displayName, 'Charlie');
      await tester.pumpWidget(const SizedBox());
    },
  );
}

final _alice = 'did:cht:${'a' * 64}';
final _bob = 'did:cht:${'b' * 64}';
final _charlie = 'did:cht:${'c' * 64}';

class _DesktopFake implements AppBridge, DesktopIdentityBridge {
  bool legacy = false;
  String? activeId;
  final pins = {_alice: '111111', _bob: '222222'};
  final profiles = {
    _alice: const StoredProfile(name: 'Alice'),
    _bob: const StoredProfile(name: 'Bob'),
  };
  IdentityView _identity(String id) => IdentityView(
    id: id,
    rootPublicKey: 'root',
    noiseStaticPublicKey: 'noise',
    derivationVersion: 1,
  );
  @override
  Future<List<SavedIdentityView>> savedIdentities() async => [
    for (final id in pins.keys)
      SavedIdentityView(
        identityId: id,
        displayName: profiles[id]!.name,
        requiresPin: !legacy,
      ),
  ];
  @override
  Future<bool> hasIdentity() async => activeId != null;
  @override
  Future<IdentityView> identity() async => _identity(activeId!);
  @override
  Future<IdentityView> unlockIdentity(String identityId, String pin) async {
    if (!legacy && pins[identityId] != pin) throw StateError('Incorrect PIN');
    activeId = identityId;
    return _identity(identityId);
  }

  @override
  Future<IdentityView> rememberIdentity(
    String pin,
    String displayName,
    String avatar,
  ) async {
    pins[activeId!] = pin;
    profiles[activeId!] = StoredProfile(name: displayName);
    return _identity(activeId!);
  }

  @override
  Future<void> lockIdentity() async {
    activeId = null;
  }

  @override
  Future<StoredProfile> loadDesktopProfile() async =>
      profiles[activeId] ?? const StoredProfile();
  @override
  Future<void> saveDesktopProfile(StoredProfile profile) async {
    profiles[activeId!] = profile;
  }

  @override
  Future<IdentityView> restoreIdentity(String phrase) async {
    activeId = _charlie;
    return _identity(_charlie);
  }

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
        preview: 'Room for $activeId',
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
  final values = <String, String>{};
  @override
  Future<String?> load(String ownerId) async => values[ownerId];
  @override
  Future<void> save(String ownerId, String source) async {
    values[ownerId] = source;
  }
}
