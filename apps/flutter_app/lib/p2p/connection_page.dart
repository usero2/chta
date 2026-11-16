import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

import '../account/account_bridge.dart';
import '../account/account_models.dart';
import '../account/routed_contact_bridge.dart';
import '../account/contact_qr_files.dart';
import '../qr/qr_scanner_page.dart';
import '../chat/chat_controller.dart';
import '../chat/chat_models.dart';
import '../chat/widgets/conversation_list.dart';
import '../chat/widgets/contact_details_sheet.dart';
import '../chat/peer_history.dart';
import '../chat/chat_attachment.dart';
import '../chat/attachment_files.dart';
import '../chat/attachment_export.dart';
import '../chat/attachment_transfer.dart';
import '../chat/chunked_attachment_bridge.dart';
import '../chat/resumable_attachment_transfer.dart';
import '../chat/widgets/file_transfer_status.dart';
import '../chat/media_batch.dart';
import '../chat/media_item.dart';
import '../chat/media_thumbnail.dart';
import '../chat/widgets/media_album.dart';
import '../chat/widgets/message_bubble.dart';
import '../chat/widgets/message_composer.dart';
import '../chat/widgets/attachment_content.dart';
import '../profile/profile_controller.dart';
import '../profile/profile_avatar.dart';
import 'p2p_bridge.dart';
import 'p2p_bridge_factory.dart';
import 'direct_file_link.dart';
import 'peer_file_controller.dart';
import '../relay/relay_crypto_bridge.dart';
import '../relay/relay_network.dart';
import '../relay/relay_chat.dart';
import '../relay/relay_host.dart';
import '../relay/relay_qr.dart';
import '../relay/relay_peer_sync.dart';
import '../seed/seed_client.dart';
import '../seed/seed_crypto_bridge.dart';

const defaultStunUrl = String.fromEnvironment(
  'CHT_STUN_URL',
  defaultValue: 'stun:stun.l.google.com:19302',
);

enum ConnectionFlow { choose, invite, join }

class ConnectionPage extends StatefulWidget {
  const ConnectionPage({
    required this.accountBridge,
    this.bridge,
    this.stunUrl = defaultStunUrl,
    this.targetContactId,
    this.chatMode = false,
    this.showChatSidebar = true,
    this.onPeerAuthenticated,
    this.onConnectRequested,
    this.onChatSelected,
    this.profileController,
    this.chatController,
    this.peerHistory,
    this.onRoomSelected,
    this.onBackToChats,
    this.onCreateGroup,
    this.onConversationAction,
    this.onOnlinePeersChanged,
    this.extraConversations = const [],
    this.autoStartListener = true,
    this.relayHostFactory = createRelayHost,
    this.onRelayNetworkReady,
    this.scanRelayQr,
    this.readRelayQrImage,
    this.relayConnector,
    this.pickAttachments,
    this.directPeerFactory,
    super.key,
  });

  final AccountBridge accountBridge;
  final P2pBridge? bridge;
  final String stunUrl;
  final String? targetContactId;
  final bool chatMode;
  final bool showChatSidebar;
  final ValueChanged<ContactView>? onPeerAuthenticated;
  final ValueChanged<ContactView>? onConnectRequested;
  final ValueChanged<ContactView>? onChatSelected;
  final ProfileController? profileController;
  final ChatController? chatController;
  final PeerHistory? peerHistory;
  final ValueChanged<String>? onRoomSelected;
  final VoidCallback? onBackToChats;
  final VoidCallback? onCreateGroup;
  final ConversationActionCallback? onConversationAction;
  final ValueChanged<Set<String>>? onOnlinePeersChanged;
  final List<ConversationView> extraConversations;
  final bool autoStartListener;
  final RelayHost? Function() relayHostFactory;
  final ValueChanged<RelayNetwork>? onRelayNetworkReady;
  final Future<String?> Function()? scanRelayQr;
  final Future<String?> Function()? readRelayQrImage;
  final RelayConnector? relayConnector;
  final Future<List<ChatAttachment>> Function(AttachmentPickKind)?
  pickAttachments;
  final DirectPeerFactory? directPeerFactory;

  @override
  State<ConnectionPage> createState() => ConnectionPageState();
}

class ConnectionPageState extends State<ConnectionPage> {
  void cancelConversationWork(String id) {
    fileController?.cancelPendingFor(id);
    relayChat?.cancelPendingFor(id);
    if (_selectedFileContact?.identityId == id) {
      attachments.reset();
      transferProgress.clear();
      incomingProgress.clear();
    }
  }

