import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../account/account_bridge.dart';
import '../account/account_models.dart';
import '../delivery/delivery_router.dart';
import '../delivery/gap_repair.dart';
import '../delivery/peer_gap_repair.dart';
import '../delivery/local_diagnostics.dart';
import '../delivery/courier_delivery_adapter.dart';
import '../delivery/delivery_envelope.dart';
import '../p2p/direct_file_link.dart';
import '../p2p/peer_file_controller.dart';
import '../p2p/p2p_bridge.dart';
import '../relay/relay_chat.dart';
import '../relay/relay_network.dart';
import '../relay/relay_peer_sync.dart';
import '../seed/seed_client.dart';
import '../runtime/network_monitor.dart';
import '../runtime/network_recovery.dart';
import 'attachment_transfer.dart';
import 'chat_attachment.dart';
import 'chunked_attachment_bridge.dart';
import 'durable_outbox.dart';
import 'delivery_feedback.dart';
import 'peer_history.dart';
import 'resumable_attachment_transfer.dart';
import 'account_scheduler.dart';
import 'file_transfer_progress.dart';

/// One unlocked account's transport lifetime. Navigation never selects or tears
/// down a remote peer's authenticated state.
class MessagingService extends ChangeNotifier {
  MessagingService({
    required this.ownerId,
    required this.account,
    required this.network,
    required this.history,
    required this.ownCard,
    this.seed,
    this.cache,
    this.peerFactory,
    this.courier,
    NetworkMonitor? networkMonitor,
    bool observeNetwork = true,
  }) : _monitor = observeNetwork
           ? networkMonitor ?? createNetworkMonitor()
           : null {
    outbox = DurableOutbox(
      ownerId: ownerId,
      history: history,
      isReady: (peer) => isOnline(peer) || courier?.canQueue(peer) == true,
      send: _sendQueued,
    );
    _recovery = NetworkRecovery(
      isCurrent: () => _active && _started,
      recover: recoverNetwork,
    );
    _scheduler = AccountScheduler(hasWork: _hasWork, tick: _poll);
  }
  final String ownerId;
  final AccountBridge account;
  final RelayNetwork network;
  final PeerHistory history;
  final Future<String> Function() ownCard;
  final SeedClient? seed;
  final ChunkedAttachmentBridge? cache;
  final DirectPeerFactory? peerFactory;
  final CourierDeliveryAdapter? courier;
  final NetworkMonitor? _monitor;
  late final NetworkRecovery _recovery;
  StreamSubscription<NetworkObservation>? _networkChanges;
  Future<void>? _recovering;
  NetworkObservation? _lastNetwork;
  bool _pathChanged = false;
  late final DurableOutbox outbox;
  final _peers = <String, _PeerConnection>{};
  final _contacts = <String, ContactView>{};
  late final AccountScheduler _scheduler;
  StreamSubscription<SeedVerifiedSignal>? _signals;
  bool _closed = false, _started = false, _polling = false;
  Object? error;
  bool get _active => !_closed && history.ownerId == ownerId;
  Set<String> get onlinePeers => {
    for (final id in _peers.keys)
      if (isOnline(id)) id,
  };
  bool isOnline(String peer) =>
      _active &&
      (_peers[peer]?.relay.authenticated == true ||
          _peers[peer]?.files?.ready == true);
  RelayChat? relayFor(String? peer) => _peers[peer]?.relay;
  PeerFileController? filesFor(String? peer) => _peers[peer]?.files;
  Map<String, double> incomingProgressFor(String? peer) => {
    ...?_peers[peer]?.incomingProgress,
    ...?courier?.incomingFor(peer),
  };
  Map<String, double> outgoingProgressFor(String? peer) =>
      _peers[peer]?.outgoingProgress ?? const {};

  Future<void> start() async {
    if (_started || !_active) return;
    _started = true;
    _networkChanges = _monitor?.changes.listen(
      _observeNetwork,
      onError: (Object _) {},
    );
    await network.initialize();
    if (!_active) return;
    network.addListener(_changed);
    network.addFrameListener(_incomingRoute);
    seed?.addListener(_changed);
    _signals = seed?.signals.listen((signal) {
      if (!_active) return;
      final peer = _peers[signal.peerId];
      if (peer != null) {
        unawaited(
          peer.files
              ?.receiveSeedControl(
                signal.messageId,
                signal.text,
                peer: signal.peerId,
              )
              .catchError((Object _) {}),
        );
      }
    });
    await refreshContacts();
    if (!_active) return;
    if (seed != null) await seed!.start(ownerId);
    if (courier != null) {
      courier!.addListener(_changed);
      try {
        await courier!.start();
      } catch (caught) {
        error = caught;
      }
    }
    _scheduler.request();
    await _poll();
  }

