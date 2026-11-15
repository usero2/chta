class PeerEvent {
  const PeerEvent({
    required this.type,
    this.messageId,
    this.text,
    this.state,
    this.reason,
    this.sentAtMilliseconds,
    this.receivedAtMilliseconds,
  });

  factory PeerEvent.fromJson(Map<String, Object?> json) => PeerEvent(
    type: json['type']! as String,
    messageId: json['messageId'] as String?,
    text: json['text'] as String?,
    state: json['state'] as String?,
    reason: json['reason'] as String?,
    sentAtMilliseconds: json['sentAtMilliseconds'] as int?,
    receivedAtMilliseconds: json['receivedAtMilliseconds'] as int?,
  );

  final String type;
  final String? messageId;
  final String? text;
  final String? state;
  final String? reason;
  final int? sentAtMilliseconds;
  final int? receivedAtMilliseconds;
}

class DiscoveredNode {
  const DiscoveredNode({required this.peerId, required this.address});

  factory DiscoveredNode.fromJson(Map<String, Object?> json) => DiscoveredNode(
    peerId: json['peerId']! as String,
    address: json['address']! as String,
  );

  final String peerId;
  final String address;
}

class ListenerStatus {
  const ListenerStatus({
    required this.listening,
    required this.peerId,
    required this.addresses,
    required this.discoveredNodes,
    required this.pinRequired,
    required this.relayEnabled,
    this.gatewayPort = 0,
    this.gatewayConnected = false,
    this.error,
  });

  factory ListenerStatus.fromJson(Map<String, Object?> json) => ListenerStatus(
    listening: json['listening']! as bool,
    peerId: json['peerId']! as String,
    addresses: (json['addresses']! as List<Object?>).cast<String>(),
    discoveredNodes: (json['discoveredNodes']! as List<Object?>)
        .map(
          (value) =>
              DiscoveredNode.fromJson((value! as Map).cast<String, Object?>()),
        )
        .toList(growable: false),
    pinRequired: json['pinRequired']! as bool,
    relayEnabled: json['relayEnabled']! as bool,
    gatewayPort: json['gatewayPort'] as int? ?? 0,
    gatewayConnected: json['gatewayConnected'] as bool? ?? false,
    error: json['error'] as String?,
  );

  final bool listening;
  final String peerId;
  final List<String> addresses;
  final List<DiscoveredNode> discoveredNodes;
  final bool pinRequired;
  final bool relayEnabled;
  final int gatewayPort;
  final bool gatewayConnected;
  final String? error;
}

abstract interface class P2pBridge {
  bool get supportsListening;
  bool get supportsAutomaticContact;
  Future<ListenerStatus> startListening(
    int port,
    String pin,
    bool allowRelay,
    String contactCard,
  );
  Future<ListenerStatus> stopListening();
  Future<ListenerStatus> listenerStatus();
  Future<void> updateListenerContactCard(String contactCard);
  Future<String> createOffer(String stunUrl, String displayName);
  Future<String> acceptOffer(String signal, String stunUrl, String displayName);
  Future<void> acceptAnswer(String signal);
  Future<String> profileName();
  Future<void> setProfileName(String name);
  Future<String> createRoom(String offer);
  Future<String> loadRoomOffer(String code);
  Future<void> publishRoomAnswer(String code, String answer);
  Future<String?> loadRoomAnswer(String code);
  Future<Map<String, Object?>> status();
  Future<void> sendMessage(
    String messageId,
    String text, {
    int? sentAtMilliseconds,
  });
  Future<void> acknowledgeMessage(String messageId, int receivedAtMilliseconds);
  Future<List<PeerEvent>> drainEvents();
  Future<void> close();
  Future<void> connectContact(String identityId, String displayName);
  Future<void> sendTransportFrame(String frame);
}