  late final P2pBridge bridge;
  late final TextEditingController stun;
  final profileNameController = TextEditingController();
  final roomCodeInput = TextEditingController();
  final messageInput = TextEditingController();
  final listenerPort = TextEditingController(text: '0');
  final listenerPin = TextEditingController();
  late final PeerHistory history;
  late final AttachmentTransfer attachments;
  PeerFileController? fileController;
  final transferProgress = <String, double>{};
  final incomingProgress = <String, double>{};
  bool? attachmentUsesRelay;
  (String, int)? _attachmentScope;
  bool _sendingBatch = false;
  String? _draftText, _draftPeer;
  List<ChatAttachment> _draftFiles = [];
  List<PeerMessage> _draftMessages = [];
  PreparedMediaBatch? _draftBatch;
  int peerGeneration = 0;
  Set<String> _reportedOnlinePeers = const {};
  void _reportOnlinePeers() {
    if (!mounted) return;
    final online = <String>{
      if (authenticated && peerIdentityId != null) peerIdentityId!,
      if (fileController?.ready == true && fileController?.peerId != null)
        fileController!.peerId!,
    };
    if (setEquals(online, _reportedOnlinePeers)) return;
    _reportedOnlinePeers = online;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && setEquals(online, _reportedOnlinePeers)) {
        widget.onOnlinePeersChanged?.call(Set.unmodifiable(online));
      }
    });
  }

  List<PeerMessage> get messages =>
      history.messagesFor(widget.targetContactId ?? peerIdentityId);
  Timer? timer;
  Timer? answerTimer;
  String connectionState = 'new';
  bool authenticated = false;
  int messageCounter = 0;
  ConnectionFlow flow = ConnectionFlow.choose;
  bool working = false;
  bool replyCreated = false;
  bool checkingAnswer = false;
  String? roomCode;
  String? pendingAnswer;
  String? peerName;
  String? peerIdentityId;
  ContactView? targetContact;
  ContactView? peerContact;
  List<ContactView> contacts = const [];
  bool peerRouteReported = false;
  bool showConnectionModal = false;
  bool useListenerPin = false;
  bool allowRelay = true;
  ListenerStatus? nativeListener;
  String? error;
  Object? technicalError;
  bool polling = false;
  bool automaticConnectionAttempted = false;
  String? connectionAttemptPeerId;
  (String, String)? advertisedProfile;
  RelayNetwork? relayNetwork;
  RelayChat? relayChat;
  RelayPeerSync? relaySync;
  SeedClient? seedClient;
  StreamSubscription<SeedVerifiedSignal>? _seedSignals;
  int _controlSession = 0;
  bool _controlWasAuthenticated = false;
  bool get usingRelayChat => relayChat?.selected == true;
  final relayAddress = TextEditingController();
  final relayConnectionLimit = TextEditingController(text: '50');
  int relayRowsShown = 20;
  String? relayError;
  RelayHost? relayHost;
  String? publishedRelayEndpoint;
  bool initializingRelays = false;
  bool readingRelayQr = false;
  bool get canScanRelayQr => supportsQrCamera || widget.scanRelayQr != null;

  String? get shareableRelay {
    if (relayHost?.running == true) return relayHost?.endpoint;
    return relayNetwork?.online
        .where(
          (url) =>
              url.startsWith('wss://') &&
              !['localhost', '127.0.0.1', '::1'].contains(Uri.parse(url).host),
        )
        .firstOrNull;
  }

  @override
  void initState() {
    super.initState();
    bridge = widget.bridge ?? createP2pBridge();
    initializingRelays = widget.accountBridge is RelayCryptoBridge;
    history = widget.peerHistory ?? PeerHistory();
    unawaited(_initializeFileController());
    attachments = AttachmentTransfer(
      maxTransferBytes: () => usingRelayChat
          ? ChatAttachment.relayMaxBytes
          : ChatAttachment.maxBytes,
      sendPacket: _sendLegacyPacket,
      onReceived: (id, attachment, sentAt, receivedAt) async {
        final peer = peerIdentityId ?? widget.targetContactId;
        if (peer == null) throw StateError('Missing attachment peer');
        await history.addAttachment(
          peer,
          PeerMessage(
            id: id,
            text: attachment.previewLabel,
            attachment: attachment,
            incoming: true,
            status: DeliveryStatus.delivered,
            sentAtMilliseconds: sentAt,
            receivedAtMilliseconds: receivedAt,
          ),
        );
        incomingProgress.remove(id);
      },
      onProgress: (id, progress, incoming) {
        if (mounted) {
          setState(
            () =>
                (incoming ? incomingProgress : transferProgress)[id] = progress,
          );
        }
      },
    );
    history.addListener(_historyChanged);
    widget.chatController?.addListener(_historyChanged);
    stun = TextEditingController(text: widget.stunUrl);
    unawaited(_initializeNode());
    _loadTargetContact();
    unawaited(_poll());
    timer = Timer.periodic(const Duration(milliseconds: 400), (_) => _poll());
  }

  Future<void> _initializeFileController() async {
    final cache = createChunkedAttachmentBridge(bridge: widget.accountBridge);
    if (cache == null) return;
    try {
      final owner = (await widget.accountBridge.identity()).id;
      if (!mounted || owner.isEmpty) return;
      final controller = PeerFileController(
        ownerId: owner,
        cache: cache,
        history: history,
        sendEncryptedControl: _sendEncryptedControl,
        sendSeedControl: (id, text) async {
          final seed = seedClient;
          if (seed == null) throw const TransferInterrupted();
          await seed.sendSignal(id, text);
        },
        sendFallbackPacket: _sendBoundFallback,
        onPacket: _onDirectPacket,
        onReceipt: _onDirectReceipt,
        onChanged: _historyChanged,
        peerFactory: widget.directPeerFactory,
      );
      fileController = controller;
      await _updateFilePeer(authenticated);
    } catch (_) {
      // An unavailable chunk cache leaves the existing chat path usable.
    }
  }

  ContactView? get _selectedFileContact {
    final selected = widget.targetContactId ?? peerIdentityId;
    if (selected == null) return null;
    return contacts
            .where((c) => c.identityId == selected && c.verified)
            .firstOrNull ??
        (targetContact?.identityId == selected &&
                targetContact?.verified == true
            ? targetContact
            : null);
  }

  Future<void> _updateFilePeer(bool secured) async {
    final contact = _selectedFileContact;
    seedClient?.selectContact(contact);
    final actualPeer = peerIdentityId;
    final selected = widget.targetContactId ?? actualPeer;
    await fileController?.updatePeer(
      contact,
      encryptedAuthenticated: secured && actualPeer == selected,
      seedSignalingAvailable: seedClient?.registered == true,
    );
  }

  Future<void> _sendEncryptedControl(String id, String text) async {
    final peer = peerIdentityId;
    final generation = peerGeneration;
    final session = _controlSession;
    final relay = usingRelayChat;
    void guard() {
      if (!mounted ||
          !authenticated ||
          peer == null ||
          peerIdentityId != peer ||
          generation != peerGeneration ||
          session != _controlSession ||
          relay != usingRelayChat) {
        throw StateError('Control session changed');
      }
    }

    guard();
    if (relay) {
      await relayChat!.sendControl(id, text);
    } else if (bridge.supportsListening) {
      final payload = await widget.accountBridge.encryptPeerMessage(id, text);
      guard();
      await bridge.sendTransportFrame(
        jsonEncode({'type': 'ciphertext', 'payload': payload}),
      );
    } else {
      guard();
      await bridge.sendMessage(id, text);
    }
  }

  Future<void> _onDirectPacket(String id, String text, int? sentAt) async {
    final generation = peerGeneration;
    final expectedPeer = fileController?.peerId;
    if (fileController?.peerId != (widget.targetContactId ?? peerIdentityId)) {
      return;
    }
    if (id.startsWith(DirectFileLink.controlPrefix)) return;
    if (RelayPeerSync.isControlId(id)) {
      await relaySync?.receive(id, text);
      return;
    }
    final received = DateTime.now().millisecondsSinceEpoch;
    if (AttachmentTransfer.isPacketId(id)) {
      await _receiveAttachment(id, text, sentAt, received);
    } else {
      final peer = fileController?.peerId;
      if (peer == null) return;
      final old = history
          .messagesFor(peer)
          .where((m) => m.id == id)
          .firstOrNull;
      final time = old?.receivedAtMilliseconds ?? received;
      if (old == null) {
        history.add(
          peer,
          PeerMessage(
            id: id,
            text: text,
            incoming: true,
            status: DeliveryStatus.delivered,
            sentAtMilliseconds: sentAt,
            receivedAtMilliseconds: time,
          ),
        );
      }
      await history.flush();
      if (history.error != null) {
        throw StateError('Could not save incoming message');
      }
      if (generation != peerGeneration ||
          expectedPeer != fileController?.peerId) {
        return;
      }
      await fileController?.acknowledge(id, time);
      return;
    }
    if (generation == peerGeneration &&
        expectedPeer == fileController?.peerId) {
      await fileController?.acknowledge(id, received);
    }
  }

  void _onDirectReceipt(String id, int receivedAt) {
    if (fileController?.peerId != (widget.targetContactId ?? peerIdentityId)) {
      return;
    }
    if (ResumableAttachmentTransfer.isPacketId(id)) return;
    if (attachments.acknowledge(id, receivedAtMilliseconds: receivedAt)) return;
    final peer = fileController?.peerId;
    if (peer != null) {
      history.setStatus(
        peer,
        id,
        DeliveryStatus.delivered,
        receivedAtMilliseconds: receivedAt,
      );
    }
  }

  Future<void> _initializeNode() async {
    await _loadProfileName();
    unawaited(_initializeRelays());
    if (!mounted || !bridge.supportsListening || !widget.autoStartListener) {
      return;
    }
    try {
      final current = await bridge.listenerStatus();
      if (!mounted) return;
      if (current.listening) {
        setState(() => nativeListener = current);
        return;
      }
      await _startNativeListener();
    } catch (caught) {
      if (mounted) {
        setState(() {
          error = 'Could not start listening. Try again.';
          technicalError = caught;
        });
      }
    }
  }

  Future<void> _initializeRelays() async {
    final account = widget.accountBridge;
    if (account is! RelayCryptoBridge || !mounted) return;
    final network = RelayNetwork(
      account as RelayCryptoBridge,
      connector: widget.relayConnector,
    );
    relayNetwork = network;
    relayHost = widget.relayHostFactory();
    relayHost?.addListener(_hostChanged);
    relayChat = RelayChat(
      account,
      network,
      ownCard: _ownContactCard,
      onFriendRequest: _friendRequest,
      canAcceptPeer: () => !authenticated || usingRelayChat,
    );
    relaySync = RelayPeerSync(network, send: _sendEncryptedControl);
    network.addListener(_historyChanged);
    try {
      await network.initialize();
      if (mounted && account is SeedCryptoBridge) {
        final seed = SeedClient(
          account: account,
          relayCrypto: account as RelayCryptoBridge,
          signalCrypto: account as SeedCryptoBridge,
          network: network,
          connector: widget.relayConnector,
          acceptIncomingPeer: _acceptIncomingSeedPeer,
        );
        seedClient = seed;
        seed.addListener(_seedChanged);
        _seedSignals = seed.signals.listen((signal) {
          final generation = peerGeneration;
          if (!mounted ||
              _selectedFileContact?.identityId != signal.peerId ||
              seed.selectedPeer != signal.peerId) {
            return;
          }
          unawaited(_receiveSeedSignal(signal, generation));
        });
        final owner = (await account.identity()).id;
        if (!mounted) {
          await seed.close();
          return;
        }
        await seed.start(owner);
        if (mounted) await _updateFilePeer(authenticated);
      }
      relayConnectionLimit.text = '${network.connectionLimit}';
      if (mounted) widget.onRelayNetworkReady?.call(network);
      if (mounted && network.hostEnabled && relayHost != null) {
        unawaited(_startPublicRelay());
      }
      if (mounted && network.enabled && !authenticated) await bridge.close();
    } catch (caught) {
      if (mounted) setState(() => relayError = '$caught');
    } finally {
      initializingRelays = false;
      if (mounted && !authenticated) await _connectAutomatically(force: true);
    }
  }

  Future<String> _ownContactCard() {
    final account = widget.accountBridge;
    final name = widget.profileController?.name ?? profileNameController.text;
    final avatar = widget.profileController?.contactAvatar ?? '';
    if (account is RoutedContactBridge) {
      return (account as RoutedContactBridge).contactCardWithRelays(
        displayName: name,
        avatar: avatar,
        relayUrls: relayNetwork?.contactRelayUrls ?? const [],
      );
    }
    return account.contactCard(displayName: name, avatar: avatar);
  }

  void _seedChanged() {
    if (!mounted) return;
    unawaited(_updateFilePeer(authenticated));
    setState(() {});
  }

  Future<bool> _acceptIncomingSeedPeer(String id) async {
    if (!mounted ||
        (widget.targetContactId != null && widget.targetContactId != id) ||
        authenticated && peerIdentityId != id ||
        fileController?.ready == true && fileController?.peerId != id) {
      return false;
    }
    final generation = peerGeneration;
    final known = await widget.accountBridge.contacts();
    final contact = known
        .where((c) => c.identityId == id && c.verified)
        .firstOrNull;
    if (!mounted ||
        contact == null ||
        generation != peerGeneration ||
        (widget.targetContactId != null && widget.targetContactId != id)) {
      return false;
    }
    if (peerIdentityId != id) {
      peerGeneration++;
      attachments.reset();
      transferProgress.clear();
      incomingProgress.clear();
      peerIdentityId = id;
      peerContact = contact;
      peerName = contact.displayName;
    }
    contacts = known;
    history.rememberContacts(known);
    await _updateFilePeer(authenticated);
    if (mounted) setState(() {});
    return mounted &&
        fileController?.peerId == id &&
        seedClient?.selectedPeer == id;
  }

  Future<void> _receiveSeedSignal(
    SeedVerifiedSignal signal,
    int generation,
  ) async {
    if (!mounted ||
        generation != peerGeneration ||
        _selectedFileContact?.identityId != signal.peerId) {
      return;
    }
    await fileController?.receiveSeedControl(
      signal.messageId,
      signal.text,
      peer: signal.peerId,
    );
    if (mounted && generation == peerGeneration) setState(() {});
  }

  bool reviewingFriend = false;

  void _friendRequest(String card, ContactView contact) {
    if (!mounted || reviewingFriend) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 30),
        content: Text('${contact.displayName} wants to chat'),
        action: SnackBarAction(
          label: 'Review',
          onPressed: () async {
            if (!mounted || reviewingFriend) return;
            reviewingFriend = true;
            try {
              final existing = (await widget.accountBridge.contacts())
                  .where((c) => c.identityId == contact.identityId)
                  .firstOrNull;
              if (!mounted) return;
              final name = await _confirmFingerprint(contact, existing);
              if (name == null || !mounted) return;
              if (existing == null) {
                await widget.accountBridge.addContact(card, name);
              }
              await widget.accountBridge.markContactVerified(
                contact.identityId,
              );
              final saved = (await widget.accountBridge.contacts()).firstWhere(
                (c) => c.identityId == contact.identityId,
              );
              if (!mounted) return;
              await relayNetwork?.addContactRoutes(contact.relayUrls);
              if (mounted) widget.onChatSelected?.call(saved);
            } catch (_) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Could not add friend. Try again.'),
                  ),
                );
              }
            } finally {
              reviewingFriend = false;
            }
          },
        ),
      ),
    );
  }

  void _hostChanged() {
    if (!mounted) return;
    final endpoint = relayHost?.endpoint;
    if (endpoint != null && endpoint != publishedRelayEndpoint) {
      final previous = publishedRelayEndpoint;
      publishedRelayEndpoint = endpoint;
      unawaited(relayNetwork!.addHostedEndpoint(previous, endpoint));
    }
    setState(() {});
  }

  Future<void> _startPublicRelay() async {
    await relayNetwork!.setHostEnabled(true);
    if (!mounted) return;
    final endpoints = <String>{
      ...relayNetwork!.seeds,
      ...relayNetwork!.records.values.map((r) => r['endpoint'] as String),
    };
    await relayHost!.start(
      endpoints.where((url) => url != publishedRelayEndpoint).toList(),
    );
  }

  Future<void> _stopPublicRelay() async {
    await relayNetwork!.setHostEnabled(false);
    await relayHost!.stop();
    final previous = publishedRelayEndpoint ?? relayNetwork!.hostedEndpoint;
    publishedRelayEndpoint = null;
    if (previous != null) await relayNetwork!.forget(previous);
    if (mounted) setState(() {});
  }

  void _historyChanged() {
    if (mounted) setState(() {});
    _reportOnlinePeers();
  }

  @override
  void didUpdateWidget(covariant ConnectionPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.targetContactId != widget.targetContactId) {
      peerGeneration++;
      attachments.reset();
      transferProgress.clear();
      incomingProgress.clear();
      messageInput.clear();
      automaticConnectionAttempted = false;
      seedClient?.selectContact(null);
      _loadTargetContact();
      unawaited(
        fileController?.updatePeer(null, encryptedAuthenticated: false),
      );
    }
  }

  @override
  void dispose() {
    attachments.dispose();
    unawaited(fileController?.close());
    timer?.cancel();
    answerTimer?.cancel();
    bridge.close();
    relaySync?.dispose();
    seedClient?.removeListener(_seedChanged);
    unawaited(_seedSignals?.cancel());
    unawaited(seedClient?.close());
    relayNetwork?.removeListener(_historyChanged);
    unawaited(relayChat?.close());
    relayHost?.removeListener(_hostChanged);
    unawaited(relayHost?.shutdown());
    history.removeListener(_historyChanged);
    widget.chatController?.removeListener(_historyChanged);
    if (widget.peerHistory == null) history.dispose();
    stun.dispose();
    profileNameController.dispose();
    roomCodeInput.dispose();
    messageInput.dispose();
    listenerPort.dispose();
    listenerPin.dispose();
    relayAddress.dispose();
    relayConnectionLimit.dispose();
    super.dispose();
  }

  Future<void> _poll() async {
    if (polling) return;
    polling = true;
    final generation = peerGeneration;
    final roomGeneration = history.conversationGeneration(
      peerIdentityId ?? widget.targetContactId ?? '',
    );
    try {
      final useRelay = usingRelayChat;
      if (bridge.supportsListening) {
        final listener = await bridge.listenerStatus();
        if (listener.listening) {
          final profile = (
            widget.profileController?.name ?? profileNameController.text,
            widget.profileController?.contactAvatar ?? '',
          );
          if (advertisedProfile != profile) {
            final card = await widget.accountBridge.contactCard(
              displayName: profile.$1,
              avatar: profile.$2,
            );
            await bridge.updateListenerContactCard(card);
            advertisedProfile = profile;
          }
        }
        final events = await bridge.drainEvents();
        if (!useRelay) {
          for (final event in events) {
            await _handleNativeGatewayEvent(
              event,
              expectedRoomGeneration: roomGeneration,
            );
          }
        }
        if (mounted) setState(() => nativeListener = listener);
        if (!useRelay) return;
      }
      final events = useRelay
          ? relayChat!.drainEvents()
          : await bridge.drainEvents();
      // Read the current state after draining historical events so a queued
      // close from the previous session cannot override a successful reconnect.
      final status = useRelay
          ? <String, Object?>{
              'connectionState': relayChat!.state,
              'authenticated': relayChat!.authenticated,
            }
          : await bridge.status();
      if (!mounted) return;
      if (generation != peerGeneration) return;
      final isAuthenticated = status['authenticated']! as bool;
      if (useRelay && isAuthenticated && relayChat!.peerId != peerIdentityId) {
        peerIdentityId = relayChat!.peerId;
        final saved = await widget.accountBridge.contacts();
        peerContact = saved
            .where((c) => c.identityId == peerIdentityId)
            .firstOrNull;
        peerName = peerContact?.displayName;
        peerRouteReported = false;
      }
      if (isAuthenticated && peerIdentityId == null && targetContact != null) {
        peerIdentityId = targetContact!.identityId;
        peerName = targetContact!.displayName;
        peerContact = targetContact;
      }
      if (isAuthenticated && !authenticated) await _refreshPeerContacts();
      authenticated = isAuthenticated;
      await _updateFilePeer(isAuthenticated);
      if (generation != peerGeneration) return;
      if (!mounted) return;
      final routePeer = isAuthenticated && !peerRouteReported
          ? peerContact
          : null;
      if (routePeer != null) peerRouteReported = true;
      final receipts = <(String, int)>[];
      final visibleEvents = <PeerEvent>[];
      _updateRelaySync(isAuthenticated);
      for (final event in events) {
        if (!mounted || generation != peerGeneration) return;
        final id = event.messageId;
        if (id != null && id.startsWith(DirectFileLink.controlPrefix)) {
          if ((event.type == 'message' || event.type == 'control') &&
              event.text != null &&
              isAuthenticated &&
              _selectedFileContact?.identityId == peerIdentityId) {
            await fileController?.receiveEncryptedControl(
              id,
              event.text!,
              authenticated: true,
              peer: peerIdentityId,
            );
          }
          continue;
        }
        if (RelayPeerSync.isControlId(id)) {
          if ((event.type == 'message' || event.type == 'control') &&
              event.text != null) {
            await relaySync?.receive(id!, event.text!);
          }
          continue;
        }
        if (ResumableAttachmentTransfer.isPacketId(id)) {
          if (event.type == 'message' && event.text != null) {
            await fileController?.receiveFilePacket(
              id!,
              event.text!,
              direct: false,
            );
            final receivedAt =
                event.receivedAtMilliseconds ??
                DateTime.now().millisecondsSinceEpoch;
            receipts.add((id!, receivedAt));
          }
          continue;
        }
        if (id == null || !AttachmentTransfer.isPacketId(id)) {
          visibleEvents.add(event);
          continue;
        }
        switch (event.type) {
          case 'message':
            final receivedAt =
                event.receivedAtMilliseconds ??
                DateTime.now().millisecondsSinceEpoch;
            try {
              await _receiveAttachment(
                id,
                event.text ?? '',
                event.sentAtMilliseconds,
                receivedAt,
              );
              receipts.add((id, receivedAt));
            } catch (caught) {
              technicalError = caught;
              error = 'Could not receive file. Ask your friend to retry.';
            }
          case 'delivered':
            attachments.acknowledge(
              id,
              receivedAtMilliseconds: event.receivedAtMilliseconds,
            );
          case 'failed':
            attachments.fail(id);
        }
      }
      if (!mounted) return;
      setState(() {
        if (generation != peerGeneration) return;
        connectionState = status['connectionState']! as String;
        authenticated = isAuthenticated;
        if (isAuthenticated || fileController?.ready == true) {
          _clearRecoveredConnectionError();
        }
        if (widget.chatMode && isAuthenticated) showConnectionModal = false;
        for (final event in visibleEvents) {
          switch (event.type) {
            case 'message':
              error = null;
              technicalError = null;
              final existing = history
                  .messagesFor(peerIdentityId ?? widget.targetContactId)
                  .where((message) => message.id == event.messageId)
                  .firstOrNull;
              final receivedAt =
                  existing?.receivedAtMilliseconds ??
                  event.receivedAtMilliseconds ??
                  DateTime.now().millisecondsSinceEpoch;
              _recordMessage(
                PeerMessage(
                  id: event.messageId!,
                  text: event.text!,
                  incoming: true,
                  status: DeliveryStatus.delivered,
                  sentAtMilliseconds: event.sentAtMilliseconds,
                  receivedAtMilliseconds: receivedAt,
                ),
                expectedGeneration: roomGeneration,
              );
              receipts.add((event.messageId!, receivedAt));
            case 'sent':
              error = null;
              technicalError = null;
              _setStatus(event.messageId!, DeliveryStatus.sent);
            case 'delivered':
              error = null;
              technicalError = null;
              _setStatus(
                event.messageId!,
                DeliveryStatus.delivered,
                receivedAtMilliseconds: event.receivedAtMilliseconds,
              );
            case 'failed':
              if (event.messageId != null) {
                _setStatus(event.messageId!, DeliveryStatus.failed);
              }
              technicalError = event.reason;
              if (!isAuthenticated && fileController?.ready != true) {
                if (fileController?.ready != true) {
                  error ??= 'Connection interrupted. Try again.';
                }
              }
            case 'connection':
              final state = event.state;
              if (isAuthenticated) break;
              if (state != null) connectionState = state;
              if (state == 'closed' ||
                  state == 'failed' ||
                  state == 'disconnected') {
                authenticated = false;
                error ??= 'Connection interrupted. Try again.';
              }
          }
        }
      });
      for (final receipt in receipts) {
        try {
          if (useRelay) {
            await relayChat!.acknowledge(receipt.$1, receipt.$2);
          } else {
            await bridge.acknowledgeMessage(receipt.$1, receipt.$2);
          }
        } catch (_) {
          /* A retry will acknowledge the same stored receive time. */
        }
      }
      if (routePeer != null) widget.onPeerAuthenticated?.call(routePeer);
    } catch (caught) {
      if (mounted) {
        setState(() {
          error = 'Connection status unavailable. Try again.';
          technicalError = caught;
        });
      }
    } finally {
      polling = false;
      _reportOnlinePeers();
    }
  }

  Future<bool> _receiveAttachment(
    String id,
    String text,
    int? sentAt,
    int receivedAt,
  ) async {
    if (!AttachmentTransfer.isPacketId(id) &&
        !text.startsWith(AttachmentTransfer.marker)) {
      return false;
    }
    if (!await attachments.receive(id, text, sentAt, receivedAt)) {
      throw const FormatException('Invalid attachment packet');
    }
    return true;
  }

  void _clearRecoveredConnectionError() {
    const recoveredErrors = {
      'Connection interrupted. Try again.',
      'Connection status unavailable. Try again.',
      'The local browser connection could not be secured.',
      'Friend unreachable. Check their connection.',
    };
    if (!recoveredErrors.contains(error)) return;
    error = null;
    technicalError = null;
  }

  Future<void> _refreshPeerContacts() async {
    final updated = await widget.accountBridge.contacts();
    if (!mounted) return;
    history.rememberContacts(updated);
    setState(() {
      contacts = updated;
      targetContact = history
          .withSavedConversations(updated)
          .where((item) => item.identityId == widget.targetContactId)
          .firstOrNull;
      peerContact =
          updated
              .where((item) => item.identityId == peerIdentityId)
              .firstOrNull ??
          peerContact;
    });
    unawaited(_updateFilePeer(authenticated));
  }

  void _updateRelaySync(bool secured) {
    if (secured != _controlWasAuthenticated) {
      _controlWasAuthenticated = secured;
      _controlSession++;
    }
    final peer = peerIdentityId;
    final trusted =
        peer != null &&
        contacts.any(
          (c) =>
              c.identityId == peer &&
              c.verified &&
              (usingRelayChat || c.capabilities.contains('relay-catalog-v1')),
        );
    relaySync?.updateSession(peer, authenticated: secured && trusted);
  }

  Future<void> _handleNativeGatewayEvent(
    PeerEvent event, {
    int? expectedRoomGeneration,
  }) async {
    final generation = peerGeneration;
    final roomGeneration =
        expectedRoomGeneration ??
        history.conversationGeneration(
          peerIdentityId ?? widget.targetContactId ?? '',
        );
    if (event.type == 'connected') {
      _updateRelaySync(false);
      unawaited(_updateFilePeer(false));
      if (mounted) {
        setState(() {
          connectionState = 'connecting';
          authenticated = false;
        });
      }
      return;
    }
    if (event.type == 'disconnected') {
      _updateRelaySync(false);
      unawaited(_updateFilePeer(false));
      if (mounted) {
        setState(() {
          connectionState = 'closed';
          authenticated = false;
        });
      }
      return;
    }
    if (event.type != 'message' || event.text == null) return;
    try {
      final frame = jsonDecode(event.text!);
      if (frame is! Map<String, dynamic>) {
        throw const FormatException('Invalid browser companion frame');
      }
      switch (frame['type']) {
        case 'browserHello':
          final contactCard = frame['contactCard'];
          final targetIdentityId = frame['targetIdentityId'];
          if (contactCard is! String || targetIdentityId is! String) {
            throw const FormatException('Invalid browser hello');
          }
          final localIdentity = await widget.accountBridge.identity();
          if (targetIdentityId != localIdentity.id) {
            throw const FormatException(
              'Browser selected a different Desktop identity',
            );
          }
          final trusted = await _ensureTrustedPeer(
            jsonEncode({'contactCard': contactCard}),
          );
          if (!trusted) return;
          await widget.accountBridge.preparePeer(contactCard, false);
        case 'noise':
          final payload = frame['payload'];
          if (payload is! String) {
            throw const FormatException('Invalid Noise frame');
          }
          final result = await widget.accountBridge.receivePeerHandshake(
            payload,
          );
          final reply = result['reply'];
          if (reply is String) {
            await bridge.sendTransportFrame(
              jsonEncode({'type': 'noise', 'payload': reply}),
            );
          }
          if (result['established'] == true) {
            await _refreshPeerContacts();
            final routePeer = peerContact;
            if (mounted) {
              setState(() {
                authenticated = true;
                connectionState = 'connected';
                _clearRecoveredConnectionError();
                showConnectionModal = false;
              });
            }
            if (routePeer != null && !peerRouteReported) {
              peerRouteReported = true;
              widget.onPeerAuthenticated?.call(routePeer);
            }
            _updateRelaySync(true);
            await _updateFilePeer(true);
          }
        case 'ciphertext':
          final payload = frame['payload'];
          if (payload is! String) {
            throw const FormatException('Invalid encrypted frame');
          }
          final message = await widget.accountBridge.decryptPeerMessage(
            payload,
          );
          if (!mounted || generation != peerGeneration) return;
          final messageId = message['messageId']! as String;
          if (messageId.startsWith(DirectFileLink.controlPrefix)) {
            if (authenticated &&
                _selectedFileContact?.identityId == peerIdentityId) {
              await fileController?.receiveEncryptedControl(
                messageId,
                message['text']! as String,
                authenticated: true,
                peer: peerIdentityId,
              );
            }
            return;
          }
          if (RelayPeerSync.isControlId(messageId)) {
            if (authenticated) {
              await relaySync?.receive(messageId, message['text']! as String);
            }
            return;
          }
          if (ResumableAttachmentTransfer.isPacketId(messageId)) {
            if (authenticated) {
              await fileController?.receiveFilePacket(
                messageId,
                message['text']! as String,
                direct: false,
              );
              await bridge.sendTransportFrame(
                jsonEncode({
                  'type': 'ack',
                  'messageId': messageId,
                  'receivedAtMilliseconds':
                      DateTime.now().millisecondsSinceEpoch,
                }),
              );
            }
            return;
          }
          final existing = history
              .messagesFor(peerIdentityId)
              .where((item) => item.id == messageId)
              .firstOrNull;
          final receivedAt =
              existing?.receivedAtMilliseconds ??
              DateTime.now().millisecondsSinceEpoch;
          final isAttachment = await _receiveAttachment(
            messageId,
            message['text']! as String,
            message['sentAtMilliseconds'] as int?,
            receivedAt,
          );
          await bridge.sendTransportFrame(
            jsonEncode({
              'type': 'ack',
              'messageId': messageId,
              'receivedAtMilliseconds': receivedAt,
            }),
          );
          if (!isAttachment && message['duplicate'] != true && mounted) {
            setState(() {
              _recordMessage(
                PeerMessage(
                  id: messageId,
                  text: message['text']! as String,
                  incoming: true,
                  status: DeliveryStatus.delivered,
                  sentAtMilliseconds: message['sentAtMilliseconds'] as int?,
                  receivedAtMilliseconds: receivedAt,
                ),
                expectedGeneration: roomGeneration,
              );
            });
          }
        case 'ack':
          final messageId = frame['messageId'];
          if (ResumableAttachmentTransfer.isPacketId(
                messageId is String ? messageId : null,
              ) ||
              (messageId is String &&
                  messageId.startsWith(DirectFileLink.controlPrefix))) {
            return;
          }
          if (RelayPeerSync.isControlId(
            messageId is String ? messageId : null,
          )) {
            return;
          }
          if (messageId is String && mounted) {
            if (attachments.acknowledge(
              messageId,
              receivedAtMilliseconds: frame['receivedAtMilliseconds'] as int?,
            )) {
              return;
            }
            setState(
              () => _setStatus(
                messageId,
                DeliveryStatus.delivered,
                receivedAtMilliseconds: frame['receivedAtMilliseconds'] as int?,
              ),
            );
          }
      }
    } catch (caught) {
      if (mounted) {
        setState(() {
          error = 'The local browser connection could not be secured.';
          technicalError = caught;
        });
      }
    }
  }

  Future<void> _startNativeListener() async {
    if (!mounted || working) return;
    final port = int.tryParse(listenerPort.text.trim());
    if (port == null || port < 0 || port > 65535) {
      setState(() => error = 'Port must be between 0 and 65535.');
      return;
    }
    final pin = useListenerPin ? listenerPin.text.trim() : '';
    if (useListenerPin && pin.isEmpty) {
      setState(() => error = 'Enter a PIN or turn PIN protection off.');
      return;
    }
    setState(() {
      working = true;
      error = null;
    });
    try {
      final contactCard = await widget.accountBridge.contactCard(
        displayName:
            widget.profileController?.name ?? profileNameController.text,
        avatar: widget.profileController?.contactAvatar ?? '',
      );
      if (!mounted) return;
      final status = await bridge.startListening(
        port,
        pin,
        allowRelay && !useListenerPin,
        contactCard,
      );
      if (mounted) {
        setState(() {
          nativeListener = status;
          advertisedProfile = (
            widget.profileController?.name ?? profileNameController.text,
            widget.profileController?.contactAvatar ?? '',
          );
        });
      }
    } catch (caught) {
      if (mounted) setState(() => error = '$caught');
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> _stopNativeListener() async {
    setState(() {
      working = true;
      error = null;
    });
    try {
      final status = await bridge.stopListening();
      if (mounted) setState(() => nativeListener = status);
    } catch (caught) {
      if (mounted) setState(() => error = '$caught');
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  void _setStatus(
    String id,
    DeliveryStatus status, {
    int? receivedAtMilliseconds,
  }) {
    final peerId = peerIdentityId ?? widget.targetContactId;
    if (peerId != null) {
      history.setStatus(
        peerId,
        id,
        status,
        receivedAtMilliseconds: receivedAtMilliseconds,
      );
    }
  }

  void _recordMessage(PeerMessage message, {int? expectedGeneration}) {
    final peerId = peerIdentityId ?? widget.targetContactId;
    if (peerId != null) {
      history.add(peerId, message, expectedGeneration: expectedGeneration);
    }
  }

  Future<void> _run(
    Future<void> Function() action, {
    String failureMessage =
        'Could not connect. Check the invitation and try again.',
  }) async {
    setState(() {
      working = true;
      error = null;
      technicalError = null;
    });
    try {
      await action();
      if (!mounted) return;
      setState(() => working = false);
    } catch (caught) {
      if (!mounted) return;
      setState(() {
        working = false;
        error = failureMessage;
        technicalError = caught;
      });
    }
  }

  Future<void> _startInvitation() async {
    final displayName = await _saveProfileName();
    if (displayName == null) return;
    setState(() => flow = ConnectionFlow.invite);
    await _run(() async {
      final offer = await bridge.createOffer(stun.text, displayName);
      roomCode = await bridge.createRoom(offer);
    }, failureMessage: 'Could not create a room. Please try again.');
    if (roomCode != null) _startAnswerPolling();
  }

  Future<void> _joinRoom() async {
    final displayName = await _saveProfileName();
    if (displayName == null) return;
    final code = roomCodeInput.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      setState(() => error = 'Enter your friend\'s 6-digit code.');
      return;
    }
    late final String offer;
    setState(() {
      working = true;
      error = null;
      technicalError = null;
    });
    try {
      offer = await bridge.loadRoomOffer(code);
    } catch (caught) {
      if (!mounted) return;
      setState(() {
        working = false;
        error = 'Room not found. Check the 6-digit code and try again.';
        technicalError = caught;
      });
      return;
    }
    if (mounted) setState(() => working = false);
    if (!await _ensureTrustedPeer(offer)) return;
    await _run(() async {
      final answer = await bridge.acceptOffer(offer, stun.text, displayName);
      await bridge.publishRoomAnswer(code, answer);
      roomCode = code;
      replyCreated = true;
    });
  }

  void _startAnswerPolling() {
    answerTimer?.cancel();
    answerTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _checkForAnswer(),
    );
    _checkForAnswer();
  }

  Future<void> _checkForAnswer() async {
    final code = roomCode;
    if (code == null || checkingAnswer || authenticated) return;
    checkingAnswer = true;
    try {
      final answer = await bridge.loadRoomAnswer(code);
      if (answer == null || !mounted) return;
      answerTimer?.cancel();
      pendingAnswer = answer;
      await _applyPendingAnswer();
    } catch (caught) {
      if (mounted) {
        setState(() {
          error = 'Could not check the room. Please create a new room.';
          technicalError = caught;
        });
      }
      answerTimer?.cancel();
    } finally {
      checkingAnswer = false;
    }
  }

  Future<void> _applyPendingAnswer() async {
    final answer = pendingAnswer;
    if (answer == null) return;
    if (!await _ensureTrustedPeer(answer)) {
      if (mounted) setState(() {});
      return;
    }
    await _run(() => bridge.acceptAnswer(answer));
    pendingAnswer = null;
  }

  Future<bool> _ensureTrustedPeer(String connectionCode) async {
    setState(() {
      working = true;
      error = null;
      technicalError = null;
    });
    try {
      final signal = jsonDecode(connectionCode);
      if (signal is! Map || signal['contactCard'] is! String) {
        throw const FormatException('Missing signed contact card');
      }
      final cardJson = signal['contactCard']! as String;
      final inspected = await widget.accountBridge.inspectContactCard(cardJson);
      final expectedIdentityId = widget.targetContactId;
      if (expectedIdentityId != null &&
          inspected.identityId != expectedIdentityId) {
        if (!mounted) return false;
        setState(() {
          working = false;
          error =
              'This room belongs to ${inspected.displayName}, not ${targetContact?.displayName ?? 'the selected friend'}.';
        });
        return false;
      }
      peerName = inspected.displayName;
      peerIdentityId = inspected.identityId;
      peerContact = inspected;
      final identity = await widget.accountBridge.identity();
      if (inspected.identityId == identity.id) {
        if (!mounted) return false;
        setState(() {
          working = false;
          error = 'Both nodes use the same identity. Switch one identity.';
        });
        return false;
      }

      final contacts = await widget.accountBridge.contacts();
      final existing = contacts
          .where((contact) => contact.identityId == inspected.identityId)
          .firstOrNull;
      if (existing?.verified == true) {
        if (mounted) setState(() => working = false);
        return true;
      }

      if (!mounted) return false;
      final accepted = await _confirmFingerprint(inspected, existing);
      if (accepted == null) {
        if (mounted) setState(() => working = false);
        return false;
      }
      if (existing == null) {
        await widget.accountBridge.addContact(cardJson, accepted);
      }
      await widget.accountBridge.markContactVerified(inspected.identityId);
      if (mounted) setState(() => working = false);
      return true;
    } catch (caught) {
      if (!mounted) return false;
      setState(() {
        working = false;
        error = 'Invalid code. Copy the full code and retry.';
        technicalError = caught;
      });
      return false;
    }
  }

  Future<String?> _confirmFingerprint(
    ContactView inspected,
    ContactView? existing,
  ) async {
    final name = TextEditingController(
      text: existing?.displayName ?? inspected.displayName,
    );
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = DialogRoute<bool>(
      context: context,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text('Verify ${inspected.displayName}'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Compare with your friend in person or by call.'),
              const SizedBox(height: 8),
              Text('Claimed name: ${inspected.displayName}'),
              const SizedBox(height: 12),
              SelectableText(
                inspected.fingerprint,
                key: const Key('peer-fingerprint'),
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              if (existing == null) ...[
                const SizedBox(height: 16),
                TextField(
                  key: const Key('peer-display-name'),
                  controller: name,
                  decoration: const InputDecoration(labelText: 'Friend’s name'),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('trust-peer-fingerprint'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Fingerprint matches'),
          ),
        ],
      ),
    );
    final accepted = await navigator.push(route);
    await route.completed;
    final displayName = name.text.trim();
    name.dispose();
    if (accepted != true) return null;
    return displayName.isEmpty ? inspected.displayName : displayName;
  }

  Future<void> _copyRoomCode() async {
    await Clipboard.setData(ClipboardData(text: roomCode ?? ''));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Room code copied.')));
  }

  Future<void> _loadProfileName() async {
    final profileName = widget.profileController?.name ?? '';
    if (profileName.isNotEmpty) {
      profileNameController.text = profileName;
      return;
    }
    try {
      final name = await bridge.profileName();
      if (mounted) profileNameController.text = name;
    } catch (_) {
      // The field remains editable if browser storage is unavailable.
    }
  }

  Future<void> _loadTargetContact() async {
    final targetId = widget.targetContactId;
    final generation = peerGeneration;
    if (targetId == null) {
      if (mounted) setState(() => targetContact = null);
      return;
    }
    if ((authenticated && peerIdentityId != targetId) ||
        (connectionAttemptPeerId != null &&
            connectionAttemptPeerId != targetId)) {
      await _resetFlow();
    }
    try {
      final contacts = history.withSavedConversations(
        await widget.accountBridge.contacts(),
      );
      final selected = contacts
          .where((contact) => contact.identityId == targetId)
          .firstOrNull;
      if (mounted &&
          generation == peerGeneration &&
          targetId == widget.targetContactId) {
        setState(() {
          this.contacts = contacts;
          targetContact = selected;
        });
        if (selected?.verified == true) unawaited(_connectAutomatically());
        unawaited(_updateFilePeer(authenticated));
      }
    } catch (caught) {
      if (mounted) {
        setState(() {
          targetContact = null;
          error = 'Could not load this friend. Open Contacts and try again.';
          technicalError = caught;
        });
      }
    }
  }

  Future<void> _connectAutomatically({bool force = false}) async {
    if (!mounted || working || initializingRelays) return;
    final contact = targetContact;
    if (!(bridge.supportsAutomaticContact ||
            relayNetwork?.enabled == true ||
            (relayNetwork != null && contact?.relayUrls.isNotEmpty == true)) ||
        contact == null ||
        !contact.verified) {
      return;
    }
    if (automaticConnectionAttempted && !force) return;
    automaticConnectionAttempted = true;
    final displayName =
        widget.profileController?.name.trim() ??
        profileNameController.text.trim();
    if (displayName.isEmpty) {
      if (mounted) {
        setState(() => error = 'Set your Profile name before connecting.');
      }
      return;
    }
    if (mounted) {
      setState(() {
        working = true;
        connectionAttemptPeerId = contact.identityId;
        connectionState = 'connecting';
        error = null;
        technicalError = null;
      });
    }
    try {
      if (relayNetwork != null) {
        await relayNetwork!.addContactRoutes(contact.relayUrls);
      }
      if (relayNetwork?.enabled == true) {
        await bridge.close();
        relayChat!.select(contact.identityId);
      } else {
        await bridge.connectContact(contact.identityId, displayName);
      }
    } catch (caught) {
      if (mounted && widget.targetContactId == contact.identityId) {
        setState(() {
          connectionState = 'closed';
          error = 'Friend unreachable. Check their connection.';
          technicalError = caught;
        });
      }
    } finally {
      if (mounted && connectionAttemptPeerId == contact.identityId) {
        setState(() {
          working = false;
          connectionAttemptPeerId = null;
        });
      }
    }
  }

  Future<String?> _saveProfileName() async {
    final name = profileNameController.text.trim();
    if (name.isEmpty) {
      setState(() => error = 'Enter your name before connecting.');
      return null;
    }
    if (name.characters.length > 64) {
      setState(() => error = 'Your name must be 64 characters or fewer.');
      return null;
    }
    try {
      await widget.profileController?.saveName(name);
      await bridge.setProfileName(name);
      return name;
    } catch (caught) {
      if (mounted) {
        setState(() {
          error = 'Could not save your name. Please try again.';
          technicalError = caught;
        });
      }
      return null;
    }
  }

  Future<void> _resetFlow() async {
    _updateRelaySync(false);
    await fileController?.updatePeer(null, encryptedAuthenticated: false);
    await bridge.close();
    relayChat?.disconnectPeer();
    answerTimer?.cancel();
    roomCodeInput.clear();
    if (!mounted) return;
    setState(() {
      flow = ConnectionFlow.choose;
      replyCreated = false;
      roomCode = null;
      pendingAnswer = null;
      peerName = null;
      peerIdentityId = null;
      peerContact = null;
      peerRouteReported = false;
      working = false;
      connectionAttemptPeerId = null;
      error = null;
      technicalError = null;
    });
  }

  String get connectionLabel {
    if (authenticated) return 'Connected securely';
    if (pendingAnswer != null) return 'Verify your friend';
    if (roomCode != null) return 'Waiting for secure connection…';
    return switch (connectionState) {
      'connecting' || 'checking' => 'Connecting…',
      'connected' || 'completed' => 'Securing connection…',
      'disconnected' => 'Connection interrupted',
      'failed' => 'Unable to connect',
      'closed' => 'Connection closed',
      _ => 'Ready to connect',
    };
  }

  IconData get connectionIcon {
    if (authenticated) return Icons.lock_outline;
    return switch (connectionState) {
      'disconnected' || 'failed' => Icons.cloud_off_outlined,
      _ => Icons.hub_outlined,
    };
  }

  Widget _statusCard() => Card(
    child: ListTile(
      leading: Icon(connectionIcon),
      title: Text(connectionLabel),
      subtitle: authenticated && peerName != null ? Text(peerName!) : null,
    ),
  );

  Widget _chooseFlow() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        'Connect with a friend',
        style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 8),
      const Text('One person invites; the other joins.'),
      const SizedBox(height: 20),
      TextField(
        key: const Key('profile-name'),
        controller: profileNameController,
        enabled: !working,
        maxLength: 64,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(
          labelText: 'Your name',
          prefixIcon: Icon(Icons.badge_outlined),
        ),
      ),
      const SizedBox(height: 12),
      FilledButton.icon(
        key: const Key('invite-friend'),
        onPressed: working ? null : _startInvitation,
        icon: const Icon(Icons.person_add_alt_1_outlined),
        label: const Padding(
          padding: EdgeInsets.symmetric(vertical: 14),
          child: Text('Invite a friend'),
        ),
      ),
      const SizedBox(height: 10),
      OutlinedButton.icon(
        key: const Key('join-invitation'),
        onPressed: working
            ? null
            : () => setState(() => flow = ConnectionFlow.join),
        icon: const Icon(Icons.markunread_mailbox_outlined),
        label: const Padding(
          padding: EdgeInsets.symmetric(vertical: 14),
          child: Text('I have an invitation'),
        ),
      ),
    ],
  );

  Widget _inviteFlow() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _flowHeader('Invite a friend'),
      if (working && roomCode == null) ...[
        const SizedBox(height: 32),
        const Center(child: CircularProgressIndicator()),
        const SizedBox(height: 12),
        const Center(child: Text('Creating a private room…')),
      ] else if (roomCode != null) ...[
        const Text('Share this code with your friend.'),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: SelectableText(
              roomCode!.split('').join(' '),
              key: const Key('room-code'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 38,
                fontWeight: FontWeight.bold,
                letterSpacing: 4,
              ),
            ),
          ),
        ),
        FilledButton.icon(
          key: const Key('copy-room-code'),
          onPressed: _copyRoomCode,
          icon: const Icon(Icons.copy_outlined),
          label: const Text('Copy room code'),
        ),
        const SizedBox(height: 24),
        if (!authenticated) ...[
          const LinearProgressIndicator(),
          const SizedBox(height: 10),
          const Text(
            'Waiting for your friend. Keep this page open.',
            textAlign: TextAlign.center,
          ),
        ],
        if (pendingAnswer != null && !working)
          FilledButton(
            key: const Key('review-peer'),
            onPressed: _applyPendingAnswer,
            child: const Text('Check fingerprint'),
          ),
      ] else ...[
        FilledButton(
          onPressed: working ? null : _startInvitation,
          child: const Text('Try again'),
        ),
      ],
    ],
  );

  Widget _joinFlow() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _flowHeader('Join a friend'),
      if (!replyCreated) ...[
        const Text('Enter your friend\'s 6-digit code.'),
        const SizedBox(height: 16),
        TextField(
          key: const Key('room-code-input'),
          controller: roomCodeInput,
          autofocus: true,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          maxLength: 6,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          style: const TextStyle(
            fontSize: 32,
            fontWeight: FontWeight.bold,
            letterSpacing: 8,
          ),
          decoration: const InputDecoration(
            labelText: 'Room code',
            hintText: '000000',
          ),
          onSubmitted: (_) => working ? null : _joinRoom(),
        ),
        const SizedBox(height: 8),
        FilledButton(
          key: const Key('join-room'),
          onPressed: working ? null : _joinRoom,
          child: Text(working ? 'Joining…' : 'Join room'),
        ),
      ] else ...[
        Card(
          child: ListTile(
            leading: Icon(
              authenticated ? Icons.lock_outline : Icons.hourglass_top,
            ),
            title: Text(
              authenticated
                  ? 'Connected securely with ${peerName ?? 'your friend'}'
                  : 'Reply sent',
            ),
            subtitle: Text(
              authenticated
                  ? 'Ready to chat'
                  : 'Waiting for fingerprint approval',
            ),
          ),
        ),
      ],
    ],
  );

  Widget _flowHeader(String title) => Row(
    children: [
      IconButton(
        key: const Key('back-to-connect-choice'),
        onPressed: working ? null : _resetFlow,
        tooltip: 'Back',
        icon: const Icon(Icons.arrow_back),
      ),
      Text(
        title,
        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
      ),
    ],
  );

  Widget _advancedSettings() => ExpansionTile(
    key: const Key('advanced-network-settings'),
    tilePadding: EdgeInsets.zero,
    title: const Text('Advanced settings'),
    children: [
      TextField(
        key: const Key('custom-stun-url'),
        controller: stun,
        autocorrect: false,
        enableSuggestions: false,
        decoration: const InputDecoration(
          labelText: 'STUN server',
          helperText: 'The provider can see connection metadata.',
        ),
      ),
      if (technicalError != null)
        SelectableText(
          'Technical details: $technicalError',
          style: const TextStyle(color: Color(0xFFB8B8B8)),
        ),
    ],
  );

  Future<void> _sendPacket(String id, String text, int sentAt) async {
    if (fileController?.ready == true &&
        fileController?.peerId == (widget.targetContactId ?? peerIdentityId)) {
      if (AttachmentTransfer.isPacketId(id) || RelayPeerSync.isControlId(id)) {
        await fileController!.sendDirectPacket(id, text, sentAt);
      } else {
        await fileController!.sendChatMessage(id, text, sentAt);
      }
      return;
    }
    await _sendLegacyPacket(id, text, sentAt);
  }

  Future<void> _sendBoundFallback(String id, String text, int sentAt) async {
    final expectedPeer = fileController?.peerId;
    final generation = peerGeneration, session = _controlSession;
    final relay = usingRelayChat;
    bool current() =>
        mounted &&
        authenticated &&
        expectedPeer != null &&
        expectedPeer == peerIdentityId &&
        expectedPeer == (widget.targetContactId ?? peerIdentityId) &&
        generation == peerGeneration &&
        session == _controlSession &&
        relay == usingRelayChat;
    void guard() {
      if (!current()) throw const TransferInterrupted();
    }

    guard();
    if (relay) {
      await relayChat!.sendMessage(id, text, sentAt, isCurrent: current);
    } else if (bridge.supportsListening) {
      final payload = await widget.accountBridge.encryptPeerMessage(
        id,
        text,
        sentAtMilliseconds: sentAt,
      );
      guard();
      await bridge.sendTransportFrame(
        jsonEncode({'type': 'ciphertext', 'payload': payload}),
      );
    } else {
      guard();
      await bridge.sendMessage(id, text, sentAtMilliseconds: sentAt);
    }
    guard();
  }

  Future<void> _sendLegacyPacket(String id, String text, int sentAt) async {
    if (!authenticated) {
      throw const TransferInterrupted(
        'Waiting for Direct or an authenticated data relay',
      );
    }
    final scope = AttachmentTransfer.isPacketId(id) ? _attachmentScope : null;
    if (scope != null) _guardPeer(scope.$1, scope.$2);
    if (AttachmentTransfer.isPacketId(id) &&
        attachmentUsesRelay != null &&
        attachmentUsesRelay != usingRelayChat) {
      throw StateError('Transfer route changed. Retry the file.');
    }
    if (usingRelayChat) {
      await relayChat!.sendMessage(id, text, sentAt);
    } else if (bridge.supportsListening) {
      final payload = await widget.accountBridge.encryptPeerMessage(
        id,
        text,
        sentAtMilliseconds: sentAt,
      );
      if (scope != null) _guardPeer(scope.$1, scope.$2);
      await bridge.sendTransportFrame(
        jsonEncode({'type': 'ciphertext', 'payload': payload}),
      );
    } else {
      await bridge.sendMessage(id, text, sentAtMilliseconds: sentAt);
    }
  }

  Future<bool> _send({PeerMessage? retry, String? value}) async {
    if (retry?.hasAttachment == true) {
      final peer = widget.targetContactId ?? peerIdentityId;
      final generation = peerGeneration;
      try {
        if (retry!.attachmentRef?.isChunked == true) {
          if (peer == null || !_isPeer(peer, generation)) return false;
          return await _sendCachedFile(retry, peer, generation);
        }
        final attachment = await history.resolveAttachment(retry);
        if (peer == null || !_isPeer(peer, generation)) return false;
        return await _sendAttachment(
          attachment,
          retry: retry,
          expectedPeer: peer,
          expectedGeneration: generation,
        );
      } catch (caught) {
        if (peer != null && _isPeer(peer, generation)) {
          setState(() => error = 'Could not read cached file.');
        }
        return false;
      }
    }
    final text = retry?.text ?? (value ?? messageInput.text).trim();
    if (text.isEmpty) return false;
    final peer = widget.targetContactId ?? peerIdentityId;
    final message =
        retry ??
        PeerMessage(
          id: 'p2p-${DateTime.now().microsecondsSinceEpoch}-${messageCounter++}',
          text: text,
          incoming: false,
          status: DeliveryStatus.pending,
        );
    if (retry == null) _recordMessage(message);
    message.status = DeliveryStatus.pending;
    history.changed();
    try {
      await _sendPacket(
        message.id,
        text,
        message.sentAtMilliseconds ?? DateTime.now().millisecondsSinceEpoch,
      );
      if ((bridge.supportsListening && !usingRelayChat ||
              fileController?.ready == true) &&
          peer != null) {
        if (message.status != DeliveryStatus.delivered) {
          history.setStatus(peer, message.id, DeliveryStatus.sent);
        }
      }
      return true;
    } catch (caught) {
      if (mounted) {
        message.status = DeliveryStatus.failed;
        setState(() {
          error = 'Message not sent. Reconnect and retry.';
          technicalError = caught;
        });
        history.changed();
      }
      return false;
    }
  }

  bool _isPeer(String peer, int generation) =>
      mounted &&
      generation == peerGeneration &&
      (widget.targetContactId ?? peerIdentityId) == peer;
  void _guardPeer(String peer, int generation) {
    if (!_isPeer(peer, generation)) {
      throw StateError('Chat changed. Retry in the original chat.');
    }
  }

  Future<bool> _sendBatch(String text, List<ChatAttachment> files) async {
    if (_sendingBatch || attachmentUsesRelay != null) return false;
    final peer = widget.targetContactId ?? peerIdentityId;
    final generation = peerGeneration;
    if (peer == null) return false;
    _sendingBatch = true;
    try {
      if (_draftBatch == null ||
          _draftText != text ||
          _draftPeer != peer ||
          !listEquals(_draftFiles, files)) {
        final id =
            'batch_${DateTime.now().microsecondsSinceEpoch}_${messageCounter++}';
        _draftBatch = prepareMediaBatch(text, files, id);
        _draftText = text;
        _draftPeer = peer;
        _draftFiles = List.of(files);
        _draftMessages = [
          for (var i = 0; i < _draftBatch!.files.length; i++)
            PeerMessage(
              id: '${id}_$i',
              text: _draftBatch!.files[i].previewLabel,
              incoming: false,
              status: DeliveryStatus.pending,
              attachment: _draftBatch!.files[i],
            ),
        ];
      }
      final batch = _draftBatch!;
      final queued = List<PeerMessage>.of(_draftMessages);
      final limit = fileController?.supportsLargeFiles == true
          ? ChatAttachment.maxStreamedBytes
          : usingRelayChat
          ? ChatAttachment.relayMaxBytes
          : ChatAttachment.maxBytes;
      for (var i = 0; i < batch.files.length; i++) {
        if (batch.files[i].size > limit) {
          throw const FormatException('File exceeds this connection limit.');
        }
        if (!batch.files[i].isStreamed) {
          AttachmentTransfer.validateOutgoing(queued[i].id, batch.files[i]);
        }
      }
      await history.addAttachments(peer, queued);
      _draftBatch = null;
      _draftMessages = [];
      _draftFiles = [];
      // Queueing has succeeded; network delivery and retry belong to the bubbles.
      unawaited(() async {
        try {
          for (var i = 0; i < batch.files.length; i++) {
            if (!_isPeer(peer, generation)) {
              for (final message in queued.skip(i)) {
                history.setStatus(peer, message.id, DeliveryStatus.failed);
              }
              return;
            }
            await _sendAttachment(
              batch.files[i],
              retry: queued[i],
              expectedPeer: peer,
              expectedGeneration: generation,
            );
          }
        } finally {
          _sendingBatch = false;
        }
      }());
      return true;
    } catch (caught) {
      _sendingBatch = false;
      if (_isPeer(peer, generation)) {
        setState(
          () => error = caught is FormatException
              ? caught.message
              : 'Could not save files. Try again.',
        );
      }
      return false;
    }
  }

  Future<bool> _sendAttachment(
    ChatAttachment attachment, {
    PeerMessage? retry,
    String? expectedPeer,
    int? expectedGeneration,
  }) async {
    final peer = expectedPeer ?? widget.targetContactId ?? peerIdentityId;
    final generation = expectedGeneration ?? peerGeneration;
    if (peer == null || !_isPeer(peer, generation)) return false;
    if (attachment.isStreamed &&
        fileController?.supportsLargeFiles != true &&
        retry == null) {
      try {
        attachment = await materializeLegacyAttachment(
          attachment,
          maxBytes: usingRelayChat
              ? ChatAttachment.relayMaxBytes
              : ChatAttachment.maxBytes,
        );
        _guardPeer(peer, generation);
      } catch (caught) {
        if (_isPeer(peer, generation)) {
          setState(() => error = 'Update both apps to send this file size.');
        }
        return false;
      }
    }
    if (attachment.isStreamed || retry?.attachmentRef?.isChunked == true) {
      final message =
          retry ??
          PeerMessage(
            id: 'file-${DateTime.now().microsecondsSinceEpoch}-${messageCounter++}',
            text: attachment.previewLabel,
            attachment: attachment,
            incoming: false,
            status: DeliveryStatus.pending,
          );
      try {
        if (fileController?.supportsLargeFiles != true) {
          throw const TransferRejected('Update both apps to send large files');
        }
        if (retry == null) await history.addAttachment(peer, message);
        _guardPeer(peer, generation);
        if (message.attachmentRef?.isChunked != true) {
          throw const TransferRejected('Encrypted chunk cache is unavailable');
        }
        return await _sendCachedFile(message, peer, generation);
      } catch (caught) {
        if (caught is TransferInterrupted) return true;
        if (retry != null) {
          history.setStatus(peer, message.id, DeliveryStatus.failed);
        }
        if (_isPeer(peer, generation)) {
          setState(() {
            error = caught is TransferRejected
                ? caught.message
                : 'Could not save file. Try again.';
            technicalError = caught;
          });
        }
        return false;
      }
    }
    if (attachmentUsesRelay != null) return false;
    attachmentUsesRelay = usingRelayChat;
    final scope = (peer, generation);
    _attachmentScope = scope;
    final message =
        retry ??
        PeerMessage(
          id: 'file-${DateTime.now().microsecondsSinceEpoch}-${messageCounter++}',
          text: attachment.previewLabel,
          attachment: attachment,
          incoming: false,
          status: DeliveryStatus.pending,
        );
    message.status = DeliveryStatus.pending;
    try {
      if (retry == null) {
        await history.addAttachment(peer, message);
      } else {
        history.changed();
      }
      _guardPeer(peer, generation);
      final receivedAt = await attachments.send(
        message.id,
        attachment,
        message.sentAtMilliseconds ?? DateTime.now().millisecondsSinceEpoch,
      );
      if (_isPeer(peer, generation)) {
        history.setStatus(
          peer,
          message.id,
          DeliveryStatus.delivered,
          receivedAtMilliseconds: receivedAt,
        );
        setState(() => transferProgress.remove(message.id));
      }
      return true;
    } catch (caught) {
      history.setStatus(peer, message.id, DeliveryStatus.failed);
      if (_isPeer(peer, generation)) {
        setState(() {
          transferProgress.remove(message.id);
          error = 'File not sent. Reconnect and retry.';
          technicalError = caught;
        });
      }
      return false;
    } finally {
      if (_attachmentScope == scope) {
        attachmentUsesRelay = null;
        _attachmentScope = null;
      }
    }
  }

  Future<bool> _sendCachedFile(
    PeerMessage message,
    String peer,
    int generation,
  ) async {
    try {
      _guardPeer(peer, generation);
      if (fileController?.peerId != peer) throw const TransferInterrupted();
      await fileController!.send(message);
      return true;
    } on TransferInterrupted {
      return true; // Durable job remains pending and resumes on reconnection.
    } catch (caught) {
      if (_isPeer(peer, generation)) {
        history.setStatus(peer, message.id, DeliveryStatus.failed);
        setState(() {
          error = 'File not sent. Retry the file.';
          technicalError = caught;
        });
      }
      return false;
    }
  }

  Widget _chatSidebar() => ConversationList(
    conversations: [
      ...?widget.chatController?.conversations,
      ...widget.extraConversations,
      for (final contact in history.withSavedConversations(contacts))
        ConversationView(
          id: contact.identityId,
          title: contact.displayName,
          avatarBase64: contact.avatarBase64,
          preview:
              history.messagesFor(contact.identityId).lastOrNull?.text ??
              ((contact.identityId == peerIdentityId && authenticated) ||
                      (fileController?.ready == true &&
                          fileController?.peerId == contact.identityId)
                  ? 'Connected securely'
                  : 'Offline'),
          updatedAtMilliseconds:
              history
                  .messagesFor(contact.identityId)
                  .lastOrNull
                  ?.sentAtMilliseconds ??
              0,
          messages: const [],
        ),
    ],
    selectedId: widget.targetContactId ?? '',
    onSelected: (id) {
      if (widget.extraConversations.any((room) => room.id == id)) {
        widget.onRoomSelected?.call(id);
        return;
      }
      final contact = history
          .withSavedConversations(contacts)
          .where((item) => item.identityId == id)
          .firstOrNull;
      if (contact != null) {
        widget.onChatSelected?.call(contact);
      } else {
        widget.onRoomSelected?.call(id);
      }
    },
    onCreateGroup: widget.onCreateGroup,
    onActionSelected: widget.onConversationAction,
  );

  MediaItem _mediaItem(PeerMessage message) {
    final file = message.attachment;
    final ref = message.attachmentRef;
    return MediaItem(
      id: message.id,
      name: file?.name ?? ref!.name,
      kind: file?.kind ?? ref!.kind,
      incoming: message.incoming,
      caption: file?.caption ?? ref?.caption,
      groupId: file?.groupId ?? ref?.groupId,
      groupIndex: file?.groupIndex ?? ref?.groupIndex,
      groupCount: file?.groupCount ?? ref?.groupCount,
      loadFile: () => history.resolveAttachment(message),
      loadThumbnail: () =>
          history.thumbnailFor(message, generate: createMediaThumbnail),
      onRetry: message.status == DeliveryStatus.failed
          ? () {
              _send(retry: message);
            }
          : null,
    );
  }

  Widget _peerMessageList() {
    final groups = groupMedia<PeerMessage>(
      messages,
      (message) => message.hasAttachment ? _mediaItem(message).groupKey : null,
    );
    return ListView.builder(
      key: ValueKey('peer-history-${widget.targetContactId ?? peerIdentityId}'),
      reverse: true,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 20),
      itemCount: groups.length + (incomingProgress.isEmpty ? 0 : 1),
      itemBuilder: (context, index) {
        if (incomingProgress.isNotEmpty && index == 0) {
          return Column(
            children: [
              for (final progress in incomingProgress.values)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    children: [
                      const Icon(Icons.download_outlined, size: 18),
                      const SizedBox(width: 8),
                      Expanded(child: LinearProgressIndicator(value: progress)),
                      const SizedBox(width: 8),
                      Text('${(progress * 100).round()}%'),
                    ],
                  ),
                ),
            ],
          );
        }
        final messageIndex = index - (incomingProgress.isEmpty ? 0 : 1);
        final group = groups[groups.length - 1 - messageIndex];
        final message = group.first;
        final album =
            message.hasAttachment && _mediaItem(message).groupKey != null;
        return Column(
          crossAxisAlignment: message.incoming
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.end,
          children: [
            MessageBubble(
              text: message.text,
              incoming: message.incoming,
              sentAtMilliseconds: message.sentAtMilliseconds,
              receivedAtMilliseconds: message.receivedAtMilliseconds,
              bubbleKey: Key('peer-message-${message.id}'),
              onRetry:
                  !album &&
                      message.status == DeliveryStatus.failed &&
                      attachmentUsesRelay == null
                  ? () => _send(retry: message)
                  : null,
              content: album
                  ? MediaAlbum(
                      key: ValueKey(_mediaItem(message).groupKey),
                      items: group.map(_mediaItem).toList(),
                    )
                  : !message.hasAttachment
                  ? null
                  : message.attachment != null
                  ? AttachmentContent(
                      attachment: message.attachment!,
                      incoming: message.incoming,
                    )
                  : CachedAttachmentContent(
                      key: ObjectKey(message),
                      history: history,
                      message: message,
                    ),
            ),
            if (fileController?.progress[message.id] != null)
              SizedBox(
                width: 220,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: FileTransferStatus(
                    snapshot: fileController!.progress[message.id]!,
                  ),
                ),
              ),
            if (transferProgress.containsKey(message.id))
              SizedBox(
                width: 180,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: LinearProgressIndicator(
                          value: transferProgress[message.id],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text('${(transferProgress[message.id]! * 100).round()}%'),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _peerComposer() => MessageComposer(
    key: ValueKey('composer-${widget.targetContactId ?? peerIdentityId}'),
    controller: messageInput,
    inputKey: const Key('peer-message-input'),
    sendKey: const Key('send-peer-message'),
    onSend: (text) => _send(value: text),
    onSendAttachment: _sendAttachment,
    onSendBatch: _sendBatch,
    pickAttachments: widget.pickAttachments,
    maxAttachmentBytes: fileController?.supportsLargeFiles == true
        ? ChatAttachment.maxStreamedBytes
        : usingRelayChat
        ? ChatAttachment.relayMaxBytes
        : ChatAttachment.maxBytes,
  );

  Widget _peerRoom({VoidCallback? onBack}) {
    final contact = targetContact;
    final direct =
        fileController?.ready == true &&
        fileController?.peerId == widget.targetContactId;
    final connected =
        (authenticated && peerIdentityId == widget.targetContactId) || direct;
    return ColoredBox(
      color: const Color(0xFF1A1A1A),
      child: Column(
        children: [
          SizedBox(
            height: 68,
            child: Row(
              children: [
                if (onBack != null)
                  IconButton(
                    onPressed: onBack,
                    tooltip: 'Back to chats',
                    icon: const Icon(Icons.arrow_back),
                  ),
                const SizedBox(width: 12),
                ProfileAvatar(
                  key: const Key('chat-peer-avatar'),
                  name: contact?.displayName ?? 'Friend',
                  avatarBase64: contact == null
                      ? ''
                      : history.withCachedAvatar(contact).avatarBase64,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        contact?.displayName ?? 'Friend',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        connected
                            ? (direct
                                  ? 'Direct · connected securely'
                                  : usingRelayChat
                                  ? 'Relay · connected securely'
                                  : 'Direct · connected securely')
                            : seedClient?.registered == true
                            ? 'Waiting for Direct'
                            : 'Offline',
                        style: TextStyle(
                          color: connected
                              ? const Color(0xFF9AE585)
                              : const Color(0xFF8E8E93),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                if (connected)
                  const Padding(
                    padding: EdgeInsets.only(right: 20),
                    child: Icon(Icons.lock_outline, size: 20),
                  ),
                if (contact != null)
                  PopupMenuButton<String>(
                    key: const Key('chat-actions-menu'),
                    tooltip: 'Chat actions',
                    icon: const Icon(Icons.more_vert),
                    onSelected: (action) async {
                      if (action == 'details') {
                        await showContactDetailsSheet(context, contact);
                      } else if (action == 'delete') {
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('Delete chat?'),
                            content: const Text(
                              'This clears chat history on this device. Your friend and their copy of the conversation are unchanged. Received files may remain in local caches.',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context, false),
                                child: const Text('Cancel'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(context, true),
                                child: const Text('Delete chat'),
                              ),
                            ],
                          ),
                        );
                        if (confirmed == true) {
                          fileController?.cancelPendingFor(contact.identityId);
                          relayChat?.cancelPendingFor(contact.identityId);
                          if (_selectedFileContact?.identityId ==
                              contact.identityId) {
                            attachments.reset();
                            transferProgress.clear();
                            incomingProgress.clear();
                          }
                          await history.clearConversation(contact.identityId);
                        }
                      }
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(
                        value: 'details',
                        child: Text('Contact details'),
                      ),
                      PopupMenuItem(
                        value: 'delete',
                        child: Text('Delete chat'),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (seedClient != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 3),
              child: Text(
                seedClient!.status,
                key: const Key('seed-status'),
                style: const TextStyle(fontSize: 11, color: Color(0xFF8E8E93)),
              ),
            ),
          if (history.error != null)
            const Padding(
              padding: EdgeInsets.all(8),
              child: Text(
                'Could not save chat history.',
                style: TextStyle(color: Colors.redAccent),
              ),
            ),
          if (connected) ...[
            Expanded(child: _peerMessageList()),
            if (error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  error!,
                  key: const Key('connection-error'),
                  style: const TextStyle(color: Colors.redAccent),
                ),
              ),
            _peerComposer(),
          ] else
            Expanded(
              child: Column(
                children: [
                  Expanded(child: _peerMessageList()),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: _offlineChat(),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _secureChatLayout() => LayoutBuilder(
    key: const Key('secure-chat-shell'),
    builder: (context, constraints) {
      if (!widget.showChatSidebar || constraints.maxWidth <= 720) {
        return _peerRoom(onBack: widget.onBackToChats);
      }
      return Row(
        children: [
          SizedBox(width: 340, child: _chatSidebar()),
          const VerticalDivider(width: 1, thickness: 1),
          Expanded(child: _peerRoom(onBack: widget.onBackToChats)),
        ],
      );
    },
  );

  Widget _offlineChat() => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            targetContact == null
                ? 'Friend is not available'
                : '${targetContact!.displayName} is offline',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            targetContact?.verified == false
                ? 'Verify this friend in Contacts to reconnect.'
                : relayNetwork != null &&
                      !relayNetwork!.enabled &&
                      canScanRelayQr
                ? 'Scan the other device\'s relay QR to connect.'
                : relayNetwork?.enabled == true
                ? 'Reconnecting. Keep both apps online.'
                : !kIsWeb && bridge.supportsAutomaticContact
                ? 'Connect through USB or add an internet relay.'
                : 'Ask your friend to open chta, then reconnect.',
          ),
          if (error != null) ...[
            const SizedBox(height: 12),
            Text(
              error!,
              key: const Key('connection-error'),
              style: const TextStyle(color: Colors.redAccent),
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  key: const Key('connect-to-chat'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    iconSize: 18,
                  ),
                  onPressed:
                      working ||
                          targetContact == null ||
                          !targetContact!.verified
                      ? null
                      : bridge.supportsAutomaticContact ||
                            relayNetwork?.enabled == true
                      ? () => _connectAutomatically(force: true)
                      : () => setState(() {
                          flow = ConnectionFlow.choose;
                          error = null;
                          technicalError = null;
                          showConnectionModal = true;
                        }),
                  icon: working
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.hub_outlined),
                  label: Text(working ? 'Connecting?' : 'Reconnect'),
                ),
              ),
              if (canScanRelayQr) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('scan-relay-from-chat'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      iconSize: 18,
                    ),
                    onPressed: readingRelayQr ? null : () => _readRelayQr(),
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('Scan QR'),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    ),
  );

  Widget _connectionModal() => Stack(
    children: [
      const ModalBarrier(dismissible: false, color: Colors.black54),
      Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720, maxHeight: 720),
          child: Dialog(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Connect with ${targetContact?.displayName ?? 'friend'}',
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      IconButton(
                        key: const Key('close-connect-modal'),
                        onPressed: working
                            ? null
                            : () => setState(() => showConnectionModal = false),
                        tooltip: 'Close',
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(20),
                    children: [
                      _statusCard(),
                      const SizedBox(height: 12),
                      switch (flow) {
                        ConnectionFlow.choose => _chooseFlow(),
                        ConnectionFlow.invite => _inviteFlow(),
                        ConnectionFlow.join => _joinFlow(),
                      },
                      if (error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                            error!,
                            key: const Key('connection-error'),
                            style: const TextStyle(color: Colors.redAccent),
                          ),
                        ),
                      const SizedBox(height: 20),
                      _advancedSettings(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ],
  );

  Future<void> _addRelay() async {
    try {
      await relayNetwork!.importList(relayAddress.text);
      if (!mounted) return;
      relayAddress.clear();
      setState(() => relayError = null);
      await bridge.close();
      await _connectAutomatically(force: true);
    } catch (caught) {
      if (mounted) setState(() => relayError = '$caught');
    }
  }

  Future<void> _readRelayQr({bool image = false}) async {
    if (readingRelayQr) return;
    setState(() {
      readingRelayQr = true;
      relayError = null;
    });
    try {
      final source = image
          ? await (widget.readRelayQrImage ?? readContactQrImage)()
          : await (widget.scanRelayQr?.call() ??
                scanQr(
                  context,
                  title: 'Scan QR',
                  fallbackText: 'Import a contact or relay QR image.',
                ));
      if (source == null || !mounted) return;
      if (source.length > 16384) {
        throw const FormatException('QR is too large.');
      }
      final selected = widget.targetContactId;
      List<String> routes;
      if (source.trimLeft().startsWith('{')) {
        final inspected = await widget.accountBridge.inspectContactCard(
          source.trim(),
        );
        if (!mounted || selected != widget.targetContactId) return;
        if (selected != null && inspected.identityId != selected) {
          throw const FormatException(
            'This QR belongs to a different friend. Open Contacts to add them.',
          );
        }
        final identity = await widget.accountBridge.identity();
        if (identity.id == inspected.identityId) {
          throw const FormatException('This is your own contact QR.');
        }
        final saved = await widget.accountBridge.contacts();
        final existing = saved
            .where((c) => c.identityId == inspected.identityId)
            .firstOrNull;
        if (existing?.verified != true) {
          if (!mounted) return;
          final name = await _confirmFingerprint(inspected, existing);
          if (name == null || !mounted || selected != widget.targetContactId) {
            return;
          }
          if (existing == null) {
            await widget.accountBridge.addContact(source.trim(), name);
          }
          await widget.accountBridge.markContactVerified(inspected.identityId);
        }
        await _refreshPeerContacts();
        routes = inspected.relayUrls.isEmpty
            ? []
            : await relayRoutesFromQr(source, widget.accountBridge);
      } else {
        routes = await relayRoutesFromQr(source, widget.accountBridge);
      }
      if (!mounted || selected != widget.targetContactId) return;
      if (routes.isNotEmpty) {
        if (relayNetwork == null) {
          throw const FormatException(
            'Relay connections are unavailable on this device.',
          );
        }
        await relayNetwork!.addContactRoutes(routes);
      }
      if (!mounted) return;
      if (!authenticated) await _connectAutomatically(force: true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              routes.isEmpty
                  ? 'Contact verified. Reconnecting…'
                  : 'Relay added. Connecting…',
            ),
          ),
        );
      }
    } catch (caught) {
      if (mounted) {
        setState(
          () => relayError = caught is FormatException
              ? caught.message
              : 'Could not read relay QR. Try another QR.',
        );
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(relayError!)));
      }
    } finally {
      if (mounted) setState(() => readingRelayQr = false);
    }
  }

  Widget _relaySettings() {
    final network = relayNetwork;
    if (network == null) return const SizedBox.shrink();
    final urls = <String>{
      ...network.seeds,
      ...network.records.values.map((r) => r['endpoint'] as String),
      ...network.userLockedRelays,
    };
    return Card(
      key: const Key('relay-network-settings'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (relayHost case final RelayHost host) ...[
              SwitchListTile(
                key: const Key('enable-public-relay'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Public relay through TryCloudflare'),
                subtitle: Text(
                  host.working
                      ? 'Starting relay…'
                      : host.running
                      ? 'Online. Starts after sign-in.'
                      : 'Let others connect through this computer.',
                ),
                value: host.enabled,
                onChanged: (enabled) => enabled
                    ? unawaited(_startPublicRelay())
                    : unawaited(_stopPublicRelay()),
              ),
              if (host.working) const LinearProgressIndicator(),
              if (host.running && host.endpoint != null)
                RelayQrRow(endpoint: host.endpoint!),
              if (host.error case final String message)
                Text(message, style: const TextStyle(color: Colors.redAccent)),
              const Text('Keep chta open and unlocked to host.'),
              const Divider(height: 24),
            ],
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                network.online.isEmpty
                    ? Icons.cloud_off_outlined
                    : Icons.cloud_done_outlined,
              ),
              title: const Text('Relays'),
              subtitle: Text(
                '${network.online.length}/${network.connectionLimit} online · ${network.connectingCount} connecting · ${urls.length} saved',
              ),
            ),
            if (relayHost?.running != true && shareableRelay != null)
              RelayQrRow(endpoint: shareableRelay!),
            if (!network.enabled)
              Text(
                canScanRelayQr
                    ? 'Scan the other device\'s relay QR to connect.'
                    : 'Enable public relay to share a QR.',
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (canScanRelayQr)
                  FilledButton.icon(
                    key: const Key('scan-relay-qr'),
                    onPressed: readingRelayQr ? null : () => _readRelayQr(),
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('Scan relay QR'),
                  ),
                if (supportsContactQrImageImport ||
                    widget.readRelayQrImage != null)
                  OutlinedButton.icon(
                    key: const Key('import-relay-qr'),
                    onPressed: readingRelayQr
                        ? null
                        : () => _readRelayQr(image: true),
                    icon: const Icon(Icons.image_search_outlined),
                    label: const Text('Import relay QR'),
                  ),
              ],
            ),
            if (readingRelayQr) const LinearProgressIndicator(),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 230,
                  child: TextField(
                    key: const Key('relay-connection-limit'),
                    controller: relayConnectionLimit,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: 'Relay limit (50 to 1000)',
                    ),
                  ),
                ),
                FilledButton(
                  key: const Key('apply-relay-limit'),
                  onPressed: () async {
                    try {
                      await network.setConnectionLimit(
                        int.tryParse(relayConnectionLimit.text) ?? 0,
                      );
                      if (mounted) setState(() => relayError = null);
                    } catch (caught) {
                      if (mounted) setState(() => relayError = '$caught');
                    }
                  },
                  child: const Text('Apply'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text('More connections use more data and battery.'),
            const SizedBox(height: 12),
            TextField(
              controller: relayAddress,
              key: const Key('relay-address'),
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Relay URL or list',
                hintText: 'https://name.trycloudflare.com',
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  key: const Key('add-relay'),
                  onPressed: _addRelay,
                  icon: const Icon(Icons.add_link),
                  label: const Text('Add relay'),
                ),
                OutlinedButton.icon(
                  onPressed: network.records.isEmpty
                      ? null
                      : () async {
                          await Clipboard.setData(
                            ClipboardData(text: network.exportList()),
                          );
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Relay list copied.'),
                              ),
                            );
                          }
                        },
                  icon: const Icon(Icons.share_outlined),
                  label: const Text('Share relay list'),
                ),
              ],
            ),
            if (relayError ?? network.error case final String message)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  message,
                  style: const TextStyle(color: Colors.redAccent),
                ),
              ),
            for (final url in urls.take(relayRowsShown))
              _relayEntry(network, url),
            if (urls.length > relayRowsShown)
              TextButton(
                onPressed: () => setState(() => relayRowsShown += 20),
                child: Text(
                  'Show more (${urls.length - relayRowsShown} remaining)',
                ),
              ),
            const SizedBox(height: 8),
            const Text('Keep two relays for backup. Both apps must stay open.'),
          ],
        ),
      ),
    );
  }

  String _relayDate(int? milliseconds) {
    if (milliseconds == null) return '—';
    final date = DateTime.fromMillisecondsSinceEpoch(milliseconds);
    String two(int value) => value.toString().padLeft(2, '0');
    return '${date.year.toString().padLeft(4, '0')}-${two(date.month)}-${two(date.day)} '
        '${two(date.hour)}:${two(date.minute)}:${two(date.second)}';
  }

  Widget _relayEntry(RelayNetwork network, String endpoint) {
    final activity = network.activityFor(endpoint);
    final locked = network.isRelayLocked(endpoint);
    final (label, color, icon) = switch (network.statusFor(endpoint)) {
      RelayConnectionStatus.online => (
        'Online',
        Colors.green,
        Icons.check_circle_outline,
      ),
      RelayConnectionStatus.connecting => (
        'Connecting',
        Colors.orange,
        Icons.sync,
      ),
      RelayConnectionStatus.unavailable => (
        'Unavailable',
        Theme.of(context).colorScheme.error,
        Icons.error_outline,
      ),
      RelayConnectionStatus.disconnected => (
        'Not connected',
        Theme.of(context).colorScheme.onSurfaceVariant,
        Icons.radio_button_unchecked,
      ),
    };
    final status = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 16),
        const SizedBox(width: 6),
        Flexible(
          child: Text(label, style: TextStyle(color: color)),
        ),
      ],
    );
    final remove = IconButton(
      tooltip: 'Remove saved address',
      icon: const Icon(Icons.delete_outline),
      onPressed: () => network.forget(endpoint),
    );
    final keep = IconButton(
      key: Key('relay-lock-$endpoint'),
      tooltip: locked ? 'Allow automatic removal' : 'Keep relay',
      icon: Icon(locked ? Icons.lock_outline : Icons.lock_open_outlined),
      onPressed: () => unawaited(network.setRelayLocked(endpoint, !locked)),
    );
    Widget date(String label, int? value, {bool inline = false}) {
      final text = Text(_relayDate(value));
      return inline
          ? Row(
              children: [
                SizedBox(width: 72, child: Text(label)),
                Flexible(child: text),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: Theme.of(context).textTheme.labelSmall),
                text,
              ],
            );
    }

    return Container(
      key: ValueKey('relay-entry-$endpoint'),
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: DefaultTextStyle.merge(
        style: Theme.of(context).textTheme.bodySmall,
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth >= 960) {
              return Row(
                children: [
                  Expanded(child: Text(endpoint)),
                  const SizedBox(width: 16),
                  SizedBox(width: 124, child: status),
                  keep,
                  SizedBox(
                    width: 150,
                    child: date('Added', activity.addedAtMilliseconds),
                  ),
                  SizedBox(
                    width: 150,
                    child: date('Updated', activity.updatedAtMilliseconds),
                  ),
                  SizedBox(
                    width: 150,
                    child: date('Last used', activity.lastUsedAtMilliseconds),
                  ),
                  remove,
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(child: Text(endpoint)),
                    remove,
                  ],
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [status, keep],
                  ),
                ),
                const SizedBox(height: 8),
                date('Added', activity.addedAtMilliseconds, inline: true),
                date('Updated', activity.updatedAtMilliseconds, inline: true),
                date(
                  'Last used',
                  activity.lastUsedAtMilliseconds,
                  inline: true,
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  EdgeInsets get _connectPadding => EdgeInsets.symmetric(
    horizontal: MediaQuery.sizeOf(context).width < 600 ? 8 : 12,
    vertical: 12,
  );

  Widget _relayNetworkPage() => Scaffold(
    appBar: AppBar(title: const Text('Connect')),
    body: ListView(padding: _connectPadding, children: [_relaySettings()]),
  );

  Widget _nativeListenerPage() {
    final status = nativeListener;
    final listening = status?.listening ?? false;
    return Scaffold(
      appBar: AppBar(title: const Text('Node service')),
      body: ListView(
        padding: _connectPadding,
        children: [
          _relaySettings(),
          const SizedBox(height: 12),
          Card(
            color: listening ? const Color(0xFF172116) : null,
            child: ListTile(
              leading: Icon(
                listening ? Icons.wifi_tethering : Icons.wifi_tethering_off,
              ),
              title: Text(listening ? 'Listening' : 'Not listening'),
              subtitle: Text(
                listening
                    ? 'Visible on your local network.'
                    : 'Let nearby nodes find this computer.',
              ),
            ),
          ),
          const SizedBox(height: 20),
          if (!listening) ...[
            const Text(
              'Make this node available',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 20),
            TextField(
              key: const Key('listener-port'),
              controller: listenerPort,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Listening port',
                helperText: '0 = automatic',
                prefixIcon: Icon(Icons.settings_ethernet),
              ),
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              key: const Key('listener-use-pin'),
              contentPadding: EdgeInsets.zero,
              value: useListenerPin,
              onChanged: working
                  ? null
                  : (value) => setState(() {
                      useListenerPin = value;
                      if (value) allowRelay = false;
                    }),
              title: const Text('Require a PIN'),
              subtitle: const Text('A PIN disables public relaying.'),
            ),
            if (useListenerPin) ...[
              const SizedBox(height: 8),
              TextField(
                key: const Key('listener-pin'),
                controller: listenerPin,
                obscureText: true,
                maxLength: 64,
                decoration: const InputDecoration(
                  labelText: 'PIN',
                  prefixIcon: Icon(Icons.pin_outlined),
                ),
              ),
            ],
            SwitchListTile(
              key: const Key('listener-allow-relay'),
              contentPadding: EdgeInsets.zero,
              value: allowRelay && !useListenerPin,
              onChanged: working || useListenerPin
                  ? null
                  : (value) => setState(() => allowRelay = value),
              title: const Text('Relay for others'),
              subtitle: const Text('Messages stay end-to-end encrypted.'),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const Key('start-listening'),
              onPressed: working ? null : _startNativeListener,
              icon: const Icon(Icons.play_arrow),
              label: Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Text(working ? 'Starting…' : 'Start listening'),
              ),
            ),
          ] else ...[
            ExpansionTile(
              key: const Key('node-details'),
              tilePadding: EdgeInsets.zero,
              title: const Text('Node details'),
              children: [
                SelectableText('Peer ID\n${status!.peerId}'),
                const SizedBox(height: 16),
                const Text(
                  'Listening addresses',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                for (final address in status.addresses)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.lan_outlined),
                    title: SelectableText(address),
                    trailing: IconButton(
                      tooltip: 'Copy address',
                      onPressed: () =>
                          Clipboard.setData(ClipboardData(text: address)),
                      icon: const Icon(Icons.copy_outlined),
                    ),
                  ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    status.relayEnabled ? Icons.route_outlined : Icons.block,
                  ),
                  title: Text(
                    status.relayEnabled
                        ? 'Relay on'
                        : status.pinRequired
                        ? 'PIN-protected mode'
                        : 'Relay off',
                  ),
                  subtitle: Text(
                    '${status.discoveredNodes.length} node(s) discovered on the local network',
                  ),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    status.gatewayConnected
                        ? Icons.language
                        : Icons.language_outlined,
                  ),
                  title: Text(
                    status.gatewayConnected
                        ? 'Browser connected'
                        : 'Browser connection ready',
                  ),
                  subtitle: Text(
                    'Local automatic connection: ws://127.0.0.1:${status.gatewayPort}',
                  ),
                ),
                if (status.discoveredNodes.isNotEmpty) ...[
                  const Divider(height: 28),
                  const Text(
                    'Discovered nodes',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                  ),
                  for (final node in status.discoveredNodes)
                    ListTile(
                      leading: const Icon(Icons.hub_outlined),
                      title: Text(node.peerId),
                      subtitle: Text(node.address),
                    ),
                ],
              ],
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              key: const Key('stop-listening'),
              onPressed: working ? null : _stopNativeListener,
              icon: const Icon(Icons.stop),
              label: const Text('Stop listening'),
            ),
          ],
          if (status?.error case final listenerError?) ...[
            const SizedBox(height: 12),
            Text(
              listenerError,
              style: const TextStyle(color: Colors.redAccent),
            ),
          ],
          if (error != null) ...[
            const SizedBox(height: 12),
            Text(
              error!,
              key: const Key('connection-error'),
              style: const TextStyle(color: Colors.redAccent),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) =>
      !kIsWeb &&
          bridge.supportsAutomaticContact &&
          !widget.chatMode &&
          widget.targetContactId == null
      ? _relayNetworkPage()
      : bridge.supportsListening && !widget.chatMode
      ? _nativeListenerPage()
      : widget.chatMode
      ? Scaffold(
          body: SafeArea(
            child: Stack(
              children: [
                _secureChatLayout(),
                if (showConnectionModal) _connectionModal(),
              ],
            ),
          ),
        )
      : Scaffold(
          appBar: AppBar(
            title: Text(
              targetContact == null
                  ? 'Connect'
                  : widget.chatMode
                  ? 'Chat with ${targetContact!.displayName}'
                  : 'Connect with ${targetContact!.displayName}',
            ),
          ),
          body: ListView(
            padding: _connectPadding,
            children: [
              _relaySettings(),
              const SizedBox(height: 12),
              if (relayNetwork?.enabled == true)
                const Card(
                  child: ListTile(
                    leading: Icon(Icons.people_outline),
                    title: Text('Ready for internet chat'),
                    subtitle: Text('Choose a friend in Contacts to chat.'),
                  ),
                )
              else ...[
                _statusCard(),
                const SizedBox(height: 12),
                switch (flow) {
                  ConnectionFlow.choose => _chooseFlow(),
                  ConnectionFlow.invite => _inviteFlow(),
                  ConnectionFlow.join => _joinFlow(),
                },
              ],
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    error!,
                    key: const Key('connection-error'),
                    style: const TextStyle(color: Colors.redAccent),
                  ),
                ),
              if (authenticated) ...[
                const Divider(height: 32),
                const Text('Opening chat…', textAlign: TextAlign.center),
              ],
              const SizedBox(height: 20),
              _advancedSettings(),
            ],
          ),
        );
}