  bool _hasWork() =>
      _active &&
      (history.queuedMessages.any(
            (e) =>
                !e.value.deliveryPaused &&
                (isOnline(e.key) || courier?.canQueue(e.key) == true),
          ) ||
          _peers.values.any(
            (p) =>
                p.incomingProgress.isNotEmpty ||
                p.files?.progress.values.any(
                      (progress) =>
                          progress.phase == FileTransferPhase.preparing ||
                          progress.phase == FileTransferPhase.sending ||
                          progress.phase == FileTransferPhase.receiving ||
                          progress.phase == FileTransferPhase.verifying,
                    ) ==
                    true,
          ));

  Future<void> resumeNetwork() async {
    if (!_active) return;
    final observation = await _monitor?.check();
    if (!_active) return;
    if (observation != null) _observeNetwork(observation);
    _recovery.resume();
  }

  void _observeNetwork(NetworkObservation state) {
    final before = _lastNetwork;
    if (before != null &&
        state.available &&
        (!before.available || before.fingerprint != state.fingerprint)) {
      _pathChanged = true;
    }
    _lastNetwork = state;
    _recovery.observe(state);
  }

  Future<void> recoverNetwork() =>
      _recovering ??= _recoverNetwork().whenComplete(() => _recovering = null);
  Future<void> _recoverNetwork() async {
    if (!_active || (await account.identity()).id != ownerId || !_active) {
      return;
    }
    final changed = _pathChanged;
    _pathChanged = false;
    await network.recoverNetwork(force: changed);
    if (!_active) return;
    if (changed || seed?.needsRecovery == true) await seed?.recoverNetwork();
    if (!_active) return;
    final peers = _peers.values.toList();
    for (var start = 0; start < peers.length && _active; start += 6) {
      final end = (start + 6).clamp(0, peers.length);
      await Future.wait(
        peers.sublist(start, end).map((peer) async {
          if (!_owns(peer)) return;
          try {
            if (changed || peer.files?.ready != true) {
              await peer.files?.recoverNetwork();
            }
          } catch (_) {
            /* Normal signaling retries remain active. */
          }
          if (_owns(peer)) outbox.retryNow(peer.contact.identityId);
        }),
      );
    }
    if (_active) _changed();
  }

  Future<void> refreshContacts() async {
    final contacts = await account.contacts();
    if (!_active) return;
    _contacts
      ..clear()
      ..addEntries(
        contacts
            .where((c) => c.verified && c.identityId != ownerId)
            .map((c) => MapEntry(c.identityId, c)),
      );
    history.rememberContacts(contacts);
    for (final id in _peers.keys.toList()) {
      if (!_contacts.containsKey(id)) {
        final p = _peers.remove(id);
        await p?.close();
      }
    }
    for (final contact in _contacts.values.take(128)) {
      _ensurePeer(contact);
    }
    _changed();
  }

