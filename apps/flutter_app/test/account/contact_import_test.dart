import 'dart:convert';
import 'dart:typed_data';

import 'package:cht/account/account_bridge.dart';
import 'package:cht/account/account_models.dart';
import 'package:cht/account/contacts_page.dart';
import 'package:cht/account/contact_qr_files.dart';
import 'package:cht/account/share_links.dart';
import 'package:cht/account/share_link_inbox.dart';
import 'package:cht/profile/profile_controller.dart';
import 'package:cht/profile/profile_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
    saved.add(
      ContactView(
        identityId: friend.identityId,
        displayName: displayName.isEmpty ? friend.displayName : displayName,
        signedName: friend.signedName,
        fingerprint: friend.fingerprint,
        verified: false,
        alias: displayName,
        relayUrls: friend.relayUrls,
        signedCard: cardJson.startsWith('{')
            ? (jsonDecode(cardJson) as Map).cast<String, Object?>()
            : null,
      ),
    );
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
  test(
    'HTTPS wrappers preserve contact and recipient-bound group magnet payloads',
    () {
      const card = '{"displayName":"Mali","signature":"synthetic"}';
      final link = Uri.parse(shareWebLink(contactMagnetLink(card)));
      expect(link.host, 'chta.app');
      expect(link.path, '/share/');
      expect(link.hasQuery, isFalse);
      expect(contactCardFromShare(link.toString()), card);
      final group = GroupInviteLink(
        invitationId: 'a' * 32,
        groupId: 'group:${'b' * 64}',
        ownerId: 'did:cht:${'c' * 64}',
        recipientId: 'did:cht:${'d' * 64}',
      );
      final groupShare = shareWebLink(group.toUri().toString());
      expect(isGroupMagnetLink(groupShare), isTrue);
      expect(GroupInviteLink.parse(groupShare).recipientId, group.recipientId);
      expect(magnetFromShareToken('invalid'), isNull);
    },
  );

  testWidgets('a launch link opens signed-card review after Contacts mounts', (
    tester,
  ) async {
    final profile = ProfileController(_Store());
    await profile.load();
    pendingShareLink.value = contactMagnetLink('{"remote":"from link"}');
    addTearDown(() => pendingShareLink.value = null);
    var routed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: ContactsPage(
          bridge: _Bridge(),
          identity: _identity,
          profileController: profile,
          onChat: (_) {},
          onOpenSharedLink: () => routed = true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(routed, isTrue);
    expect(find.text('Add Remote friend'), findsOneWidget);
    expect(pendingShareLink.value, isNull);
  });

  testWidgets(
    'phone contacts keep the share actions compact and build friends on demand',
    (tester) async {
      tester.view.physicalSize = const Size(360, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = _Bridge();
      bridge.saved.addAll(
        List.generate(
          100,
          (i) => ContactView(
            identityId: 'did:cht:friend-$i',
            displayName: 'Friend $i',
            fingerprint: 'ABC-$i',
            verified: true,
          ),
        ),
      );
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
      final qr = find.byKey(const Key('my-contact-qr'));
      final copy = find.byKey(const Key('copy-contact-link'));
      expect(tester.getCenter(qr).dx, 180);
      expect(
        tester.getTopLeft(copy).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(qr).dy),
      );
      expect(
        find.byKey(const Key('friend-avatar-did:cht:friend-0')),
        findsOneWidget,
      );
      final last = find.byKey(const Key('friend-avatar-did:cht:friend-99'));
      expect(last, findsNothing);
      await tester.scrollUntilVisible(
        last,
        600,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 50,
      );
      expect(last, findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'contact and relay QR keep a thin opaque four-module white border',
    (tester) async {
      for (final data in ['x' * 2800, 'wss://example.trycloudflare.com/cht']) {
        final size = data.startsWith('wss:') ? 112.0 : 260.0;
        final qr = QrCode.fromData(
          data: data,
          errorCorrectLevel: QrErrorCorrectLevel.L,
        );
        final margin = contactQrMargin(size, qr.moduleCount);
        final boundary = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: RepaintBoundary(
                key: boundary,
                child: ContactQrView(card: data, size: size),
              ),
            ),
          ),
        );
        await tester.pump();
        final raster =
            (boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImageSync();
        final bytes = await tester.runAsync(() => raster.toByteData());
        expect(bytes, isNotNull);
        expect(raster.width, size.toInt());
        expect(raster.height, size.toInt());
        // Four modules are the entire frame, with no extra outer padding.
        expect(margin, lessThan(size * 0.14));
        final module = (size - margin * 2) / qr.moduleCount;
        final matrix = QrImage(qr);
        for (var row = 0; row < qr.moduleCount; row++) {
          for (var col = 0; col < qr.moduleCount; col++) {
            final x = (margin + (col + 0.5) * module).floor();
            final y = (margin + (row + 0.5) * module).floor();
            expect(
              bytes!.getUint32((y * raster.width + x) * 4),
              matrix.isDark(row, col) ? 0x000000ff : 0xffffffff,
              reason: 'Correct QR module at ($row, $col)',
            );
          }
        }
        for (var y = 0; y < size; y++) {
          for (var x = 0; x < size; x++) {
            if (x >= margin.floor() &&
                y >= margin.floor() &&
                x < size - margin.floor() &&
                y < size - margin.floor()) {
              continue;
            }
            final offset = (y * raster.width + x) * 4;
            expect(
              bytes!.getUint32(offset),
              0xffffffff,
              reason: 'White quiet zone at ($x, $y), size $size',
            );
          }
        }
        raster.dispose();
      }
    },
  );
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

  testWidgets('friends search by alias or signed name and open details', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bridge = _Bridge()
      ..saved.addAll([
        const ContactView(
          identityId: 'did:cht:mali',
          displayName: 'Work teammate',
          signedName: 'Mali',
          alias: 'Work teammate',
          fingerprint: 'ABCD-1234',
          verified: true,
        ),
        _friend,
      ]);
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
    final search = find.byKey(const Key('friend-search'));
    expect(find.text('ABCD-1234'), findsNothing);

    for (final query in [' WORK ', 'mALI']) {
      await tester.enterText(search, query);
      await tester.pumpAndSettle();
      expect(find.text('Work teammate'), findsOneWidget);
      expect(find.text('Remote friend'), findsNothing);
    }
    await tester.enterText(search, 'no match');
    await tester.pumpAndSettle();
    expect(find.text('No matching friends.'), findsOneWidget);
    await tester.tap(find.byTooltip('Clear search'));
    await tester.pumpAndSettle();
    expect(find.text('Remote friend'), findsOneWidget);
    await tester.tap(find.text('Work teammate'));
    await tester.pumpAndSettle();
    expect(find.text('Mali'), findsOneWidget);
    expect(find.text('ABCD-1234'), findsOneWidget);
    expect(find.text('did:cht:mali'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('friend list import and export use a local backup file', (
    tester,
  ) async {
    final bridge = _Bridge();
    final profile = ProfileController(_Store());
    await profile.load();
    final file = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'format': 'chta-friends',
          'version': 1,
          'friends': [
            {
              'card': {'public': 'card'},
              'alias': 'Work friend',
              'verified': true,
            },
            {
              'card': {'public': 'card'},
              'alias': 'Duplicate',
            },
            {'card': false, 'alias': 'Broken'},
          ],
        }),
      ),
    );
    Uint8List? exported;
    await tester.pumpWidget(
      MaterialApp(
        home: ContactsPage(
          bridge: bridge,
          identity: _identity,
          onChat: (_) => fail('Import should not open a chat'),
          profileController: profile,
          readFriendList: () async => file,
          saveFriendList: (bytes) async {
            exported = bytes;
            return true;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Friend list options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import friends'));
    await tester.pumpAndSettle();
    expect(bridge.saved, isEmpty);
    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();
    expect(bridge.saved.single.alias, 'Work friend');
    expect(bridge.saved.single.verified, isFalse);
    expect(find.text('Imported 1, existing 1, skipped 1'), findsOneWidget);
    await tester.tap(find.byTooltip('Friend list options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export friends'));
    await tester.pumpAndSettle();
    final list = jsonDecode(utf8.decode(exported!)) as Map<String, dynamic>;
    expect(list['version'], 1);
    expect(list['friends'], [
      {
        'card': {'public': 'card'},
        'alias': 'Work friend',
      },
    ]);
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
        'magnet:?xt=urn%3Achta%3Acontact%3A1&x.chta-card=eyJyZW1vdGUiOiJjYXJkIn0',
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
      expect(find.text('My friend'), findsOneWidget);
    },
  );
}
