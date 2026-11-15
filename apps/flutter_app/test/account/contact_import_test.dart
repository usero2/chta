import 'package:cht/account/account_bridge.dart';
import 'package:cht/account/account_models.dart';
import 'package:cht/account/contacts_page.dart';
import 'package:cht/account/contact_qr_files.dart';
import 'package:cht/profile/profile_controller.dart';
import 'package:cht/profile/profile_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:qr_flutter/qr_flutter.dart';

const _identity = IdentityView(
  id: 'did:cht:me',
  rootPublicKey: '',
  noiseStaticPublicKey: '',
  derivationVersion: 1,
);
const _friend = ContactView(
  identityId: 'did:cht:friend',
  displayName: 'Remote friend',
  fingerprint: 'ABCD-1234',
  verified: false,
);

class _Store implements ProfileStore {
  @override
  Future<StoredProfile> load() async => const StoredProfile(name: 'Me');
  @override
  Future<void> save(StoredProfile profile) async {}
}

class _Bridge implements AccountBridge {
  bool includeRoutes = false;
  ContactView get friend => ContactView(
    identityId: _friend.identityId,
    displayName: _friend.displayName,
    fingerprint: _friend.fingerprint,
    verified: false,
    relayUrls: includeRoutes ? ['wss://one.example.com/cht'] : const [],
  );
  final saved = <ContactView>[];
  String? imported;
  @override
  Future<String> contactCard({
    String displayName = '',
    String avatar = '',
  }) async => '{"public":"card"}';
  @override
  Future<List<ContactView>> contacts() async => List.of(saved);
  @override
  Future<ContactView> inspectContactCard(String cardJson) async => friend;
  @override
  Future<List<ContactView>> addContact(
    String cardJson,
    String displayName,
  ) async {
    imported = cardJson;
    saved.add(friend);
    return List.of(saved);
  }

  @override
  Future<List<ContactView>> markContactVerified(String identityId) async {
    saved[0] = ContactView(
      identityId: friend.identityId,
      displayName: friend.displayName,
      fingerprint: friend.fingerprint,
      verified: true,
      relayUrls: friend.relayUrls,
    );
    return List.of(saved);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('QR uses exactly four quiet-zone modules at every density', () {
    for (final size in [260.0, 1200.0]) {
      final qr = QrCode.fromData(
        data: 'x' * 2800,
        errorCorrectLevel: QrErrorCorrectLevel.L,
      );
      final margin = contactQrMargin(size, qr.moduleCount);
      expect(
        margin / ((size - margin * 2) / qr.moduleCount),
        closeTo(4, 0.001),
      );
    }
  });

  testWidgets('mobile friend details use their own full width row', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bridge = _Bridge()..saved.add(_friend);
    final profile = ProfileController(_Store());
    await profile.load();
    await tester.pumpWidget(
      MaterialApp(
        home: ContactsPage(
          bridge: bridge,
          identity: _identity,
          onChat: (_) {},
          profileController: profile,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final details = find.byKey(const Key('friend-details-did:cht:friend'));
    await tester.scrollUntilVisible(
      details,
      350,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    final rect = tester.getRect(details);
    final avatar = tester.getRect(
      find.byKey(const Key('friend-avatar-did:cht:friend')),
    );
    final header = tester.getRect(
      find.byKey(const Key('friend-header-did:cht:friend')),
    );
    expect(rect.width, closeTo(header.width, 0.1));
    expect(rect.left, closeTo(header.left, 0.1));
    expect(rect.top, greaterThan(avatar.bottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets('verified add friend opens chat with the included relay route', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 920);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bridge = _Bridge()..includeRoutes = true;
    final profile = ProfileController(_Store());
    await profile.load();
    ContactView? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: ContactsPage(
          bridge: bridge,
          identity: _identity,
          onChat: (c) => selected = c,
          profileController: profile,
          readQrImage: () async => 'signed-card',
        ),
      ),
    );
    await tester.pumpAndSettle();
    final import = find.byKey(const Key('import-friend-qr-image'));
    await tester.ensureVisible(import);
    await tester.pumpAndSettle();
    await tester.tap(import);
    await tester.pumpAndSettle();
    expect(selected, isNull);
    await tester.ensureVisible(find.byType(CheckboxListTile));
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    expect(find.text('Add friend & chat'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-add-friend')));
    await tester.pumpAndSettle();
    expect(selected?.verified, isTrue);
    expect(selected?.relayUrls, ['wss://one.example.com/cht']);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'exported contact QR is a full resolution PNG with a white quiet zone',
    (tester) async {
      final bytes = await tester.runAsync(
        () => encodeContactQrImage('{"public":"contact-card"}'),
      );
      final decoded = image.decodePng(bytes!);
      expect(decoded, isNotNull);
      expect(decoded!.width, 1200);
      expect(decoded.height, 1200);
      final corner = decoded.getPixel(1, 1);
      expect([corner.r, corner.g, corner.b, corner.a], [255, 255, 255, 255]);
    },
  );
  testWidgets(
    'a QR image received over the Internet adds a friend without connecting to a node',
    (tester) async {
      tester.view.physicalSize = const Size(420, 920);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = _Bridge();
      final profile = ProfileController(_Store());
      await profile.load();
      await tester.pumpWidget(
        MaterialApp(
          home: ContactsPage(
            bridge: bridge,
            identity: _identity,
            onChat: (_) {},
            profileController: profile,
            readQrImage: () async => '{"remote":"signed-card-from-image"}',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('import-friend-qr-image')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('import-friend-qr-image')));
      await tester.pumpAndSettle();
      expect(find.text('Add Remote friend'), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirm-add-friend')));
      await tester.pumpAndSettle();
      expect(bridge.imported, '{"remote":"signed-card-from-image"}');
      expect(bridge.saved.single.verified, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'importing a remote card closes focused dialogs without disposing active fields',
    (tester) async {
      tester.view.physicalSize = const Size(420, 920);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = _Bridge();
      final profile = ProfileController(_Store());
      await profile.load();
      await tester.pumpWidget(
        MaterialApp(
          home: ContactsPage(
            bridge: bridge,
            identity: _identity,
            onChat: (_) {},
            profileController: profile,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('paste-friend-card')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('paste-friend-card')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('friend-card-input')),
        '{"remote":"card"}',
      );
      await tester.tap(find.text('Check card'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('friend-alias-input')),
        'My friend',
      );
      await tester.tap(find.byKey(const Key('confirm-add-friend')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(bridge.imported, '{"remote":"card"}');
      expect(find.text('Remote friend'), findsOneWidget);
    },
  );
}
