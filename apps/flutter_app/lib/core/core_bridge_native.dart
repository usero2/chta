import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';

import '../account/account_models.dart';
import '../account/routed_contact_bridge.dart';
import '../account/desktop_identity_bridge.dart';
import '../account/android_session_bridge.dart';
import '../profile/profile_store.dart';
import '../profile/contact_avatar.dart';
import '../p2p/p2p_bridge_factory.dart';
import '../relay/relay_crypto_bridge.dart';
import '../seed/seed_crypto_bridge.dart';
import '../chat/chat_models.dart';
import '../chat/attachment_store.dart';
import '../chat/chunked_attachment_bridge.dart';
import '../groups/group_crypto_bridge.dart';
import '../groups/group_blob_bridge.dart';
import '../contact_requests/contact_request_bridge.dart';
import 'core_bridge.dart';

typedef _CallNative = Pointer<Utf8> Function(Pointer<Utf8> request);
typedef _CallDart = Pointer<Utf8> Function(Pointer<Utf8> request);
typedef _FreeNative = Void Function(Pointer<Utf8> value);
typedef _FreeDart = void Function(Pointer<Utf8> value);

AppBridge createPlatformCoreBridge() => _NativeCoreBridge();

Future<Object?> _vaultCall(String command, Map<String, Object?> args) =>
    Isolate.run(() => _NativeCoreBridge()._invoke(command, args));