  _PeerConnection _ensurePeer(ContactView contact) {
    final existing = _peers[contact.identityId];
    if (existing != null) {
      existing.contact = contact;
      return existing;
    }
    if (!_active ||
        !contact.verified ||
        !_contacts.containsKey(contact.identityId)) {
      throw StateError('Verify friend first');
    }
    final id = contact.identityId;
    final relay = RelayChat(
      account,
      network,
      ownCard: ownCard,
      ownsNetwork: false,
      boundPeer: id,
      automaticTicks: false,
      onEvents: _schedulePoll,
    );
    final peer = _PeerConnection(
      contact,
      relay,
      DeliveryRouter(
        onMetric: (metric) => courier?.service.diagnostics.count(metric),
      ),
    );
    _peers[id] = peer;
    peer.sync = RelayPeerSync(network, send: relay.sendControl);
    peer.attachments = AttachmentTransfer(
      maxTransferBytes: () => ChatAttachment.relayMaxBytes,
      sendPacket: (packet, text, sentAt) =>
          _sendPacket(peer, packet, text, sentAt),
      onProgress: (transfer, progress, incoming) {
        if (!_owns(peer)) return;
        if (!incoming &&
            history
                .messagesFor(id)
                .any(
                  (m) =>
                      m.id == transfer && m.status == DeliveryStatus.delivered,
                )) {
          return;
        }
        (incoming ? peer.incomingProgress : peer.outgoingProgress)[transfer] =
            progress;
        _notify();
      },
      onReceived: (transfer, attachment, sentAt, receivedAt) async {
        if (!_owns(peer)) throw const TransferInterrupted();
        try {
          await history.addAttachment(
            id,
            PeerMessage(
              id: transfer,
              text: attachment.previewLabel,
              incoming: true,
              status: DeliveryStatus.delivered,
              attachment: attachment,
              sentAtMilliseconds: sentAt,
              receivedAtMilliseconds: receivedAt,
            ),
          );
          await _durable(peer);
        } finally {
          if (_owns(peer)) {
            peer.incomingProgress.remove(transfer);
            _notify();
          }
        }
      },
    );
    if (cache != null) {
      peer.files = PeerFileController(
        ownerId: ownerId,
        cache: cache!,
        history: history,
        autoResume: false,
        automaticRetries: false,
        sendEncryptedControl: relay.sendControl,
        sendSeedControl: seed == null
            ? null
            : (packet, text) => seed!.sendPeerSignal(id, packet, text),
        sendFallbackPacket: (packet, text, sentAt) => relay.sendMessage(
          packet,
          text,
          sentAt,
          isCurrent: () => _owns(peer) && _filePacketCurrent(peer, text),
        ),
        onPacket: (packet, text, sentAt) => _receive(
          peer,
          PeerEvent(
            type: 'message',
            messageId: packet,
            text: text,
            sentAtMilliseconds: sentAt,
          ),
          direct: true,
        ),
        onReceipt: (packet, receivedAt) {
          if (!_owns(peer)) return;
          if (AttachmentTransfer.isPacketId(packet)) {
            peer.attachments!.acknowledge(
              packet,
              receivedAtMilliseconds: receivedAt,
            );
          } else {
            peer.router.acknowledge(packet, routeId: 'direct');
            unawaited(_recordDelivery(id, packet, receivedAt));
          }
        },
        onChanged: _changed,
        peerFactory: peerFactory,
      );
    }
    relay.select(id);
    return peer;
  }

  bool _owns(_PeerConnection peer) =>
      _active &&
      identical(_peers[peer.contact.identityId], peer) &&
      _contacts.containsKey(peer.contact.identityId);
  void _incomingRoute(String endpoint, Map<String, dynamic> frame) {
    if (!_active || frame['type'] != 'route') return;
    if (frame['body'] is Map &&
        (frame['body'] as Map)['type'] == 'courier-v1') {
      return;
    }
    final contact = _contacts[frame['from']];
    if (contact != null && !_peers.containsKey(contact.identityId)) {
      final peer = _ensurePeer(contact);
      peer.relay.acceptFrame(endpoint, frame);
    }
  }

  Future<void> reconnect(String id) async {
    await refreshContacts();
    final contact = _contacts[id];
    if (contact == null) return;
    final peer = _ensurePeer(contact);
    if (!peer.relay.authenticated) peer.relay.select(id);
    await network.tick();
    await _updateFiles(peer);
    outbox.retryNow(id);
    _notify();
  }

  void cancelConversation(String id) {
    final peer = _peers.remove(id);
    if (peer != null) unawaited(peer.close());
  }

  Future<void> pauseFile(String peer, String id) =>
      _stopFile(peer, id, cancel: false);
  Future<void> cancelFile(String peer, String id) =>
      _stopFile(peer, id, cancel: true);
  Future<void> _stopFile(
    String peerId,
    String id, {
    required bool cancel,
  }) async {
    final peer = _peers[peerId];
    final message = history
        .messagesFor(peerId)
        .where((m) => m.id == id)
        .firstOrNull;
    if (!_active ||
        peer == null ||
        message == null ||
        !message.hasAttachment ||
        message.status == DeliveryStatus.delivered) {
      return;
    }
    message.deliveryPaused = true;
    if (cancel) {
      message.queuedForDelivery = false;
      message.status = DeliveryStatus.failed;
      message.failureReason = 'Cancelled';
    }
    peer.attachments?.interrupt(id);
    peer.files?.interruptTransfer(id);
    peer.relay.cancelPendingWhere(
      (packet) =>
          packet.startsWith('chtatt1_${id}_') ||
          packet.startsWith('${ResumableAttachmentTransfer.prefix}${id}_'),
    );
    peer.incomingProgress.remove(id);
    peer.outgoingProgress.remove(id);
    history.changed(peerId);
    await history.flush();
    if (history.error != null) throw StateError('Could not save file state');
    await courier?.pause(peerId, message, cancel: cancel);
    if (_active) _changed();
  }

