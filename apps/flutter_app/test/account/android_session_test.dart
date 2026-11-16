import 'dart:async';

import 'package:cht/account/account_bridge.dart';
import 'package:cht/account/account_controller.dart';
import 'package:cht/account/account_models.dart';
import 'package:cht/account/android_session_bridge.dart';
import 'package:cht/account/desktop_identity_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

const owner =
    'did:cht:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const fixtureIdentity = IdentityView(
  id: owner,
  rootPublicKey: '',
  noiseStaticPublicKey: '',
  derivationVersion: 1,
);

void main() {
  test('group room routes remain valid through Android session restore', () {
    final group = 'group:${'a' * 64}';
    for (final path in [
      '/chats/$group',
      '/chats/${Uri.encodeComponent(group)}',
    ]) {
      expect(isSessionRoute(path), isTrue, reason: path);
      expect(
        SessionPreferences.fromJson({'pinRequired': false, 'lastRoute': path})
            .lastRoute,
        path,
      );
    }
    for (final path in [
      '/connect/$group',
      '/chats/group:short',
      '/chats/group:${'A' * 64}',
      '/chats/group:${'a' * 64}/extra',
    ]) {
      expect(isSessionRoute(path), isFalse, reason: path);
    }
  });
  test('saved routes accept app pages and reject malformed external paths', () {
    for (final path in [
      '/chats',
      '/contacts',
      '/profile',
      '/connect',
      '/chats/general',
      '/chats/${Uri.encodeComponent(owner)}',
    ]) {
      expect(isSessionRoute(path), isTrue, reason: path);
    }
    for (final path in [
      'https://example.com',
      '/identity/pin',
      '/chats/../profile',
      '/chats/%ff',
      '/chats/%00',
      '/chats/foo?pin=1',
      '/chats/a/b',
    ]) {
      expect(isSessionRoute(path), isFalse, reason: path);
      expect(
        () => SessionPreferences.fromJson({
          'pinRequired': false,
          'lastRoute': path,
        }),
        throwsFormatException,
      );
    }
    expect(
      () => SessionPreferences.fromJson({'pinRequired': 'false'}),
      throwsFormatException,
    );
  });
  test(
    'Off restores last identity and page, On leaves the PIN picker',
    () async {
      final bridge = _Bridge()
        ..remembered = true
        ..prefs = const SessionPreferences(
          pinRequired: false,
          lastRoute: '/chats/general',
        );
      final controller = AccountController(bridge);
      await controller.initialize();
      expect(controller.status, AccountStatus.ready);
      expect(controller.pinLockEnabled, false);
      expect(controller.rememberedRoute, '/chats/general');
      expect(bridge.resumeCalls, 1);
      bridge.active = false;
      bridge.remembered = false;
      bridge.prefs = const SessionPreferences(pinRequired: true);
      final locked = AccountController(bridge);
      await locked.initialize();
      expect(locked.status, AccountStatus.chooseIdentity);
      expect(locked.pinLockEnabled, true);
    },
  );
  test(
    'corrupt resume state falls back to PIN and a correct PIN recovers',
    () async {
      final bridge = _Bridge()..resumeError = StateError('corrupt');
      final controller = AccountController(bridge);
      await controller.initialize();
      expect(controller.status, AccountStatus.chooseIdentity);
      expect(await controller.unlock(owner, 'fixture-pin'), true);
      expect(controller.status, AccountStatus.ready);
      expect(controller.pinLockEnabled, true);
    },
  );
  test('preference failure does not optimistically disable PIN', () async {
    final bridge = _Bridge()
      ..active = true
      ..saveError = StateError('disk full');
    final controller = AccountController(bridge);
    await controller.initialize();
    await expectLater(controller.setPinLock(false), throwsStateError);
    expect(controller.pinLockEnabled, true);
    expect(bridge.remembered, false);
  });
  test(
    'manual lock waits for pending preference write then revokes resume',
    () async {
      final bridge = _Bridge()
        ..active = true
        ..writeGate = Completer<void>();
      final controller = AccountController(bridge);
      await controller.initialize();
      final setting = controller.setPinLock(false);
      final assertion = expectLater(setting, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      final locking = controller.lock();
      bridge.writeGate!.complete();
      await assertion;
      await locking;
      expect(bridge.remembered, false);
      expect(controller.status, AccountStatus.chooseIdentity);
      expect(controller.pinLockEnabled, true);
    },
  );
  test('delayed route write cannot recreate a revoked resume grant', () async {
    final bridge = _Bridge()
      ..remembered = true
      ..active = true
      ..prefs = const SessionPreferences(pinRequired: false)
      ..routeGate = Completer<void>();
    final controller = AccountController(bridge);
    await controller.initialize();
    final route = controller.rememberRoute('/contacts');
    await Future<void>.delayed(Duration.zero);
    final locking = controller.lock();
    bridge.routeGate!.complete();
    await route;
    await locking;
    expect(bridge.remembered, false);
    expect(controller.rememberedRoute, isNull);
    expect(bridge.calls.last, 'lock');
  });
  test(
    'session preferences are opt-in capability on other platforms',
    () async {
      final bridge = _Bridge()
        ..enabled = false
        ..active = true;
      final controller = AccountController(bridge);
      await controller.initialize();
      expect(controller.supportsPinLockPreference, false);
      expect(bridge.resumeCalls, 0);
    },
  );
  test('reinitialization clears stale identity and Off preference', () async {
    final bridge = _Bridge()
      ..remembered = true
      ..prefs = const SessionPreferences(
        pinRequired: false,
        lastRoute: '/profile',
      );
    final controller = AccountController(bridge);
    await controller.initialize();
    bridge.active = false;
    bridge.remembered = false;
    await controller.initialize();
    expect(controller.status, AccountStatus.chooseIdentity);
    expect(controller.identity, isNull);
    expect(controller.pinLockEnabled, true);
    expect(controller.rememberedRoute, isNull);
  });
}

class _Bridge
    implements AccountBridge, DesktopIdentityBridge, AndroidSessionBridge {
  bool enabled = true, active = false, remembered = false;
  Object? resumeError, saveError;
  Completer<void>? writeGate, routeGate;
  int resumeCalls = 0;
  final calls = <String>[];
  SessionPreferences prefs = const SessionPreferences(pinRequired: true);
  @override
  bool get supportsRememberedSession => enabled;
  @override
  Future<IdentityView?> resumeIdentity() async {
    resumeCalls++;
    if (resumeError != null) throw resumeError!;
    if (remembered) {
      active = true;
      return fixtureIdentity;
    }
    return null;
  }

  @override
  Future<SessionPreferences> sessionPreferences() async => prefs;
  @override
  Future<SessionPreferences> setPinLock(String ownerId, bool required) async {
    await writeGate?.future;
    if (saveError != null) throw saveError!;
    if (!active || ownerId != owner) throw StateError('wrong owner');
    calls.add('preference');
    remembered = !required;
    return prefs = SessionPreferences(
      pinRequired: required,
      lastRoute: prefs.lastRoute,
    );
  }

  @override
  Future<void> saveSessionRoute(String ownerId, String path) async {
    await routeGate?.future;
    if (!active || ownerId != owner) throw StateError('wrong owner');
    calls.add('route');
    prefs = SessionPreferences(pinRequired: prefs.pinRequired, lastRoute: path);
  }

  @override
  Future<bool> hasIdentity() async => active;
  @override
  Future<IdentityView> identity() async => identityFixture;
  IdentityView get identityFixture => fixtureIdentity;
  @override
  Future<List<SavedIdentityView>> savedIdentities() async => [
    const SavedIdentityView(identityId: owner, displayName: 'Fixture'),
  ];
  @override
  Future<IdentityView> unlockIdentity(String id, String pin) async {
    active = true;
    prefs = const SessionPreferences(pinRequired: true);
    return identityFixture;
  }

  @override
  Future<void> lockIdentity() async {
    calls.add('lock');
    active = false;
    remembered = false;
    prefs = const SessionPreferences(pinRequired: true);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
