import 'dart:convert';
import 'dart:js_interop';

import '../account/account_models.dart';
import '../account/desktop_identity_bridge.dart';
import '../profile/profile_store.dart';
import '../profile/contact_avatar.dart';
import '../account/routed_contact_bridge.dart';

import '../chat/chat_models.dart';
import '../chat/chunked_attachment_bridge.dart';
import 'core_bridge.dart';
import '../relay/relay_crypto_bridge.dart';
import '../seed/seed_crypto_bridge.dart';
import '../groups/group_crypto_bridge.dart';
import '../groups/group_blob_bridge.dart';

@JS('chtCore.savedIdentities')
external JSPromise<JSString> _savedIdentities();
@JS('chtCore.rememberIdentity')
external JSPromise<JSString> _rememberIdentity(
  JSString pin,
  JSString name,
  JSString avatar,
  JSString contactAvatar,
);
@JS('chtCore.unlockIdentity')
external JSPromise<JSString> _unlockIdentity(JSString identityId, JSString pin);
@JS('chtCore.lockIdentity')
external JSPromise<JSAny?> _lockIdentity();
@JS('chtCore.loadDesktopProfile')
external JSPromise<JSString> _loadDesktopProfile();
@JS('chtCore.saveDesktopProfile')
external JSPromise<JSAny?> _saveDesktopProfile(JSString source);

@JS('chtCore.groupCall')
external JSPromise<JSString> _groupCall(JSString operation, JSString args);
@JS('chtCore.loadGroupBlob')
external JSPromise<JSString?> _loadGroupBlob(JSString ownerId, JSString key);
@JS('chtCore.saveGroupBlob')
external JSPromise<JSAny?> _saveGroupBlob(
  JSString ownerId,
  JSString key,
  JSString value,
);
@JS('chtCore.deleteGroupBlob')
external JSPromise<JSAny?> _deleteGroupBlob(JSString ownerId, JSString key);

@JS('chtCore.signSeedSignal')
external JSPromise<JSString> _signSeedSignal(
  JSString peerId,
  JSString messageId,
  JSString text,
  JSNumber now,
);
@JS('chtCore.inspectSeedSignal')
external JSPromise<JSString> _inspectSeedSignal(
  JSString source,
  JSString expectedPeer,
  JSNumber now,
);

@JS('chtCore.contactCardWithRelays')
external JSPromise<JSString> _contactCardWithRelays(
  JSString name,
  JSString avatar,
  JSString urls,
);

@JS('chtCore.relayProof')
external JSPromise<JSString> _relayProof(JSString nonce, JSString relayId);
@JS('chtCore.inspectRelayRecord')
external JSPromise<JSString> _inspectRelayRecord(
  JSString source,
  JSNumber now,
  JSBoolean allowLoopback,
);
@JS('chtCore.loadRelayState')
external JSPromise<JSString> _loadRelayState();
@JS('chtCore.saveRelayState')
external JSPromise<JSAny?> _saveRelayState(JSString source);

@JS('chtCore.version')
external JSPromise<JSString> _coreVersion();

@JS('chtCore.snapshot')
external JSPromise<JSString> _coreSnapshot();
@JS('chtCore.deleteConversation')
external JSPromise<JSString> _coreDeleteConversation(JSString conversationId);

@JS('chtCore.sendText')
external JSPromise<JSString> _coreSendText(
  JSString conversationId,
  JSString text,
  JSNumber sentAtMilliseconds,
);

@JS('chtCore.hasIdentity')
external JSPromise<JSBoolean> _hasIdentity();

@JS('chtCore.createIdentity')
external JSPromise<JSString> _createIdentity();

@JS('chtCore.discardPendingIdentity')
external JSPromise<JSAny?> _discardPendingIdentity();

@JS('chtCore.confirmRecovery')
external JSPromise<JSString> _confirmRecovery(JSString phrase);

@JS('chtCore.restoreIdentity')
external JSPromise<JSString> _restoreIdentity(JSString phrase);

@JS('chtCore.identity')
external JSPromise<JSString> _identity();

@JS('chtCore.contactCard')
external JSPromise<JSString> _contactCard(
  JSString displayName,
  JSString avatar,
);

@JS('chtCore.contacts')
external JSPromise<JSString> _contacts();

@JS('chtCore.inspectContactCard')
external JSPromise<JSString> _inspectContactCard(JSString cardJson);

@JS('chtCore.addContact')
external JSPromise<JSString> _addContact(
  JSString cardJson,
  JSString displayName,
);

@JS('chtCore.markContactVerified')
external JSPromise<JSString> _markContactVerified(JSString identityId);

@JS('chtCore.setContactAlias')
external JSPromise<JSString> _setContactAlias(
  JSString identityId,
  JSString alias,
);

@JS('chtCore.removeContact')
external JSPromise<JSString> _removeContact(JSString identityId);

@JS('chtCore.preparePeer')
external JSPromise<JSString> _preparePeer(
  JSString cardJson,
  JSBoolean initiator,
);