  Future<void> resumeFile(String peerId, String id) async {
    final message = history
        .messagesFor(peerId)
        .where((m) => m.id == id)
        .firstOrNull;
    if (!_active ||
        message == null ||
        !message.hasAttachment ||
        message.status == DeliveryStatus.delivered) {
      return;
    }
    if (message.incoming) {
      if (message.failureReason == 'Cancelled') return;
      message.deliveryPaused = false;
      message.failureReason = null;
      message.status = DeliveryStatus.pending;
      history.changed(peerId);
      await history.flush();
      if (history.error != null) throw StateError('Could not save file state');
    } else {
      await outbox.enqueue(peerId, message);
    }
    if (_active) _changed();
  }

  Future<void> queueText(String peer, String text, {String? id}) async {
    if (text.trim().isEmpty) throw const FormatException('Enter a message.');
    final attachment = RelayChat.messageFits(text)
        ? null
        : ChatAttachment.longMessage(text);
    if (!_contacts.containsKey(peer)) await refreshContacts();
    final contact = _contacts[peer];
    if (contact == null) throw StateError('Verify friend first');
    _ensurePeer(contact);
    await outbox.enqueue(
      peer,
      PeerMessage(
        id: id ?? 'p2p-${RelayChat.randomId()}',
        text: attachment?.previewLabel ?? text,
        incoming: false,
        status: DeliveryStatus.pending,
        attachment: attachment,
      ),
    );
    _notify();
  }

  Future<void> queueMessage(String peer, PeerMessage message) async {
    if (!message.hasAttachment) validateOutgoingText(message.text);
    if (!_contacts.containsKey(peer)) await refreshContacts();
    final contact = _contacts[peer];
    if (contact == null) throw StateError('Verify friend first');
    _ensurePeer(contact);
    await outbox.enqueue(peer, message);
    _notify();
  }

  Future<void> queueBatch(String peer, List<PeerMessage> messages) async {
    if (!_contacts.containsKey(peer)) await refreshContacts();
    final contact = _contacts[peer];
    if (contact == null) throw StateError('Verify friend first');
    _ensurePeer(contact);
    for (final message in messages) {
      if (message.incoming || !message.hasAttachment) {
        throw ArgumentError('Outgoing attachments required');
      }
      message.queuedForDelivery = true;
    }
    await history.addAttachments(peer, messages);
    await history.flush();
    if (!_active || history.error != null) {
      throw StateError('Could not save files');
    }
    outbox.pump();
    _notify();
  }

  void _notify() {
    if (!_closed) notifyListeners();
  }

  void _changed() {
    if (!_active) return;
    _schedulePoll();
    _notify();
  }

  void _schedulePoll() {
    if (_active && _started) _scheduler.request();
  }

  Future<void> _updateFiles(_PeerConnection peer) async {
    if (!_owns(peer)) return;
    await peer.files?.updatePeer(
      peer.contact,
      encryptedAuthenticated: peer.relay.authenticated,
      seedSignalingAvailable: seed?.registered == true,
    );
    peer.sync?.updateSession(
      peer.contact.identityId,
      authenticated: peer.relay.authenticated,
    );
    _updateRepair(peer);
  }