class _NativeCoreBridge
    implements
        AppBridge,
        ConversationManagementBridge,
        DesktopIdentityBridge,
        InitializableCoreBridge,
        RelayCryptoBridge,
        SeedCryptoBridge,
        AttachmentBridge,
        ChunkedAttachmentBridge,
        AndroidSessionBridge,
        RoutedContactBridge,
        GroupCryptoBridge,
        ContactRequestBridge,
        GroupBlobBridge {
  @override
  Future<Map<String, Object?>> contactRequestCall(
    String operation,
    Map<String, Object?> args,
  ) async => _map(
    _invoke('contactRequestCall', {'operation': operation, 'args': args}),
  );
  @override
  Future<Map<String, Object?>> groupCall(
    String operation,
    Map<String, Object?> args,
  ) async => _map(_invoke('groupCall', {'operation': operation, 'args': args}));

  @override
  Future<String?> loadGroupBlob(String ownerId, String key) async =>
      (await _vaultCall('loadGroupBlob', {'ownerId': ownerId, 'key': key}))
          as String?;
  @override
  Future<void> saveGroupBlob(String ownerId, String key, String value) async {
    await _vaultCall('saveGroupBlob', {
      'ownerId': ownerId,
      'key': key,
      'value': value,
    });
  }

  @override
  Future<void> deleteGroupBlob(String ownerId, String key) async {
    await _vaultCall('deleteGroupBlob', {'ownerId': ownerId, 'key': key});
  }

  @override
  Future<ChunkedAttachmentState> beginChunkedAttachment(
    String ownerId,
    String id,
    int size,
    int chunkSize, {
    String? digest,
  }) async => ChunkedAttachmentState.fromJson(
    _map(
      await _vaultCall('beginChunkedAttachment', {
        'ownerId': ownerId,
        'id': id,
        'size': size,
        'chunkSize': chunkSize,
        'digest': digest,
      }),
    ),
  );
  @override
  Future<ChunkedAttachmentState> chunkedAttachmentStatus(
    String ownerId,
    String id,
  ) async => ChunkedAttachmentState.fromJson(
    _map(
      await _vaultCall('chunkedAttachmentStatus', {
        'ownerId': ownerId,
        'id': id,
      }),
    ),
  );
  @override
  Future<void> writeChunkedAttachment(
    String ownerId,
    String id,
    int index,
    Uint8List bytes,
  ) async {
    if (bytes.length > maxChunkedAttachmentChunkSize) {
      throw const FormatException('Attachment chunk is too large');
    }
    await _vaultCall('writeChunkedAttachment', {
      'ownerId': ownerId,
      'id': id,
      'index': index,
      'data': base64Encode(bytes),
    });
  }

  @override
  Future<Uint8List> readChunkedAttachment(
    String ownerId,
    String id,
    int index,
  ) async {
    final data = await _vaultCall('readChunkedAttachment', {
      'ownerId': ownerId,
      'id': id,
      'index': index,
    }) as String;
    if (data.length > ((maxChunkedAttachmentChunkSize + 2) ~/ 3) * 4) {
      throw const FormatException('Attachment chunk is too large');
    }
    return base64Decode(data);
  }

  @override
  Future<ChunkedAttachmentState> finishChunkedAttachment(
    String ownerId,
    String id, {
    String? expectedDigest,
  }) async => ChunkedAttachmentState.fromJson(
    _map(
      await _vaultCall('finishChunkedAttachment', {
        'ownerId': ownerId,
        'id': id,
        'expectedDigest': expectedDigest,
      }),
    ),
  );
  @override
  Future<void> deleteChunkedAttachment(String ownerId, String id) async {
    await _vaultCall('deleteChunkedAttachment', {'ownerId': ownerId, 'id': id});
  }

  @override
  bool get supportsRememberedSession => Platform.isAndroid;
  @override
  Future<IdentityView?> resumeIdentity() async {
    final value = await _vaultCall('resumeIdentity', {});
    return value == null ? null : IdentityView.fromJson(_map(value));
  }

  @override
  Future<SessionPreferences> sessionPreferences() async =>
      SessionPreferences.fromJson(
        _map(await _vaultCall('sessionPreferences', {})),
      );
  @override
  Future<SessionPreferences> setPinLock(String ownerId, bool required) async =>
      SessionPreferences.fromJson(
        _map(
          await _vaultCall('setPinLock', {
            'ownerId': ownerId,
            'required': required,
          }),
        ),
      );
  @override
  Future<void> saveSessionRoute(String ownerId, String path) async {
    await _vaultCall('saveSessionRoute', {'ownerId': ownerId, 'path': path});
  }

  @override
  Future<void> savePeerAttachment(
    String ownerId,
    String digest,
    String data,
  ) async {
    await _vaultCall('savePeerAttachment', {
      'ownerId': ownerId,
      'digest': digest,
      'data': data,
    });
  }

  @override
  Future<String?> loadPeerAttachment(String ownerId, String digest) async =>
      await _vaultCall('loadPeerAttachment', {
        'ownerId': ownerId,
        'digest': digest,
      }) as String?;
  @override
  Future<String> contactCardWithRelays({
    String displayName = '',
    String avatar = '',
    List<String> relayUrls = const [],
  }) async =>
      _invoke('contactCard', {
            'displayName': displayName,
            'avatar': avatar,
            'relayUrls': relayUrls,
          })!
          as String;
  @override
  Future<String> relayProof(String nonce, String relayId) async =>
      _invoke('relayProof', {'nonce': nonce, 'relayId': relayId})! as String;
  @override
  Future<String> signSeedSignal(
    String peerId,
    String messageId,
    String text,
    int now,
  ) async =>
      _invoke('signSeedSignal', {
            'peerId': peerId,
            'messageId': messageId,
            'text': text,
            'now': now,
          })!
          as String;
  @override
  Future<String> inspectSeedSignal(
    String source,
    String expectedPeer,
    int now,
  ) async =>
      _invoke('inspectSeedSignal', {
            'source': source,
            'expectedPeer': expectedPeer,
            'now': now,
          })!
          as String;
  @override
  Future<String> inspectRelayRecord(
    String source,
    int now,
    bool allowLoopback,
  ) async =>
      _invoke('inspectRelayRecord', {
            'source': source,
            'now': now,
            'allowLoopback': allowLoopback,
          })!
          as String;
  @override
  Future<String> loadRelayState() async => _invoke('loadRelayState')! as String;
  @override
  Future<void> saveRelayState(String source) async {
    _invoke('saveRelayState', {'source': source});
  }

  _NativeCoreBridge() {
    final executableDirectory = File(Platform.resolvedExecutable).parent.path;
    final libraryName = Platform.isWindows
        ? 'cht_core.dll'
        : Platform.isMacOS
        ? 'libcht_core.dylib'
        : 'libcht_core.so';
    final library = DynamicLibrary.open(
      Platform.isAndroid
          ? libraryName
          : '$executableDirectory${Platform.pathSeparator}$libraryName',
    );
    _call = library.lookupFunction<_CallNative, _CallDart>('cht_call');
    _free = library.lookupFunction<_FreeNative, _FreeDart>('cht_free_string');
  }

  late final _CallDart _call;
  late final _FreeDart _free;

  @override
  Future<void> initializePlatform() async {
    if (!Platform.isAndroid) return;
    final configuration = await const MethodChannel('app.cht/platform')
        .invokeMapMethod<String, String>('storageConfiguration');
    if (configuration == null) {
      throw StateError('Android secure storage is unavailable');
    }
    _invoke('configureAndroidStorage', configuration);
  }

  @override
  bool get usesPlatformHistory => Platform.isAndroid;

  @override
  Future<String?> loadNativeHistory(String ownerId) async {
    final source = _invoke('loadPeerHistory', {'ownerId': ownerId})! as String;
    return source.isEmpty ? null : source;
  }

  @override
  Future<void> saveNativeHistory(String ownerId, String source) async {
    _invoke('savePeerHistory', {'ownerId': ownerId, 'source': source});
  }

  @override
  Future<List<SavedIdentityView>> savedIdentities() async =>
      (_invoke('listSavedIdentities')! as List)
          .map((value) => SavedIdentityView.fromJson(_map(value)))
          .toList();

  @override
  Future<IdentityView> rememberIdentity(
    String pin,
    String displayName,
    String avatar,
  ) async => IdentityView.fromJson(
    _map(
      await _vaultCall('rememberIdentity', {
        'pin': pin,
        'displayName': displayName,
        'avatar': avatar,
      }),
    ),
  );

  @override
  Future<IdentityView> unlockIdentity(String identityId, String pin) async =>
      IdentityView.fromJson(
        _map(
          await _vaultCall('unlockIdentity', {
            'identityId': identityId,
            'pin': pin,
          }),
        ),
      );

  @override
  Future<void> lockIdentity() async {
    await createP2pBridge().stopListening();
    _invoke('lockIdentity');
  }

  @override
  Future<StoredProfile> loadDesktopProfile() async {
    final value = _map(_invoke('loadDesktopProfile'));
    final avatar = value['avatar'] as String?;
    return StoredProfile(
      name: value['name'] as String? ?? '',
      avatar: avatar == null || avatar.isEmpty ? null : base64Decode(avatar),
    );
  }

  @override
  Future<void> saveDesktopProfile(StoredProfile profile) async {
    _invoke('saveDesktopProfile', {
      'name': profile.name,
      'avatar': profile.avatar == null ? null : base64Encode(profile.avatar!),
      'contactAvatar': createContactAvatar(profile.avatar),
    });
  }

  Object? _invoke(String command, [Map<String, Object?> args = const {}]) {
    final request = jsonEncode({'command': command, 'args': args})
        .toNativeUtf8();
    Pointer<Utf8> response = nullptr;
    try {
      response = _call(request);
      final document = jsonDecode(response.toDartString());
      if (document is! Map<String, Object?>) {
        throw const FormatException('Native core returned an invalid response');
      }
      if (document['ok'] != true) {
        throw StateError('${document['error'] ?? 'Native core failed'}');
      }
      return document['value'];
    } finally {
      malloc.free(request);
      if (response != nullptr) _free(response);
    }
  }

  Map<String, Object?> _map(Object? value) =>
      (value! as Map).cast<String, Object?>();

  List<ContactView> _contacts(Object? value) => (value! as List<Object?>)
      .map((item) => ContactView.fromJson(_map(item)))
      .toList(growable: false);

  @override
  Future<String> version() async => _invoke('version')! as String;

  @override
  Future<ChatSnapshot> loadSnapshot() async =>
      ChatSnapshot.fromJson(_map(_invoke('snapshot')));

  @override
  Future<ChatSnapshot> deleteConversation(String conversationId) async =>
      ChatSnapshot.fromJson(
        _map(_invoke('deleteConversation', {'conversationId': conversationId})),
      );

  @override
  Future<ChatSnapshot> sendText(
    String conversationId,
    String text,
    int sentAtMilliseconds,
  ) async => ChatSnapshot.fromJson(
    _map(
      _invoke('sendText', {
        'conversationId': conversationId,
        'text': text,
        'sentAtMilliseconds': sentAtMilliseconds,
      }),
    ),
  );

  @override
  Future<bool> hasIdentity() async => _invoke('hasIdentity')! as bool;

  @override
  Future<CreatedIdentityView> createIdentity() async =>
      CreatedIdentityView.fromJson(_map(_invoke('createIdentity')));

  @override
  Future<void> discardPendingIdentity() async =>
      _invoke('discardPendingIdentity');

  @override
  Future<IdentityView> confirmRecovery(String phrase) async =>
      IdentityView.fromJson(
        _map(_invoke('confirmRecovery', {'phrase': phrase})),
      );

  @override
  Future<IdentityView> restoreIdentity(String phrase) async =>
      IdentityView.fromJson(
        _map(_invoke('restoreIdentity', {'phrase': phrase})),
      );

  @override
  Future<IdentityView> identity() async =>
      IdentityView.fromJson(_map(_invoke('identity')));

  @override
  Future<String> contactCard({
    String displayName = '',
    String avatar = '',
  }) async =>
      _invoke('contactCard', {'displayName': displayName, 'avatar': avatar})!
          as String;

  @override
  Future<List<ContactView>> contacts() async => _contacts(_invoke('contacts'));

  @override
  Future<ContactView> inspectContactCard(String cardJson) async =>
      ContactView.fromJson(
        _map(_invoke('inspectContactCard', {'cardJson': cardJson})),
      );

  @override
  Future<List<ContactView>> addContact(
    String cardJson,
    String displayName,
  ) async => _contacts(
    _invoke('addContact', {'cardJson': cardJson, 'displayName': displayName}),
  );

  @override
  Future<List<ContactView>> markContactVerified(String identityId) async =>
      _contacts(_invoke('markContactVerified', {'identityId': identityId}));

  @override
  Future<List<ContactView>> setContactAlias(
    String identityId,
    String alias,
  ) async => _contacts(
    _invoke('setContactAlias', {'identityId': identityId, 'alias': alias}),
  );

  @override
  Future<List<ContactView>> removeContact(String identityId) async =>
      _contacts(_invoke('removeContact', {'identityId': identityId}));

  @override
  Future<String> preparePeer(String cardJson, bool initiator) async =>
      _invoke('preparePeer', {'cardJson': cardJson, 'initiator': initiator})!
          as String;

  @override
  Future<String> startPeerHandshake() async =>
      _invoke('startPeerHandshake')! as String;

  @override
  Future<Map<String, Object?>> receivePeerHandshake(String frame) async =>
      _map(_invoke('receivePeerHandshake', {'frame': frame}));

  @override
  Future<String> encryptPeerMessage(
    String messageId,
    String text, {
    int? sentAtMilliseconds,
  }) async =>
      _invoke('encryptPeerMessage', {
            'messageId': messageId,
            'text': text,
            'sentAtMilliseconds': sentAtMilliseconds,
          })!
          as String;

  @override
  Future<Map<String, Object?>> decryptPeerMessage(String frame) async =>
      _map(_invoke('decryptPeerMessage', {'frame': frame}));
}
