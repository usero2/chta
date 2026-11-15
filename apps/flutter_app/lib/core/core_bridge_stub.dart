import 'core_bridge.dart';

import '../account/account_models.dart';
import '../chat/chat_models.dart';

AppBridge createPlatformCoreBridge() => const _UnsupportedCoreBridge();

class _UnsupportedCoreBridge implements AppBridge {
  const _UnsupportedCoreBridge();

  @override
  Future<String> version() => Future.error(
    UnsupportedError('Rust core bridge is only available on Web'),
  );

  @override
  Future<ChatSnapshot> loadSnapshot() => Future.error(
    UnsupportedError('Rust core bridge is only available on Web'),
  );

  @override
  Future<ChatSnapshot> sendText(
    String conversationId,
    String text,
    int sentAtMilliseconds,
  ) => Future.error(
    UnsupportedError('Rust core bridge is only available on Web'),
  );

  Future<T> _unsupported<T>() =>
      Future.error(UnsupportedError('Account bridge is only available on Web'));

  @override
  Future<List<ContactView>> addContact(String cardJson, String displayName) =>
      _unsupported();
  @override
  Future<IdentityView> confirmRecovery(String phrase) => _unsupported();
  @override
  Future<String> contactCard({String displayName = '', String avatar = ''}) =>
      _unsupported();
  @override
  Future<List<ContactView>> contacts() => _unsupported();
  @override
  Future<CreatedIdentityView> createIdentity() => _unsupported();
  @override
  Future<void> discardPendingIdentity() => _unsupported();
  @override
  Future<bool> hasIdentity() => _unsupported();
  @override
  Future<IdentityView> identity() => _unsupported();
  @override
  Future<ContactView> inspectContactCard(String cardJson) => _unsupported();
  @override
  Future<List<ContactView>> markContactVerified(String identityId) =>
      _unsupported();
  @override
  Future<List<ContactView>> setContactAlias(String identityId, String alias) =>
      _unsupported();
  @override
  Future<List<ContactView>> removeContact(String identityId) => _unsupported();
  @override
  Future<IdentityView> restoreIdentity(String phrase) => _unsupported();
  @override
  Future<String> preparePeer(String cardJson, bool initiator) => _unsupported();
  @override
  Future<String> startPeerHandshake() => _unsupported();
  @override
  Future<Map<String, Object?>> receivePeerHandshake(String frame) =>
      _unsupported();
  @override
  Future<String> encryptPeerMessage(
    String messageId,
    String text, {
    int? sentAtMilliseconds,
  }) => _unsupported();
  @override
  Future<Map<String, Object?>> decryptPeerMessage(String frame) =>
      _unsupported();
}