  void _updateRepair(_PeerConnection peer) {
    final adapter = courier, id = peer.contact.identityId;
    if (adapter == null ||
        !_owns(peer) ||
        !isOnline(id) ||
        !peer.contact.capabilities.contains('delivery-v2')) {
      peer.repair?.close();
      peer.repair = null;
      peer.nextRepair = 0;
      return;
    }
    final repair = PeerGapRepair(sink: adapter.sink, peer: id);
    final cursor = ProtectedGapCursor(adapter.service.storage, ownerId, id);
    final engine = peer.repair ??= GapRepair(
      send: (frame) async {
        final packet = '$gapRepairControlId-${RelayChat.randomId()}';
        if (peer.relay.authenticated) {
          await peer.relay.sendControl(packet, frame);
        } else if (peer.files?.ready == true) {
          await peer.files!.sendDirectPacket(packet, frame, null);
        } else {
          throw StateError('Repair route closed');
        }
      },
      authorize: (scope) async =>
          _owns(peer) && isOnline(id) && repair.active && scope == repair.scope,
      records: (_) => repair.rows(),
      contains: (_, id) => repair.contains(id),
      commit: (_, row) async {
        await repair.commit(row);
        if (repair.contains(row.id)) {
          adapter.service.diagnostics.count(DeliveryMetric.repaired);
        }
      },
      checkpoint: cursor.checkpoint,
      resume: cursor.resume,
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now >= peer.nextRepair) {
      peer.nextRepair = now + 30000;
      unawaited(engine.offer(repair.scope).catchError((Object _) {}));
    }
  }

  Future<void> _poll() async {
    if (!_active || _polling) return;
    _polling = true;
    try {
      if ((await account.identity()).id != ownerId) {
        await close();
        return;
      }
      for (final peer in _peers.values.toList()) {
        if (!_owns(peer)) continue;
        unawaited(peer.relay.tick());
        if (!peer.binding) {
          peer.binding = true;
          unawaited(
            _updateFiles(peer)
                .catchError((Object caught) {
                  error = caught;
                })
                .whenComplete(() => peer.binding = false),
          );
        }
        if (!peer.polling) unawaited(_pollPeer(peer));
      }
      outbox.pump();
    } catch (caught) {
      error = caught;
      _notify();
    } finally {
      _polling = false;
    }
  }

  Future<void> _pollPeer(_PeerConnection peer) async {
    peer.polling = true;
    final generation = history.conversationGeneration(peer.contact.identityId);
    var changed = false;
    try {
      for (final event in peer.relay.drainEvents()) {
        changed = true;
        if (!_owns(peer) ||
            generation !=
                history.conversationGeneration(peer.contact.identityId)) {
          break;
        }
        try {
          await _receive(peer, event);
        } catch (caught) {
          error = caught;
        }
      }
    } finally {
      peer.polling = false;
      if (changed) _notify();
      if (_owns(peer) && peer.relay.events.isNotEmpty) _schedulePoll();
    }
  }

  Future<void> _durable(_PeerConnection peer) async {
    await history.flush();
    if (!_owns(peer) || history.error != null) {
      throw const TransferInterrupted('Could not save received message');
    }
  }