@JS('chtCore.startPeerHandshake')
external JSPromise<JSString> _startPeerHandshake();

@JS('chtCore.receivePeerHandshake')
external JSPromise<JSString> _receivePeerHandshake(JSString frame);

@JS('chtCore.encryptPeerMessage')
external JSPromise<JSString> _encryptPeerMessage(
  JSString messageId,
  JSString text,
  JSNumber? sentAtMilliseconds,
);

@JS('chtCore.decryptPeerMessage')
external JSPromise<JSString> _decryptPeerMessage(JSString frame);

AppBridge createPlatformCoreBridge() => const _WebCoreBridge();

class _WebCoreBridge
    implements
        AppBridge,
        ConversationManagementBridge,
        DesktopIdentityBridge,
        RelayCryptoBridge,
        SeedCryptoBridge,
        RoutedContactBridge,
        BrowserChunkedStorageHost,
        GroupCryptoBridge,
        GroupBlobBridge {
  @override
  bool get usesPlatformHistory => false;
  @override
  Future<String?> loadNativeHistory(String ownerId) async => null;
  @override
  Future<void> saveNativeHistory(String ownerId, String source) async =>
      throw UnsupportedError('Use browser history storage');
  @override
  Future<List<SavedIdentityView>> savedIdentities() async =>
      (jsonDecode((await _savedIdentities().toDart).toDart) as List)
          .map(
            (value) => SavedIdentityView.fromJson(
              (value as Map).cast<String, Object?>(),
            ),
          )
          .toList();
  @override
  Future<IdentityView> rememberIdentity(
    String pin,
    String displayName,
    String avatar,
  ) async => IdentityView.fromJson(
    _decodeMap(
      (await _rememberIdentity(
        pin.toJS,
        displayName.toJS,
        avatar.toJS,
        createContactAvatar(avatar.isEmpty ? null : base64Decode(avatar)).toJS,
      ).toDart).toDart,
    ),
  );
  @override
  Future<IdentityView> unlockIdentity(String identityId, String pin) async =>
      IdentityView.fromJson(
        _decodeMap(
          (await _unlockIdentity(identityId.toJS, pin.toJS).toDart).toDart,
        ),
      );
  @override
  Future<void> lockIdentity() async {
    await _lockIdentity().toDart;
  }

  @override
  Future<StoredProfile> loadDesktopProfile() async {
    final value = _decodeMap((await _loadDesktopProfile().toDart).toDart);
    final avatar = value['avatar'] as String? ?? '';
    return StoredProfile(
      name: value['name'] as String? ?? '',
      avatar: avatar.isEmpty ? null : base64Decode(avatar),
    );
  }

  @override
  Future<void> saveDesktopProfile(StoredProfile profile) async {
    await _saveDesktopProfile(
      jsonEncode({
        'name': profile.name,
        'avatar': profile.avatar == null ? '' : base64Encode(profile.avatar!),
        'contactAvatar': createContactAvatar(profile.avatar),
      }).toJS,
    ).toDart;
  }

  @override
  Future<Map<String, Object?>> groupCall(
    String operation,
    Map<String, Object?> args,
  ) async => _decodeMap(
    (await _groupCall(operation.toJS, jsonEncode(args).toJS).toDart).toDart,
  );

  @override
  Future<String?> loadGroupBlob(String ownerId, String key) async =>
      (await _loadGroupBlob(ownerId.toJS, key.toJS).toDart)?.toDart;
  @override
  Future<void> saveGroupBlob(String ownerId, String key, String value) async {
    await _saveGroupBlob(ownerId.toJS, key.toJS, value.toJS).toDart;
  }

  @override
  Future<void> deleteGroupBlob(String ownerId, String key) async {
    await _deleteGroupBlob(ownerId.toJS, key.toJS).toDart;
  }

  @override
  Future<String> contactCardWithRelays({
    String displayName = '',
    String avatar = '',
    List<String> relayUrls = const [],
  }) async => (await _contactCardWithRelays(
    displayName.toJS,
    avatar.toJS,
    jsonEncode(relayUrls).toJS,
  ).toDart).toDart;
  @override
  Future<String> relayProof(String nonce, String relayId) async =>
      (await _relayProof(nonce.toJS, relayId.toJS).toDart).toDart;
  @override
  Future<String> signSeedSignal(
    String peerId,
    String messageId,
    String text,
    int now,
  ) async => (await _signSeedSignal(
    peerId.toJS,
    messageId.toJS,
    text.toJS,
    now.toJS,
  ).toDart).toDart;
  @override
  Future<String> inspectSeedSignal(
    String source,
    String expectedPeer,
    int now,
  ) async => (await _inspectSeedSignal(
    source.toJS,
    expectedPeer.toJS,
    now.toJS,
  ).toDart).toDart;
  @override
  Future<String> inspectRelayRecord(
    String source,
    int now,
    bool allowLoopback,
  ) async => (await _inspectRelayRecord(
    source.toJS,
    now.toJS,
    allowLoopback.toJS,
  ).toDart).toDart;
  @override
  Future<String> loadRelayState() async =>
      (await _loadRelayState().toDart).toDart;
  @override
  Future<void> saveRelayState(String source) async {
    await _saveRelayState(source.toJS).toDart;
  }

  const _WebCoreBridge();

  @override
  Future<String> version() async => (await _coreVersion().toDart).toDart;

  @override
  Future<ChatSnapshot> loadSnapshot() async =>
      _decodeSnapshot((await _coreSnapshot().toDart).toDart);

  @override
  Future<ChatSnapshot> deleteConversation(String conversationId) async =>
      _decodeSnapshot(
        (await _coreDeleteConversation(conversationId.toJS).toDart).toDart,
      );

  @override
  Future<ChatSnapshot> sendText(
    String conversationId,
    String text,
    int sentAtMilliseconds,
  ) async => _decodeSnapshot(
    (await _coreSendText(
      conversationId.toJS,
      text.toJS,
      sentAtMilliseconds.toJS,
    ).toDart).toDart,
  );

  @override
  Future<bool> hasIdentity() async => (await _hasIdentity().toDart).toDart;

  @override
  Future<CreatedIdentityView> createIdentity() async =>
      CreatedIdentityView.fromJson(
        _decodeMap((await _createIdentity().toDart).toDart),
      );

  @override
  Future<void> discardPendingIdentity() async {
    await _discardPendingIdentity().toDart;
  }

  @override
  Future<IdentityView> confirmRecovery(String phrase) async =>
      IdentityView.fromJson(
        _decodeMap((await _confirmRecovery(phrase.toJS).toDart).toDart),
      );

  @override
  Future<IdentityView> restoreIdentity(String phrase) async =>
      IdentityView.fromJson(
        _decodeMap((await _restoreIdentity(phrase.toJS).toDart).toDart),
      );

  @override
  Future<IdentityView> identity() async =>
      IdentityView.fromJson(_decodeMap((await _identity().toDart).toDart));

  @override
  Future<String> contactCard({
    String displayName = '',
    String avatar = '',
  }) async => (await _contactCard(displayName.toJS, avatar.toJS).toDart).toDart;

  @override
  Future<List<ContactView>> contacts() async =>
      _decodeContacts((await _contacts().toDart).toDart);

  @override
  Future<ContactView> inspectContactCard(String cardJson) async =>
      ContactView.fromJson(
        _decodeMap((await _inspectContactCard(cardJson.toJS).toDart).toDart),
      );

  @override
  Future<List<ContactView>> addContact(
    String cardJson,
    String displayName,
  ) async => _decodeContacts(
    (await _addContact(cardJson.toJS, displayName.toJS).toDart).toDart,
  );

  @override
  Future<List<ContactView>> markContactVerified(String identityId) async =>
      _decodeContacts(
        (await _markContactVerified(identityId.toJS).toDart).toDart,
      );

  @override
  Future<List<ContactView>> setContactAlias(
    String identityId,
    String alias,
  ) async => _decodeContacts(
    (await _setContactAlias(identityId.toJS, alias.toJS).toDart).toDart,
  );

  @override
  Future<List<ContactView>> removeContact(String identityId) async =>
      _decodeContacts((await _removeContact(identityId.toJS).toDart).toDart);

  @override
  Future<String> preparePeer(String cardJson, bool initiator) async =>
      (await _preparePeer(cardJson.toJS, initiator.toJS).toDart).toDart;

  @override
  Future<String> startPeerHandshake() async =>
      (await _startPeerHandshake().toDart).toDart;

  @override
  Future<Map<String, Object?>> receivePeerHandshake(String frame) async =>
      _decodeMap((await _receivePeerHandshake(frame.toJS).toDart).toDart);

  @override
  Future<String> encryptPeerMessage(
    String messageId,
    String text, {
    int? sentAtMilliseconds,
  }) async => (await _encryptPeerMessage(
    messageId.toJS,
    text.toJS,
    sentAtMilliseconds?.toJS,
  ).toDart).toDart;

  @override
  Future<Map<String, Object?>> decryptPeerMessage(String frame) async =>
      _decodeMap((await _decryptPeerMessage(frame.toJS).toDart).toDart);
}

ChatSnapshot _decodeSnapshot(String source) {
  return ChatSnapshot.fromJson(_decodeMap(source));
}

Map<String, Object?> _decodeMap(String source) {
  final value = jsonDecode(source);
  if (value is Map<String, Object?>) return value;
  throw const FormatException('Expected a JSON object');
}

List<ContactView> _decodeContacts(String source) {
  final value = jsonDecode(source);
  if (value is! List<Object?>) {
    throw const FormatException('Expected a JSON contact list');
  }
  return value
      .map(
        (item) => ContactView.fromJson((item! as Map).cast<String, Object?>()),
      )
      .toList(growable: false);
}
