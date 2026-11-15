import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../account/desktop_identity_bridge.dart';
import '../core/core_bridge_native.dart';
import '../core/core_bridge.dart';
import '../profile/contact_avatar.dart';
import 'p2p_bridge.dart';

final P2pBridge androidP2pBridge = AndroidP2pBridge(
  account: createPlatformCoreBridge(),
);

class AndroidP2pBridge implements P2pBridge {
  AndroidP2pBridge({
    required this.account,
    this.companionUrl = const String.fromEnvironment(
      'CHT_DESKTOP_COMPANION_URL',
      defaultValue: 'ws://127.0.0.1:17357',
    ),
    this.handshakeTimeout = const Duration(seconds: 30),
  });
  final AppBridge account;
  final String companionUrl;
  final Duration handshakeTimeout;
  final events = <PeerEvent>[];
  WebSocket? socket;
  StreamSubscription<dynamic>? subscription;
  bool authenticated = false;
  String state = 'new';
  String name = '';
  int generation = 0;
  Completer<void>? pendingHandshake;

  @override
  bool get supportsListening => false;
  @override
  bool get supportsAutomaticContact => true;

  @override
  Future<void> connectContact(String identityId, String displayName) async {
    final current = ++generation;
    await _closeTransport();
    if (current != generation) {
      throw StateError('Connection attempt was cancelled');
    }
    events.clear();
    try {
      await _connectContact(identityId, displayName, current);
    } catch (_) {
      if (current == generation) {
        final failedGeneration = ++generation;
        await _closeTransport();
        if (failedGeneration == generation) state = 'failed';
      }
      rethrow;
    }
  }

  Future<void> _connectContact(
    String identityId,
    String displayName,
    int current,
  ) async {
    state = 'connecting';
    final ready = Completer<void>();
    final connection = await WebSocket.connect(companionUrl)
        .timeout(const Duration(seconds: 3));
    if (current != generation) {
      await connection.close();
      throw StateError('Connection attempt was cancelled');
    }
    socket = connection;
    pendingHandshake = ready;
    Future<void> frames = Future.value();
    subscription = connection.listen(
      (data) {
        frames = frames
            .then((_) async {
              if (generation != current) return;
              final frame = jsonDecode(data as String) as Map<String, dynamic>;
              switch (frame['type']) {
                case 'desktopHello':
                  final card = frame['contactCard'] as String;
                  final inspected = await account.inspectContactCard(card);
                  if (generation != current) return;
                  if (inspected.identityId != identityId) {
                    throw StateError(
                      'The Desktop node is not the selected friend',
                    );
                  }
                  await account.preparePeer(card, true);
                  final profile = await (account as DesktopIdentityBridge)
                      .loadDesktopProfile();
                  if (generation != current) return;
                  final ownCard = await account.contactCard(
                    displayName: displayName,
                    avatar: createContactAvatar(profile.avatar),
                  );
                  await sendTransportFrame(
                    jsonEncode({
                      'type': 'browserHello',
                      'targetIdentityId': identityId,
                      'contactCard': ownCard,
                    }),
                  );
                  await sendTransportFrame(
                    jsonEncode({
                      'type': 'noise',
                      'payload': await account.startPeerHandshake(),
                    }),
                  );
                case 'noise':
                  final result = await account.receivePeerHandshake(
                    frame['payload'] as String,
                  );
                  if (generation != current) return;
                  if (result['reply'] is String) {
                    await sendTransportFrame(
                      jsonEncode({'type': 'noise', 'payload': result['reply']}),
                    );
                  }
                  if (result['established'] == true) {
                    authenticated = true;
                    state = 'connected';
                    events.add(const PeerEvent(type: 'authenticated'));
                    if (!ready.isCompleted) ready.complete();
                  }
                case 'ciphertext':
                  final decoded = await account.decryptPeerMessage(
                    frame['payload'] as String,
                  );
                  events.add(
                    PeerEvent(
                      type: 'message',
                      messageId: decoded['messageId'] as String,
                      text: decoded['text'] as String,
                      sentAtMilliseconds: decoded['sentAtMilliseconds'] as int?,
                      receivedAtMilliseconds:
                          DateTime.now().millisecondsSinceEpoch,
                    ),
                  );
                case 'ack':
                  events.add(
                    PeerEvent(
                      type: 'delivered',
                      messageId: frame['messageId'] as String,
                      receivedAtMilliseconds:
                          frame['receivedAtMilliseconds'] is int
                          ? frame['receivedAtMilliseconds'] as int
                          : null,
                    ),
                  );
              }
            })
            .catchError((Object error) {
              if (generation != current) return;
              authenticated = false;
              state = 'failed';
              events.add(PeerEvent(type: 'failed', reason: '$error'));
              if (!ready.isCompleted) ready.completeError(error);
            });
      },
      onError: (Object error) {
        if (generation != current) return;
        authenticated = false;
        state = 'failed';
        events.add(PeerEvent(type: 'failed', reason: '$error'));
        if (!ready.isCompleted) ready.completeError(error);
      },
      onDone: () {
        if (generation != current) return;
        authenticated = false;
        state = 'closed';
        events.add(const PeerEvent(type: 'connection', state: 'closed'));
        if (!ready.isCompleted) {
          ready.completeError(StateError('Desktop connection closed'));
        }
      },
    );
    await ready.future.timeout(handshakeTimeout);
  }