  Future<void> _receive(
    _PeerConnection peer,
    PeerEvent event, {
    bool direct = false,
  }) async {
    if (!_owns(peer)) return;
    final id = event.messageId;
    if (id == null) return;
    final peerId = peer.contact.identityId;
    if (event.type == 'delivered') {
      if (AttachmentTransfer.isPacketId(id)) {
        peer.attachments!.acknowledge(
          id,
          receivedAtMilliseconds: event.receivedAtMilliseconds,
        );
        return;
      }
      peer.router.acknowledge(id, routeId: direct ? 'direct' : 'relay');
      await _recordDelivery(
        peerId,
        id,
        event.receivedAtMilliseconds ?? DateTime.now().millisecondsSinceEpoch,
      );
      return;
    }
    if (event.type == 'sent') {
      history.setStatus(peerId, id, DeliveryStatus.sent);
      return;
    }
    if (event.type != 'message' && event.type != 'control') return;
    final text = event.text;
    if (text == null) return;
    if (id.startsWith('$gapRepairControlId-')) {
      if (direct || event.type == 'control') {
        if (peer.repair == null) _updateRepair(peer);
        await peer.repair?.receive(text);
      }
      return;
    }
    if (id.startsWith(DirectFileLink.controlPrefix)) {
      // SDP/plugin work has its own ordered signal queue. Waiting for it here
      // would hold ordinary relay messages behind slow ICE/remote description.
      unawaited(
        peer.files
            ?.receiveEncryptedControl(
              id,
              text,
              authenticated: peer.relay.authenticated,
              peer: peerId,
            )
            .catchError((Object caught) {
              if (_owns(peer)) error = caught;
            }),
      );
      return;
    }
    if (RelayPeerSync.isControlId(id)) {
      await peer.sync?.receive(id, text);
      return;
    }
    if (text.startsWith(deliveryWirePrefix)) {
      final receiver = courier;
      if (receiver == null) return;
      final received = await receiver.receiveLive(
        peerId,
        id,
        text,
        event.sentAtMilliseconds,
        event.receivedAtMilliseconds ?? DateTime.now().millisecondsSinceEpoch,
      );
      if (!_owns(peer)) return;
      if (direct) {
        await peer.files?.acknowledge(id, received);
      } else {
        await peer.relay.acknowledge(id, received);
      }
      return;
    }
    final existing = history
        .messagesFor(peerId)
        .where((m) => m.id == id)
        .firstOrNull;
    final receivedAt =
        existing?.receivedAtMilliseconds ??
        event.receivedAtMilliseconds ??
        DateTime.now().millisecondsSinceEpoch;
    if (ResumableAttachmentTransfer.isPacketId(id)) {
      if (peer.files == null) return;
      await peer.files!.receiveFilePacket(id, text, direct: direct);
    } else if (AttachmentTransfer.isPacketId(id)) {
      if (!await peer.attachments!.receive(
        id,
        text,
        event.sentAtMilliseconds,
        receivedAt,
      )) {
        return;
      }
    } else {
      final generation = history.conversationGeneration(peerId);
      if (existing == null) {
        history.add(
          peerId,
          PeerMessage(
            id: id,
            text: text,
            incoming: true,
            status: DeliveryStatus.delivered,
            sentAtMilliseconds: event.sentAtMilliseconds,
            receivedAtMilliseconds: receivedAt,
          ),
          expectedGeneration: generation,
        );
      } else if (history.error != null) {
        history.changed(peerId);
      }
    }
    await _durable(peer);
    if (direct) {
      await peer.files?.acknowledge(id, receivedAt);
    } else {
      await peer.relay.acknowledge(id, receivedAt);
    }
  }

  Future<void> _sendPacket(
    _PeerConnection peer,
    String id,
    String text,
    int sentAt,
  ) async {
    if (!_owns(peer) || (await account.identity()).id != ownerId) {
      throw const TransferInterrupted();
    }
    if (peer.attachments?.canSendPacket(id) != true) {
      throw const TransferInterrupted('Transfer paused');
    }
    if (peer.files?.ready == true) {
      await peer.files!.sendDirectPacket(id, text, sentAt);
    } else {
      await peer.relay.sendMessage(
        id,
        text,
        sentAt,
        isCurrent: () =>
            _owns(peer) && peer.attachments?.canSendPacket(id) == true,
      );
    }
  }

  bool _filePacketCurrent(_PeerConnection peer, String text) {
    try {
      final value = jsonDecode(text) as Map;
      if (!['offer', 'part', 'finish'].contains(value['type'])) return true;
      final message = history
          .messagesFor(peer.contact.identityId)
          .where((m) => m.id == value['id'] && !m.incoming)
          .firstOrNull;
      return message != null &&
          message.queuedForDelivery &&
          !message.deliveryPaused;
    } catch (_) {
      return false;
    }
  }

  Future<String> _sendTextWithFailover(
    _PeerConnection peer,
    PeerMessage message,
  ) async {
    if (!_owns(peer) || (await account.identity()).id != ownerId) {
      throw const TransferInterrupted();
    }
    final sentAt =
        message.sentAtMilliseconds ?? DateTime.now().millisecondsSinceEpoch;
    final text =
        await courier?.liveText(peer.contact.identityId, message) ??
        message.text;
    final chosen = await peer.router.send(message.id, [
      DeliveryRoute(
        id: 'direct',
        kind: DeliveryRouteKind.direct,
        authenticated: peer.files?.ready == true,
        send: () => peer.files!.sendDirectPacket(message.id, text, sentAt),
      ),
      DeliveryRoute(
        id: 'relay',
        kind: DeliveryRouteKind.relay,
        authenticated: peer.relay.authenticated,
        send: () => peer.relay.sendMessage(
          message.id,
          text,
          sentAt,
          isCurrent: () => _owns(peer) && message.queuedForDelivery,
        ),
      ),
      if (courier != null)
        DeliveryRoute(
          id: 'courier',
          kind: DeliveryRouteKind.courier,
          authenticated: courier!.canQueue(peer.contact.identityId),
          send: () => courier!.queue(peer.contact.identityId, message),
        ),
    ], isCurrent: () => _owns(peer) && message.queuedForDelivery);
    message.lastAttemptWasDirect =
        chosen == 'direct' && message.status != DeliveryStatus.delivered;
    return chosen;
  }

