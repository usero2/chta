import 'dart:convert';
import 'dart:js_interop';

import 'p2p_bridge.dart';

@JS('chtCore.createPeerOffer')
external JSPromise<JSString> _createOffer(
  JSString stunUrl,
  JSString displayName,
);
@JS('chtCore.acceptPeerOffer')
external JSPromise<JSString> _acceptOffer(
  JSString signal,
  JSString stunUrl,
  JSString displayName,
);
@JS('chtCore.acceptPeerAnswer')
external JSPromise<JSAny?> _acceptAnswer(JSString signal);
@JS('chtCore.createPeerRoom')
external JSPromise<JSString> _createRoom(JSString offer);
@JS('chtCore.loadPeerRoomOffer')
external JSPromise<JSString> _loadRoomOffer(JSString code);
@JS('chtCore.publishPeerRoomAnswer')
external JSPromise<JSAny?> _publishRoomAnswer(JSString code, JSString answer);
@JS('chtCore.loadPeerRoomAnswer')
external JSPromise<JSString> _loadRoomAnswer(JSString code);
@JS('chtCore.profileName')
external JSPromise<JSString> _profileName();
@JS('chtCore.setProfileName')
external JSPromise<JSAny?> _setProfileName(JSString name);
@JS('chtCore.peerStatus')
external JSPromise<JSString> _status();
@JS('chtCore.sendPeerMessage')
external JSPromise<JSAny?> _sendMessage(
  JSString messageId,
  JSString text,
  JSNumber? sentAtMilliseconds,
);
@JS('chtCore.acknowledgePeerMessage')
external JSPromise<JSAny?> _acknowledgeMessage(
  JSString messageId,
  JSNumber receivedAtMilliseconds,
);
@JS('chtCore.drainPeerEvents')
external JSPromise<JSString> _drainEvents();
@JS('chtCore.closePeer')
external JSPromise<JSAny?> _close();
@JS('chtCore.connectLocalDesktop')
external JSPromise<JSAny?> _connectLocalDesktop(
  JSString identityId,
  JSString displayName,
);

P2pBridge createPlatformP2pBridge() => const _WebP2pBridge();

class _WebP2pBridge implements P2pBridge {
  const _WebP2pBridge();

  @override
  bool get supportsListening => false;

  @override
  bool get supportsAutomaticContact => true;

  @override
  Future<void> updateListenerContactCard(String contactCard) => Future.error(
    UnsupportedError('Public listening is available in the Desktop app'),
  );

  @override
  Future<ListenerStatus> startListening(
    int port,
    String pin,
    bool allowRelay,
    String contactCard,
  ) => Future.error(
    UnsupportedError('Public listening is available in the Desktop app'),
  );

  @override
  Future<ListenerStatus> stopListening() => Future.error(
    UnsupportedError('Public listening is available in the Desktop app'),
  );

  @override
  Future<ListenerStatus> listenerStatus() => Future.error(
    UnsupportedError('Public listening is available in the Desktop app'),
  );

  @override
  Future<String> createOffer(String stunUrl, String displayName) async =>
      (await _createOffer(stunUrl.toJS, displayName.toJS).toDart).toDart;

  @override
  Future<String> profileName() async => (await _profileName().toDart).toDart;

  @override
  Future<void> setProfileName(String name) async {
    await _setProfileName(name.toJS).toDart;
  }

  @override
  Future<String> acceptOffer(
    String signal,
    String stunUrl,
    String displayName,
  ) async => (await _acceptOffer(
    signal.toJS,
    stunUrl.toJS,
    displayName.toJS,
  ).toDart).toDart;

  @override
  Future<void> acceptAnswer(String signal) async {
    await _acceptAnswer(signal.toJS).toDart;
  }

  @override
  Future<String> createRoom(String offer) async =>
      (await _createRoom(offer.toJS).toDart).toDart;

  @override
  Future<String> loadRoomOffer(String code) async =>
      (await _loadRoomOffer(code.toJS).toDart).toDart;

  @override
  Future<void> publishRoomAnswer(String code, String answer) async {
    await _publishRoomAnswer(code.toJS, answer.toJS).toDart;
  }

  @override
  Future<String?> loadRoomAnswer(String code) async {
    final value = (await _loadRoomAnswer(code.toJS).toDart).toDart;
    return value.isEmpty ? null : value;
  }

  @override
  Future<Map<String, Object?>> status() async =>
      (jsonDecode((await _status().toDart).toDart) as Map)
          .cast<String, Object?>();

  @override
  Future<void> sendMessage(
    String messageId,
    String text, {
    int? sentAtMilliseconds,
  }) async {
    await _sendMessage(
      messageId.toJS,
      text.toJS,
      sentAtMilliseconds?.toJS,
    ).toDart;
  }

  @override
  Future<void> acknowledgeMessage(
    String messageId,
    int receivedAtMilliseconds,
  ) async {
    await _acknowledgeMessage(
      messageId.toJS,
      receivedAtMilliseconds.toJS,
    ).toDart;
  }

  @override
  Future<List<PeerEvent>> drainEvents() async {
    final values = jsonDecode((await _drainEvents().toDart).toDart) as List;
    return values
        .map(
          (value) => PeerEvent.fromJson((value as Map).cast<String, Object?>()),
        )
        .toList(growable: false);
  }

  @override
  Future<void> close() async {
    await _close().toDart;
  }

  @override
  Future<void> connectContact(String identityId, String displayName) async {
    await _connectLocalDesktop(identityId.toJS, displayName.toJS).toDart;
  }

  @override
  Future<void> sendTransportFrame(String frame) => Future.error(
    UnsupportedError('Raw transport frames are managed by the Web runtime'),
  );
}
