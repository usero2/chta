import 'dart:convert';

import 'package:cht/account/account_controller.dart';
import 'package:cht/account/account_models.dart';
import 'package:cht/account/contacts_page.dart';
import 'package:cht/app.dart';
import 'package:cht/chat/chat_controller.dart';
import 'package:cht/chat/chat_models.dart';
import 'package:cht/chat/widgets/conversation_list.dart';
import 'package:cht/chat/peer_history.dart';
import 'package:cht/chat/peer_history_store.dart';
import 'package:cht/chat/attachment_store.dart';
import 'package:cht/core/core_bridge.dart';
import 'package:cht/groups/group_crypto_bridge.dart';
import 'package:cht/groups/group_blob_bridge.dart';
import 'package:cht/contact_requests/contact_request_bridge.dart';
import 'package:cht/profile/profile_controller.dart';
import 'package:cht/profile/profile_avatar.dart';
import 'package:cht/profile/profile_store.dart';
import 'package:cht/routing/app_router.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;

void main() {
  testWidgets(
    'an unknown friend request is reviewed from chat before reciprocal trust',
    (tester) async {
      final bridge = _RequestAccountBridge(),
          router = AppRouter(initialPath: '/chats/general');
      await tester.pumpWidget(
        ChtApp(
          controller: ChatController(coreBridge: bridge),
          coreBridge: bridge,
          accountController: AccountController(bridge),
          peerHistoryStore: _HistoryTestStore(),
          router: router,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        bridge.savedContacts.any((c) => c.identityId == bridge.requester),
        isFalse,
      );
      expect(find.text('Friend requests (1)'), findsOneWidget);
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();
      expect(find.text('Request Alice'), findsWidgets);
      expect(
        bridge.savedContacts.any((c) => c.identityId == bridge.requester),
        isFalse,
      );
      await tester.tap(find.text('Accept'));
      await tester.pumpAndSettle();
      expect(
        bridge.savedContacts
            .firstWhere((c) => c.identityId == bridge.requester)
            .verified,
        isTrue,
      );
      expect(router.path, contains(Uri.encodeComponent(bridge.requester)));
      expect(find.text('Friend requests (1)'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
  testWidgets(
    'desktop keeps the same room order and sidebar width across room types',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = _TwoRoomAccountBridge();
      final groupId = 'group:${'a' * 64}';
      final router = AppRouter(
        initialPath: '/chats/${Uri.encodeComponent(groupId)}',
      );
      await tester.pumpWidget(
        ChtApp(
          controller: ChatController(coreBridge: bridge),
          coreBridge: bridge,
          accountController: AccountController(bridge),
          peerHistoryStore: _HistoryTestStore(),
          router: router,
        ),
      );
      await tester.pumpAndSettle();
      final expected = ['general', 'design', 'did:cht:alice', groupId];
      double? width;
      for (final route in [
        '/chats/${Uri.encodeComponent(groupId)}',
        '/chats/did%3Acht%3Aalice',
        '/chats/design',
        '/chats',
      ]) {
        router.go(route);
        await tester.pumpAndSettle();
        final list = find.byType(ConversationList);
        expect(list, findsOneWidget);
        expect(
          tester.widget<ConversationList>(list).conversations.map((c) => c.id),
          expected,
          reason: 'Room selection must not reorder the sidebar',
        );
        width ??= tester.getSize(list).width;
        expect(
          tester.getSize(list).width,
          width,
          reason: 'Sidebar width must remain constant',
        );
      }
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'desktop main navigation stays in the sidebar on every destination',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = _GroupAccountBridge();
      final router = AppRouter(initialPath: '/chats/group%3A${'a' * 64}');
      await tester.pumpWidget(
        ChtApp(
          controller: ChatController(coreBridge: bridge),
          coreBridge: bridge,
          accountController: AccountController(bridge),
          peerHistoryStore: _HistoryTestStore(),
          router: router,
        ),
      );
      await tester.pumpAndSettle();
      for (final entry in [
        ('Contacts', '/contacts'),
        ('Connect', '/connect'),
        ('Profile', '/profile'),
        ('Chats', '/chats'),
      ]) {
        final nav = find.byType(NavigationBar);
        expect(nav, findsOneWidget);
        expect(tester.getRect(nav).right, lessThanOrEqualTo(304));
        await tester.tap(
          find.descendant(of: nav, matching: find.text(entry.$1)),
        );
        await tester.pumpAndSettle();
        expect(router.path, entry.$2);
        expect(find.byType(ConversationList), findsOneWidget);
      }
      router.go('/chats/did%3Acht%3Aalice');
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsOneWidget);
      tester.view.physicalSize = const Size(720, 800);
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.byTooltip('Back to chats'), findsOneWidget);
      tester.view.physicalSize = const Size(721, 800);
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(ConversationList), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('missing group route retains a Back button on desktop', (
    tester,
  ) async {
    final bridge = _GroupAccountBridge();
    final router = AppRouter(initialPath: '/chats/group%3A${'c' * 64}');
    await tester.pumpWidget(
      ChtApp(
        controller: ChatController(coreBridge: bridge),
        coreBridge: bridge,
        accountController: AccountController(bridge),
        peerHistoryStore: _HistoryTestStore(),
        router: router,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Group unavailable'), findsOneWidget);
    await tester.tap(find.byTooltip('Back to chats'));
    await tester.pumpAndSettle();
    expect(router.path, '/chats');
    expect(find.byType(NavigationBar), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'opening a different local route does not notify siblings during build',
    (tester) async {
      final bridge = _TwoRoomAccountBridge();
      final router = AppRouter(initialPath: '/chats/group%3A${'a' * 64}');
      final chat = ChatController(coreBridge: bridge);
      await tester.pumpWidget(
        ChtApp(
          controller: chat,
          coreBridge: bridge,
          accountController: AccountController(bridge),
          peerHistoryStore: _HistoryTestStore(),
          router: router,
        ),
      );
      await tester.pumpAndSettle();
      expect(chat.selectedConversation.id, 'general');
      router.go('/chats/design');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(chat.selectedConversation.id, 'design');
      expect(find.byTooltip('Back to chats'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'group room hides main navigation and both Back actions return to chats',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = _GroupAccountBridge(),
          router = AppRouter(initialPath: '/chats/group%3A${'a' * 64}');
      await tester.pumpWidget(
        ChtApp(
          controller: ChatController(coreBridge: bridge),
          coreBridge: bridge,
          accountController: AccountController(bridge),
          peerHistoryStore: _HistoryTestStore(),
          router: router,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('group-room-title')), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      await tester.tap(find.byTooltip('Back to chats'));
      await tester.pumpAndSettle();
      expect(router.path, '/chats');
      expect(find.byType(NavigationBar), findsOneWidget);
      router.go('/chats/group%3A${'a' * 64}');
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(router.path, '/chats');
      expect(find.byType(NavigationBar), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'local and friend chat Back buttons restore the room list and navigation',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = _AccountTestBridge(hasExistingIdentity: true),
          router = AppRouter(initialPath: '/chats/general');
      await tester.pumpWidget(
        ChtApp(
          controller: ChatController(coreBridge: bridge),
          coreBridge: bridge,
          accountController: AccountController(bridge),
          peerHistoryStore: _HistoryTestStore(),
          router: router,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsNothing);
      await tester.tap(find.byTooltip('Back to chats'));
      await tester.pumpAndSettle();
      expect(router.path, '/chats');
      expect(find.byType(NavigationBar), findsOneWidget);
      router.go('/chats/did%3Acht%3Aalice');
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.byTooltip('Back to chats'), findsOneWidget);
      await tester.tap(find.byTooltip('Back to chats'));
      await tester.pumpAndSettle();
      expect(router.path, '/chats');
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'contacts and chat show the local profile and signed friend avatar',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bytes = image.encodeJpg(image.Image(width: 48, height: 48));
      final avatar = base64Encode(bytes);
      final profileStore = _ProfileTestStore()
        ..value = StoredProfile(name: 'My profile name', avatar: bytes);
      final profile = ProfileController(profileStore);
      await profile.load();
      final bridge = _AccountTestBridge(hasExistingIdentity: true);
      bridge.savedContacts = [bridge.savedContacts.single.withAvatar(avatar)];
      final router = AppRouter(initialPath: '/contacts');
      await tester.pumpWidget(
        ChtApp(
          controller: ChatController(coreBridge: bridge),
          coreBridge: bridge,
          accountController: AccountController(bridge),
          profileController: profile,
          peerHistoryStore: _HistoryTestStore(),
          router: router,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('My profile name'), findsOneWidget);
      expect(
        tester
            .widget<ProfileAvatar>(find.byKey(const Key('my-contact-avatar')))
            .bytes,
        bytes,
      );
      expect(
        tester
            .widget<ProfileAvatar>(
              find.byKey(const Key('friend-avatar-did:cht:alice')),
            )
            .avatarBase64,
        avatar,
      );
      expect(bridge.cardAvatar, profile.contactAvatar);
      await tester.ensureVisible(
        find.byKey(const Key('chat-contact-did:cht:alice')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('chat-contact-did:cht:alice')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ProfileAvatar>(find.byKey(const Key('chat-peer-avatar')))
            .avatarBase64,
        avatar,
      );
      expect(
        tester
            .widget<ProfileAvatar>(
              find.byKey(const Key('conversation-avatar-did:cht:alice')),
            )
            .avatarBase64,
        avatar,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('generated phrase fills the 24 editable recovery fields', (
    tester,
  ) async {
    final bridge = _AccountTestBridge();
    await tester.pumpWidget(
      ChtApp(
        controller: ChatController(coreBridge: bridge),
        coreBridge: bridge,
        accountController: AccountController(bridge),
        router: AppRouter(initialPath: '/identity'),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('create-identity')));
    await tester.pump();

    expect(_fieldValue(tester, 1), 'first1');
    expect(_fieldValue(tester, 24), 'first24');
    expect(find.text('Paste 24 words'), findsNothing);

    await tester.tap(find.byKey(const Key('random-recovery-phrase')));
    await tester.pump();

    expect(_fieldValue(tester, 1), 'second1');
    expect(_fieldValue(tester, 24), 'second24');

    await tester.tap(find.byKey(const Key('back-from-create-identity')));
    await tester.pump();

    expect(find.byKey(const Key('create-identity')), findsOneWidget);
    expect(bridge.discardedPendingIdentity, isTrue);
  });

  testWidgets('restore identity uses 24 word fields', (tester) async {
    final bridge = _AccountTestBridge();
    final phrase = List.generate(24, (index) => 'word${index + 1}').join(' ');
    await tester.pumpWidget(
      ChtApp(
        controller: ChatController(coreBridge: bridge),
        coreBridge: bridge,
        accountController: AccountController(bridge),
        router: AppRouter(initialPath: '/identity'),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('restore-recovery-1')), findsOneWidget);
    expect(find.byKey(const Key('restore-recovery-24')), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('restore-phrase-paste')),
      phrase,
    );
    await tester.pump();

    expect(
      tester
          .widget<TextField>(find.byKey(const Key('restore-recovery-1')))
          .controller!
          .text,
      'word1',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('restore-recovery-24')))
          .controller!
          .text,
      'word24',
    );

    await tester.scrollUntilVisible(
      find.byKey(const Key('restore-identity')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('restore-identity')));
    await tester.pump();
    expect(bridge.restoredPhrase, phrase);
  });

  testWidgets('contacts route shows a friend and opens secure chat', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bridge = _AccountTestBridge(hasExistingIdentity: true);
    final router = AppRouter(initialPath: '/contacts');
    await tester.pumpWidget(
      ChtApp(
        controller: ChatController(coreBridge: bridge),
        coreBridge: bridge,
        accountController: AccountController(bridge),
        router: router,
        peerHistoryStore: _HistoryTestStore(),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byType(ContactsPage),
        matching: find.text('Alice'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Signed name: Alice'), findsOneWidget);
    expect(find.textContaining('Identity verified'), findsOneWidget);

    await tester.ensureVisible(
      find.byKey(const Key('edit-alias-did:cht:alice')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('edit-alias-did:cht:alice')));
    await tester.pump();
    expect(find.text('Edit alias'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('contact-alias-input')),
      'Work Alice',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(bridge.savedContacts.single.alias, 'Work Alice');
    expect(find.text('Work Alice'), findsOneWidget);
    expect(find.textContaining('Signed name: Alice'), findsOneWidget);

    await tester.tap(find.byKey(const Key('chat-contact-did:cht:alice')));
    await tester.pump();
    await tester.pump();

    expect(router.path, '/chats/did%3Acht%3Aalice');
    expect(find.byKey(const Key('secure-chat-shell')), findsOneWidget);
    expect(find.text('Work Alice'), findsWidgets);
    expect(find.byKey(const Key('connect-to-chat')), findsOneWidget);

    await tester.tap(find.byKey(const Key('connect-to-chat')));
    await tester.pump();

    expect(router.path, '/chats/did%3Acht%3Aalice');
    expect(find.text('Connect with Work Alice'), findsWidgets);
    expect(find.byKey(const Key('close-connect-modal')), findsOneWidget);
  });

  testWidgets(
    'friend history stays visible offline while switching between rooms',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = _AccountTestBridge(hasExistingIdentity: true);
      final store = _HistoryTestStore();
      final saved = PeerHistory(store: store);
      await saved.load('did:cht:current');
      saved.add(
        'did:cht:alice',
        PeerMessage(
          id: 'persisted',
          text: 'Saved friend message',
          incoming: true,
          status: DeliveryStatus.delivered,
        ),
      );
      await saved.flush();
      saved.dispose();
      final router = AppRouter(initialPath: '/chats/did%3Acht%3Aalice');
      await tester.pumpWidget(
        ChtApp(
          controller: ChatController(coreBridge: bridge),
          coreBridge: bridge,
          accountController: AccountController(bridge),
          peerHistoryStore: store,
          router: router,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('peer-message-persisted')), findsOneWidget);
      expect(find.byKey(const Key('conversation-general')), findsOneWidget);
      expect(
        find.byKey(const Key('conversation-did:cht:alice')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('conversation-general')));
      await tester.pumpAndSettle();
      expect(router.path, '/chats/general');
      expect(find.byKey(const Key('conversation-general')), findsOneWidget);
      expect(
        find.byKey(const Key('conversation-did:cht:alice')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('conversation-did:cht:alice')));
      await tester.pumpAndSettle();
      expect(router.path, '/chats/did%3Acht%3Aalice');
      expect(find.byKey(const Key('peer-message-persisted')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('profile route saves the display name', (tester) async {
    final bridge = _AccountTestBridge(hasExistingIdentity: true);
    final store = _ProfileTestStore();
    final profile = ProfileController(store);
    await profile.load();
    final router = AppRouter(initialPath: '/profile');

    await tester.pumpWidget(
      ChtApp(
        controller: ChatController(coreBridge: bridge),
        coreBridge: bridge,
        accountController: AccountController(bridge),
        profileController: profile,
        peerHistoryStore: _HistoryTestStore(),
        router: router,
      ),
    );
    await tester.pumpAndSettle();

    expect(router.path, '/profile');
    expect(find.text('Profile'), findsWidgets);
    await tester.enterText(find.byKey(const Key('profile-name')), 'Alice CHT');
    await tester.tap(find.byKey(const Key('save-profile')));
    await tester.pumpAndSettle();

    expect(profile.name, 'Alice CHT');
    expect((await store.load()).name, 'Alice CHT');
  });
}

String _fieldValue(WidgetTester tester, int number) => tester
    .widget<TextField>(find.byKey(Key('confirm-recovery-$number')))
    .controller!
    .text;

class _ProfileTestStore implements ProfileStore {
  StoredProfile value = const StoredProfile();

  @override
  Future<StoredProfile> load() async => value;

  @override
  Future<void> save(StoredProfile profile) async => value = profile;
}

class _HistoryTestStore implements PeerHistoryStore {
  final values = <String, String>{};
  @override
  Future<String?> load(String ownerId) async => values[ownerId];
  @override
  Future<void> save(String ownerId, String source) async {
    values[ownerId] = source;
  }
}

class _RequestAccountBridge extends _GroupAccountBridge
    implements ContactRequestBridge {
  final requester = 'did:cht:${'a' * 64}';
  String? requestState;
  String get requestCard => jsonEncode({
    'identity': {'id': requester},
    'displayName': 'Request Alice',
  });
  @override
  Future<String?> loadGroupBlob(String owner, String key) async {
    if (key != 'contact-requests-v1') return null;
    return requestState ??
        jsonEncode({
          'version': 1,
          'ownerId': owner,
          'outbox': [],
          'decisions': [],
          'inbox': [
            {
              'peerId': requester,
              'requestId': '1' * 32,
              'cardJson': requestCard,
              'status': 'pending',
              'createdAt': 1000,
            },
          ],
        });
  }

  @override
  Future<void> saveGroupBlob(String owner, String key, String value) async {
    if (key == 'contact-requests-v1') requestState = value;
  }

  @override
  Future<ContactView> inspectContactCard(String source) async => ContactView(
    identityId: requester,
    displayName: 'Request Alice',
    fingerprint: 'Synthetic fingerprint',
    verified: false,
  );
  @override
  Future<List<ContactView>> addContact(String source, String name) async {
    savedContacts = [...savedContacts, await inspectContactCard(source)];
    return savedContacts;
  }

  @override
  Future<List<ContactView>> markContactVerified(String id) async {
    savedContacts = [
      for (final c in savedContacts)
        if (c.identityId == id)
          ContactView(
            identityId: c.identityId,
            displayName: c.displayName,
            fingerprint: c.fingerprint,
            verified: true,
          )
        else
          c,
    ];
    return savedContacts;
  }

  @override
  Future<Map<String, Object?>> contactRequestCall(
    String operation,
    Map<String, Object?> args,
  ) async => throw UnimplementedError();
}

class _TwoRoomAccountBridge extends _GroupAccountBridge {
  @override
  Future<ChatSnapshot> loadSnapshot() async => ChatSnapshot(
    schemaVersion: 1,
    conversations: [
      ...(await super.loadSnapshot()).conversations,
      ConversationView(
        id: 'design',
        title: 'Design',
        preview: '',
        updatedAtMilliseconds: 1,
        messages: const [],
      ),
    ],
  );
}

class _GroupAccountBridge extends _AccountTestBridge
    implements GroupCryptoBridge, GroupBlobBridge, AttachmentBridge {
  _GroupAccountBridge() : super(hasExistingIdentity: true);
  @override
  Future<IdentityView> identity() async => IdentityView(
    id: 'did:cht:${'b' * 64}',
    rootPublicKey: '',
    noiseStaticPublicKey: '',
    derivationVersion: 1,
  );
  @override
  Future<Map<String, Object?>> groupCall(
    String op,
    Map<String, Object?> args,
  ) async {
    if (op == 'list') {
      return {
        'groups': [
          {
            'groupId': 'group:${'a' * 64}',
            'name': 'Test group',
            'ownerId': 'did:cht:${'b' * 64}',
            'epoch': 1,
            'closed': false,
            'members': [
              {'identityId': 'did:cht:${'b' * 64}', 'displayName': 'Owner'},
            ],
            'states': <String>[],
          },
        ],
      };
    }
    if (op == 'export') return {'data': '{}'};
    throw UnimplementedError(op);
  }

  @override
  Future<String?> loadGroupBlob(String owner, String key) async => null;
  @override
  Future<void> saveGroupBlob(String owner, String key, String value) async {}
  @override
  Future<void> deleteGroupBlob(String owner, String key) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _AccountTestBridge implements AppBridge {
  _AccountTestBridge({this.hasExistingIdentity = false})
    : savedContacts = [
        const ContactView(
          identityId: 'did:cht:alice',
          displayName: 'Alice',
          signedName: 'Alice',
          fingerprint: 'AA11-BB22',
          verified: true,
        ),
      ];

  final bool hasExistingIdentity;
  List<ContactView> savedContacts;
  var generation = 0;
  var discardedPendingIdentity = false;
  String? restoredPhrase;
  String? cardAvatar;

  @override
  Future<bool> hasIdentity() async => hasExistingIdentity;

  @override
  Future<CreatedIdentityView> createIdentity() async {
    generation++;
    final prefix = generation == 1 ? 'first' : 'second';
    return CreatedIdentityView(
      mnemonic: List.generate(24, (index) => '$prefix${index + 1}').join(' '),
      identity: _identity(prefix),
    );
  }

  @override
  Future<void> discardPendingIdentity() async {
    discardedPendingIdentity = true;
  }

  IdentityView _identity(String suffix) => IdentityView(
    id: 'did:cht:$suffix',
    rootPublicKey: 'root-$suffix',
    noiseStaticPublicKey: 'noise-$suffix',
    derivationVersion: 1,
  );

  @override
  Future<IdentityView> confirmRecovery(String phrase) async =>
      _identity('confirmed');
  @override
  Future<IdentityView> restoreIdentity(String phrase) async {
    restoredPhrase = phrase;
    return _identity('restored');
  }

  @override
  Future<IdentityView> identity() async => _identity('current');
  @override
  Future<String> contactCard({
    String displayName = '',
    String avatar = '',
  }) async {
    cardAvatar = avatar;
    return '{}';
  }

  @override
  Future<List<ContactView>> contacts() async => savedContacts;
  @override
  Future<ContactView> inspectContactCard(String cardJson) =>
      throw UnimplementedError();
  @override
  Future<List<ContactView>> addContact(
    String cardJson,
    String displayName,
  ) async => const [];
  @override
  Future<List<ContactView>> markContactVerified(String identityId) async =>
      const [];

  @override
  Future<List<ContactView>> setContactAlias(
    String identityId,
    String alias,
  ) async {
    savedContacts = [
      ContactView(
        identityId: identityId,
        displayName: alias.isEmpty ? 'Alice' : alias,
        signedName: 'Alice',
        alias: alias,
        fingerprint: 'AA11-BB22',
        verified: true,
      ),
    ];
    return savedContacts;
  }

  @override
  Future<List<ContactView>> removeContact(String identityId) async => const [];
  @override
  Future<String> preparePeer(String cardJson, bool initiator) =>
      throw UnimplementedError();
  @override
  Future<String> startPeerHandshake() => throw UnimplementedError();
  @override
  Future<Map<String, Object?>> receivePeerHandshake(String frame) =>
      throw UnimplementedError();
  @override
  Future<String> encryptPeerMessage(
    String messageId,
    String text, {
    int? sentAtMilliseconds,
  }) => throw UnimplementedError();
  @override
  Future<Map<String, Object?>> decryptPeerMessage(String frame) =>
      throw UnimplementedError();
  @override
  Future<String> version() async => 'cht-core@test';
  @override
  Future<ChatSnapshot> loadSnapshot() async => ChatSnapshot(
    schemaVersion: 1,
    conversations: [
      ConversationView(
        id: 'general',
        title: 'General',
        preview: 'test',
        updatedAtMilliseconds: 1,
        messages: const [],
      ),
    ],
  );
  @override
  Future<ChatSnapshot> sendText(
    String conversationId,
    String text,
    int sentAtMilliseconds,
  ) => loadSnapshot();
}