  Future<void> _sendQueued(String id, PeerMessage message) async {
    final peer = _peers[id];
    if (message.hasAttachment &&
        courier?.canQueue(id) == true &&
        peer != null) {
      final size = message.attachmentRef?.size ?? message.attachment?.size ?? 0;
      if (!isOnline(id) ||
          (size > ChatAttachment.relayMaxBytes && peer.files?.ready != true)) {
        await courier!.queue(id, message);
        return;
      }
      try {
        await _sendQueuedLive(id, message);
        return;
      } on TransferRejected {
        rethrow;
      } catch (_) {
        if (_owns(peer) &&
            message.queuedForDelivery &&
            !message.deliveryPaused) {
          await courier!.queue(id, message);
          return;
        }
        rethrow;
      }
    }
    await _sendQueuedLive(id, message);
  }

  Future<void> _recordDelivery(String peer, String id, int receivedAt) async {
    await outbox.acknowledge(peer, id, receivedAt);
    if (_active && history.error == null) {
      await courier?.delivered(peer, id, receivedAt);
    }
  }

  Future<void> _sendQueuedLive(String id, PeerMessage message) async {
    final peer = _peers[id];
    if (peer == null || !_owns(peer)) throw const TransferInterrupted();
    void guard() {
      if (!_owns(peer) ||
          !message.queuedForDelivery ||
          message.deliveryPaused ||
          !history.messagesFor(id).contains(message)) {
        throw const TransferInterrupted('Transfer paused');
      }
    }

    guard();
    if (message.hasAttachment) {
      if (message.attachmentRef?.isChunked == true) {
        if (message.attachmentRef!.size > ChatAttachment.relayMaxBytes &&
            peer.files?.ready != true) {
          throw const TransferInterrupted('Waiting for Direct connection');
        }
        if (peer.files?.supportsLargeFiles != true) {
          throw const TransferInterrupted();
        }
        final received = await peer.files!.send(message);
        if (_owns(peer)) await _recordDelivery(id, message.id, received);
      } else {
        if (!peer.relay.authenticated && peer.files?.ready != true) {
          throw const TransferInterrupted();
        }
        final ChatAttachment attachment;
        try {
          attachment = await history.resolveAttachment(message);
        } catch (_) {
          guard();
          throw const TransferRejected('Cached file is missing or damaged');
        }
        guard();
        try {
          final received = await peer.attachments!.send(
            message.id,
            attachment,
            message.sentAtMilliseconds ?? DateTime.now().millisecondsSinceEpoch,
          );
          if (received != null && _owns(peer)) {
            await _recordDelivery(id, message.id, received);
          }
        } on FormatException catch (error) {
          guard();
          throw TransferRejected(error.message);
        } finally {
          if (_owns(peer)) {
            peer.outgoingProgress.remove(message.id);
            _notify();
          }
        }
      }
    } else {
      final route = await _sendTextWithFailover(peer, message);
      if (_owns(peer) && route != 'courier') {
        history.setStatus(id, message.id, DeliveryStatus.sent);
      }
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _recovery.dispose();
    await _networkChanges?.cancel();
    await _monitor?.close();
    _scheduler.close();
    outbox.close();
    network.removeListener(_changed);
    network.removeFrameListener(_incomingRoute);
    seed?.removeListener(_changed);
    await _signals?.cancel();
    courier?.removeListener(_changed);
    await courier?.close();
    await seed?.close();
    for (final peer in _peers.values.toList()) {
      await peer.close();
    }
    _peers.clear();
    await network.close();
  }
}

class _PeerConnection {
  _PeerConnection(this.contact, this.relay, this.router);
  ContactView contact;
  final RelayChat relay;
  final DeliveryRouter router;
  bool binding = false, polling = false;
  PeerFileController? files;
  RelayPeerSync? sync;
  GapRepair? repair;
  int nextRepair = 0;
  AttachmentTransfer? attachments;
  final incomingProgress = <String, double>{},
      outgoingProgress = <String, double>{};
  Future<void> close() async {
    router.clear();
    sync?.dispose();
    repair?.close();
    attachments?.dispose();
    await files?.close();
    await relay.close();
  }
}