  @override
  Future<Map<String, Object?>> status() async => {
    'connectionState': state,
    'authenticated': authenticated,
  };
  @override
  Future<List<PeerEvent>> drainEvents() async {
    final result = List<PeerEvent>.of(events);
    events.clear();
    return result;
  }

  @override
  Future<void> sendTransportFrame(String frame) async {
    if (socket?.readyState != WebSocket.open) {
      throw StateError('Desktop connection is not open');
    }
    socket!.add(frame);
  }

  @override
  Future<void> sendMessage(
    String messageId,
    String text, {
    int? sentAtMilliseconds,
  }) async {
    if (!authenticated) throw StateError('The connection is not authenticated');
    final payload = await account.encryptPeerMessage(
      messageId,
      text,
      sentAtMilliseconds:
          sentAtMilliseconds ?? DateTime.now().millisecondsSinceEpoch,
    );
    await sendTransportFrame(
      jsonEncode({'type': 'ciphertext', 'payload': payload}),
    );
    events.add(PeerEvent(type: 'sent', messageId: messageId));
  }

  @override
  Future<void> acknowledgeMessage(
    String messageId,
    int receivedAtMilliseconds,
  ) => sendTransportFrame(
    jsonEncode({
      'type': 'ack',
      'messageId': messageId,
      'receivedAtMilliseconds': receivedAtMilliseconds,
    }),
  );
  @override
  Future<void> close() async {
    final current = ++generation;
    await _closeTransport();
    if (current == generation) events.clear();
  }

  Future<void> _closeTransport() async {
    final closingSubscription = subscription;
    final closingSocket = socket;
    final closingHandshake = pendingHandshake;
    pendingHandshake = null;
    subscription = null;
    socket = null;
    authenticated = false;
    state = 'closed';
    if (closingHandshake != null && !closingHandshake.isCompleted) {
      closingHandshake.completeError(
        StateError('Connection attempt was cancelled'),
      );
    }
    await closingSubscription?.cancel();
    try {
      await closingSocket?.close().timeout(const Duration(seconds: 2));
    } catch (_) {
      // A disconnected USB tunnel may never complete its closing handshake.
    }
  }

  Future<T> _unsupported<T>() => Future.error(
    UnsupportedError(
      'Choose a verified friend in Contacts. For USB, connect to Desktop.',
    ),
  );
  static const offline = ListenerStatus(
    listening: false,
    peerId: '',
    addresses: [],
    discoveredNodes: [],
    pinRequired: false,
    relayEnabled: false,
  );
  @override
  Future<ListenerStatus> startListening(
    int port,
    String pin,
    bool allowRelay,
    String contactCard,
  ) => _unsupported();
  @override
  Future<ListenerStatus> stopListening() async {
    await close();
    return offline;
  }

  @override
  Future<ListenerStatus> listenerStatus() async => offline;
  @override
  Future<void> updateListenerContactCard(String contactCard) async {}
  @override
  Future<String> profileName() async => name;
  @override
  Future<void> setProfileName(String value) async {
    name = value.trim();
  }

  @override
  Future<String> createOffer(String stunUrl, String displayName) =>
      _unsupported();
  @override
  Future<String> acceptOffer(
    String signal,
    String stunUrl,
    String displayName,
  ) => _unsupported();
  @override
  Future<void> acceptAnswer(String signal) => _unsupported();
  @override
  Future<String> createRoom(String offer) => _unsupported();
  @override
  Future<String> loadRoomOffer(String code) => _unsupported();
  @override
  Future<void> publishRoomAnswer(String code, String answer) => _unsupported();
  @override
  Future<String?> loadRoomAnswer(String code) => _unsupported();
}
