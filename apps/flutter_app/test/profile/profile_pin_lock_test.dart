import 'dart:async';

import 'package:cht/account/account_models.dart';
import 'package:cht/profile/profile_controller.dart';
import 'package:cht/profile/profile_page.dart';
import 'package:cht/profile/profile_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _identity = IdentityView(
  id: 'test-identity',
  rootPublicKey: 'root-key',
  noiseStaticPublicKey: 'noise-key',
  derivationVersion: 1,
);
const _pinLock = Key('profile-pin-lock');
const _lockApp = Key('lock-app');

void main() {
  late ProfileController controller;

  setUp(() => controller = ProfileController(_MemoryProfileStore()));
  tearDown(() => controller.dispose());

  Future<void> showProfile(
    WidgetTester tester, {
    bool? enabled,
    Future<void> Function(bool)? onChanged,
    Future<void> Function()? onLock,
  }) => tester.pumpWidget(
    MaterialApp(
      home: ProfilePage(
        controller: controller,
        identity: _identity,
        pinLockEnabled: enabled,
        onPinLockChanged: onChanged,
        onLockApp: onLock,
      ),
    ),
  );

  Future<void> tapControl(WidgetTester tester, Key key) async {
    expect(find.byKey(key), findsOneWidget);
    await tester.ensureVisible(find.byKey(key));
    await tester.pump();
    await tester.tap(find.byKey(key));
    await tester.pump();
  }

  testWidgets('PIN controls stay hidden without platform callbacks', (
    tester,
  ) async {
    await showProfile(tester, enabled: true);
    expect(find.byKey(_pinLock), findsNothing);
    expect(find.byKey(_lockApp), findsNothing);

    await showProfile(tester, onChanged: (_) async {});
    expect(find.byKey(_pinLock), findsNothing);
  });

  for (final initiallyEnabled in [true, false]) {
    testWidgets(
      'PIN toggle from $initiallyEnabled waits for saved parent state',
      (tester) async {
        final persistence = Completer<void>();
        final requests = <bool>[];
        var enabled = initiallyEnabled;
        late StateSetter updateParent;
        await tester.pumpWidget(
          MaterialApp(
            home: StatefulBuilder(
              builder: (context, setState) {
                updateParent = setState;
                return ProfilePage(
                  controller: controller,
                  identity: _identity,
                  pinLockEnabled: enabled,
                  onPinLockChanged: (value) async {
                    requests.add(value);
                    await persistence.future;
                  },
                );
              },
            ),
          ),
        );

        await tapControl(tester, _pinLock);
        expect(requests, [!initiallyEnabled]);
        expect(
          tester.widget<SwitchListTile>(find.byKey(_pinLock)).value,
          initiallyEnabled,
        );
        expect(find.text(initiallyEnabled ? 'On' : 'Off'), findsOneWidget);

        persistence.complete();
        await tester.pump();
        expect(
          tester.widget<SwitchListTile>(find.byKey(_pinLock)).value,
          initiallyEnabled,
        );

        updateParent(() => enabled = !initiallyEnabled);
        await tester.pump();
        expect(
          tester.widget<SwitchListTile>(find.byKey(_pinLock)).value,
          !initiallyEnabled,
        );
        expect(find.text(initiallyEnabled ? 'Off' : 'On'), findsOneWidget);
      },
    );
  }

  testWidgets('failed PIN persistence preserves state and permits retry', (
    tester,
  ) async {
    var attempts = 0;
    await showProfile(
      tester,
      enabled: true,
      onChanged: (_) async {
        attempts++;
        throw const FormatException('Could not save PIN lock.');
      },
    );

    await tapControl(tester, _pinLock);
    expect(tester.widget<SwitchListTile>(find.byKey(_pinLock)).value, isTrue);
    expect(find.textContaining('Could not save PIN lock.'), findsOneWidget);
    expect(
      tester.widget<SwitchListTile>(find.byKey(_pinLock)).onChanged,
      isNotNull,
    );
    await tapControl(tester, _pinLock);
    expect(attempts, 2);
  });

  testWidgets('pending PIN save disables profile actions and lock controls', (
    tester,
  ) async {
    final persistence = Completer<void>();
    var locks = 0;
    await showProfile(
      tester,
      enabled: false,
      onChanged: (_) => persistence.future,
      onLock: () async => locks++,
    );

    await tapControl(tester, _pinLock);
    expect(
      tester.widget<SwitchListTile>(find.byKey(_pinLock)).onChanged,
      isNull,
    );
    for (final key in [
      _lockApp,
      const Key('save-profile'),
      const Key('choose-profile-image'),
    ]) {
      expect(
        tester.widget<ButtonStyleButton>(find.byKey(key)).onPressed,
        isNull,
      );
    }
    expect(locks, 0);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    persistence.complete();
    await tester.pump();
    expect(
      tester.widget<SwitchListTile>(find.byKey(_pinLock)).onChanged,
      isNotNull,
    );
    expect(
      tester.widget<ButtonStyleButton>(find.byKey(_lockApp)).onPressed,
      isNotNull,
    );
  });

  testWidgets('Lock app waits for explicit action and shares saving guard', (
    tester,
  ) async {
    final locking = Completer<void>();
    var locks = 0;
    await showProfile(
      tester,
      enabled: true,
      onChanged: (_) async {},
      onLock: () {
        locks++;
        return locking.future;
      },
    );
    expect(locks, 0);

    await tapControl(tester, _lockApp);
    expect(locks, 1);
    expect(
      tester.widget<ButtonStyleButton>(find.byKey(_lockApp)).onPressed,
      isNull,
    );
    expect(
      tester.widget<SwitchListTile>(find.byKey(_pinLock)).onChanged,
      isNull,
    );

    locking.complete();
    await tester.pump();
    expect(
      tester.widget<ButtonStyleButton>(find.byKey(_lockApp)).onPressed,
      isNotNull,
    );
  });

  testWidgets('PIN controls fit a 320 pixel wide profile', (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await showProfile(
      tester,
      enabled: true,
      onChanged: (_) async {},
      onLock: () async {},
    );
    await tester.ensureVisible(find.byKey(_pinLock));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.byKey(_lockApp));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final fail in [false, true]) {
    testWidgets('PIN callback completing after disposal is safe (fail=$fail)', (
      tester,
    ) async {
      final persistence = Completer<void>();
      await showProfile(
        tester,
        enabled: true,
        onChanged: (_) => persistence.future,
      );
      await tapControl(tester, _pinLock);
      await tester.pumpWidget(const SizedBox.shrink());
      if (fail) {
        persistence.completeError(const FormatException('Save failed.'));
      } else {
        persistence.complete();
      }
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  }
}

class _MemoryProfileStore implements ProfileStore {
  StoredProfile value = const StoredProfile(name: 'Alice');

  @override
  Future<StoredProfile> load() async => value;

  @override
  Future<void> save(StoredProfile profile) async => value = profile;
}
