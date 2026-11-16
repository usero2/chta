// Actual native JSON gateway in an isolated child process for integration tests.
import 'package:cht/account/account_bridge.dart';
import 'package:cht/account/account_models.dart';
import 'package:cht/seed/seed_crypto_bridge.dart';

import '../groups/group_native_relay_test.dart' show NativeWorker;

class NativeAccountWorker extends NativeWorker
    implements AccountBridge, SeedCryptoBridge {
  NativeAccountWorker(super.process);
  Map<String, Object?> _map(Object? v) => Map<String, Object?>.from(v as Map);
  @override
  Future<IdentityView> identity() async =>
      IdentityView.fromJson(_map(await call('identity')));
  @override
  Future<List<ContactView>> contacts() async => (await call('contacts') as List)
      .map((v) => ContactView.fromJson(_map(v)))
      .toList();
  @override
  Future<ContactView> inspectContactCard(String cardJson) async =>
      ContactView.fromJson(
        _map(await call('inspectContactCard', {'cardJson': cardJson})),
      );
  @override
  Future<String> contactCard({
    String displayName = '',
    String avatar = '',
  }) async =>
      await call('contactCard', {'displayName': displayName, 'avatar': avatar})
          as String;
  @override
  Future<String> preparePeer(String cardJson, bool initiator) async =>
      await call('preparePeer', {'cardJson': cardJson, 'initiator': initiator})
          as String;
  @override
  Future<String> startPeerHandshake() async =>
      await call('startPeerHandshake') as String;
  @override
  Future<Map<String, Object?>> receivePeerHandshake(String frame) async =>
      _map(await call('receivePeerHandshake', {'frame': frame}));
  @override
  Future<String> encryptPeerMessage(
    String messageId,
    String text, {
    int? sentAtMilliseconds,
  }) async => await call('encryptPeerMessage', {
    'messageId': messageId,
    'text': text,
    'sentAtMilliseconds': sentAtMilliseconds,
  }) as String;
  @override
  Future<Map<String, Object?>> decryptPeerMessage(String frame) async =>
      _map(await call('decryptPeerMessage', {'frame': frame}));
  @override
  Future<String> signSeedSignal(
    String peerId,
    String messageId,
    String text,
    int now,
  ) async => await call('signSeedSignal', {
    'peerId': peerId,
    'messageId': messageId,
    'text': text,
    'now': now,
  }) as String;
  @override
  Future<String> inspectSeedSignal(
    String source,
    String expectedPeer,
    int now,
  ) async => await call('inspectSeedSignal', {
    'source': source,
    'expectedPeer': expectedPeer,
    'now': now,
  }) as String;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
