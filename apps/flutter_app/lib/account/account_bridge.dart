import 'account_models.dart';

abstract interface class AccountBridge {
  Future<bool> hasIdentity();
  Future<CreatedIdentityView> createIdentity();
  Future<void> discardPendingIdentity();
  Future<IdentityView> confirmRecovery(String phrase);
  Future<IdentityView> restoreIdentity(String phrase);
  Future<IdentityView> identity();
  Future<String> contactCard({String displayName = '', String avatar = ''});
  Future<List<ContactView>> contacts();
  Future<ContactView> inspectContactCard(String cardJson);
  Future<List<ContactView>> addContact(String cardJson, String displayName);
  Future<List<ContactView>> markContactVerified(String identityId);
  Future<List<ContactView>> setContactAlias(String identityId, String alias);
  Future<List<ContactView>> removeContact(String identityId);
  Future<String> preparePeer(String cardJson, bool initiator);
  Future<String> startPeerHandshake();
  Future<Map<String, Object?>> receivePeerHandshake(String frame);
  Future<String> encryptPeerMessage(
    String messageId,
    String text, {
    int? sentAtMilliseconds,
  });
  Future<Map<String, Object?>> decryptPeerMessage(String frame);
}
