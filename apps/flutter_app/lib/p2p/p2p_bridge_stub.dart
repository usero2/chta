import 'p2p_bridge.dart';

P2pBridge createPlatformP2pBridge() => const _UnsupportedP2pBridge();

class _UnsupportedP2pBridge implements P2pBridge {
  const _UnsupportedP2pBridge();
  Future<T> _unsupported<T>() =>
      Future.error(UnsupportedError('WebRTC is available on Web only'));
  @override
  bool get supportsListening => false;
  @override
  bool get supportsAutomaticContact => false;
  @override
  Future<ListenerStatus> startListening(
    int port,
    String pin,
    bool allowRelay,
    String contactCard,
  ) => _unsupported();
  @override
  Future<ListenerStatus> stopListening() => _unsupported();
  @override
  Future<ListenerStatus> listenerStatus() => _unsupported();

  @override
  Future<void> updateListenerContactCard(String contactCard) => _unsupported();

  @override
  Future<void> acceptAnswer(String signal) => _unsupported();
  @override
  Future<String> acceptOffer(
    String signal,
    String stunUrl,
    String displayName,
  ) => _unsupported();
  @override
  Future<void> close() async {}
  @override
  Future<void> connectContact(String identityId, String displayName) =>
      _unsupported();
  @override
  Future<void> sendTransportFrame(String frame) => _unsupported();
  @override
  Future<String> createOffer(String stunUrl, String displayName) =>
      _unsupported();
  @override
  Future<String> createRoom(String offer) => _unsupported();
  @override
  Future<List<PeerEvent>> drainEvents() => _unsupported();
  @override
  Future<String?> loadRoomAnswer(String code) => _unsupported();
  @override
  Future<String> loadRoomOffer(String code) => _unsupported();
  @override
  Future<void> publishRoomAnswer(String code, String answer) => _unsupported();
  @override
  Future<String> profileName() => _unsupported();
  @override
  Future<void> setProfileName(String name) => _unsupported();
  @override
  Future<void> sendMessage(
    String messageId,
    String text, {
    int? sentAtMilliseconds,
  }) => _unsupported();
  @override
  Future<void> acknowledgeMessage(
    String messageId,
    int receivedAtMilliseconds,
  ) => _unsupported();
  @override
  Future<Map<String, Object?>> status() => _unsupported();
}
