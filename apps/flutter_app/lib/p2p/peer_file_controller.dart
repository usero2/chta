import 'dart:async';
import 'dart:convert';

import '../account/account_models.dart';
import '../chat/attachment_transfer.dart';
import '../chat/attachment_ref.dart';
import '../chat/file_offer.dart';
import '../chat/chunked_attachment_bridge.dart';
import '../chat/file_transfer_progress.dart';
import '../chat/peer_history.dart';
import '../chat/peer_message_action.dart';
import '../chat/resumable_attachment_transfer.dart';
import 'direct_file_link.dart';

/// Binds the direct DTLS link and durable file jobs to one verified conversation.
class PeerFileController {
  PeerFileController({
    required this.ownerId,
    required this.cache,
    required this.history,
    required this.sendEncryptedControl,
    this.sendSeedControl,
    required this.sendFallbackPacket,
    required this.onPacket,
    required this.onReceipt,
    this.onChanged,
    this.autoResume = true,
    this.advertiseMessageActions = false,
    this.advertiseFileOffers = false,
    this.validateFileOffer,
    bool automaticRetries = true,
    int Function()? clock,
    DirectPeerFactory? peerFactory,
  }) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch) {
    if (automaticRetries) {
      _retryTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => unawaited(_retryMessages()),
      );
    }
    link = DirectFileLink(
      ownIdentityId: ownerId,
      allowEitherInitiator: true,
      sendSignal: _sendSignal,
      onChanged: _linkChanged,
      peerFactory: peerFactory,
    );
    _subscription = link.frames.listen((frame) {
      unawaited(_frame(frame));
    });
  }
  final String ownerId;
  final bool autoResume;
  final bool advertiseMessageActions;
  final bool advertiseFileOffers;
  final FutureOr<bool> Function(String id, AttachmentRef ref)?
  validateFileOffer;
  final _sentCapabilities = <String>{};
  final _peerCapabilities = <String>{};
  bool get supportsMessageActions =>
      ready && _peerCapabilities.contains(PeerMessageAction.capability);
  bool get supportsFileOffers =>
      ready && _peerCapabilities.contains(fileOfferCapability);
  final ChunkedAttachmentBridge cache;
  final PeerHistory history;
  final DirectSignalSender sendEncryptedControl;
  final DirectSignalSender? sendSeedControl;
  final Future<void> Function(String id, String text, int sentAt)
  sendFallbackPacket;
  final Future<void> Function(String id, String text, int? sentAt) onPacket;
  final void Function(String id, int receivedAt) onReceipt;
  final void Function()? onChanged;
  late final DirectFileLink link;
  StreamSubscription<String>? _subscription;
  Timer? _retryTimer;
  final int Function() _clock;
  bool _retrying = false;
  final _pendingMessages = <String, _DirectMessage>{};
  ResumableAttachmentTransfer? _transfer;
  String? _peer;
  bool _capable = false,
      _closed = false,
      _signalingAvailable = false,
      _overflowReset = false;
  bool _fallbackAuthenticated = false,
      _seedAvailable = false,
      _seedValidated = false,
      _noiseValidated = false;
  int _bindRevision = 0;
  Future<void>? _bindFuture;
  int _generation = 0, _framesInFlight = 0;
  Future<void> _incoming = Future.value();
  final progress = <String, TransferProgressSnapshot>{};
  final _running = <String>{};
  bool get ready =>
      !_closed &&
      _capable &&
      (_noiseValidated || _seedValidated) &&
      link.ready &&
      link.peerId == _peer;
  bool get supportsLargeFiles => _capable;
  String? get peerId => _peer;
  bool _current(int generation, String peer) =>
      !_closed && generation == _generation && peer == _peer;

  Future<void> recoverNetwork() async {
    if (_closed) return;
    _generation++;
    _transfer?.dispose();
    _transfer = null;
    _running.clear();
    _pendingMessages.clear();
    _seedValidated = false;
    _noiseValidated = false;
    if (_peer != null && _capable) _createTransfer(_peer!, _generation);
    await link.recoverNetwork();
    if (!_closed) onChanged?.call();
  }

  /// Forget local work for a deleted conversation, retaining its live channel.
  void cancelPendingFor(String identityId) {
    if (_closed || _peer != identityId) return;
    _generation++;
    _transfer?.dispose();
    _transfer = null;
    _running.clear();
    _pendingMessages.clear();
    progress.clear();
    if (_capable) _createTransfer(identityId, _generation);
    onChanged?.call();
  }

  void interruptTransfer(String id) {
    _transfer?.interrupt(id);
    progress.remove(id);
    onChanged?.call();
  }

  Future<void> _sendSignal(String id, String text) async {
    final peer = _peer, generation = _generation;
    if (peer == null ||
        !_capable ||
        !_signalingAvailable ||
        link.peerId != peer) {
      throw const TransferInterrupted();
    }
    if (_fallbackAuthenticated) {
      await sendEncryptedControl(id, text);
    } else if (_seedAvailable && sendSeedControl != null) {
      await sendSeedControl!(id, text);
    } else {
      throw const TransferInterrupted();
    }
    if (!_current(generation, peer)) throw const TransferInterrupted();
  }

  Future<void> updatePeer(
    ContactView? contact, {
    required bool encryptedAuthenticated,
    bool seedSignalingAvailable = false,
  }) {
    if (_closed) return Future.value();
    final selected = contact?.verified == true ? contact!.identityId : null;
    final seed =
        selected != null && seedSignalingAvailable && sendSeedControl != null;
    final capable =
        selected != null &&
        (contact!.capabilities.contains('files-v2') ||
            seed ||
            (selected == _peer && _seedValidated));
    final fallback =
        encryptedAuthenticated &&
        selected != null &&
        contact!.capabilities.contains('files-v2');
    final signaling = fallback || seed;
    final changed =
        selected != _peer ||
        capable != _capable ||
        signaling != _signalingAvailable;
    if (selected != _peer || capable != _capable) {
      _generation++;
      _transfer?.dispose();
      _transfer = null;
      _running.clear();
      _pendingMessages.clear();
      progress.clear();
      _peer = selected;
      _sentCapabilities.clear();
      _peerCapabilities.clear();
      _capable = capable;
      _seedValidated = false;
      _noiseValidated = false;
      if (selected != null && capable) _createTransfer(selected, _generation);
    }
    _signalingAvailable = signaling;
    _fallbackAuthenticated = fallback;
    _noiseValidated |= fallback;
    _seedAvailable = seed;
    if (changed || link.peerId != (capable ? selected : null)) {
      _bindRevision++;
    } else {
      _announceActions();
      unawaited(resumePending());
      return _bindFuture ?? Future.value();
    }
    return _bindFuture ??= _drainBindings().whenComplete(
      () => _bindFuture = null,
    );
  }

  Future<void> _drainBindings() async {
    while (!_closed) {
      final revision = _bindRevision;
      try {
        await link.bind(
          _capable ? _peer : null,
          signalingAvailable: _signalingAvailable,
        );
      } catch (_) {
        /* Existing chat survives a failed direct attempt. */
      }
      if (revision == _bindRevision) break;
    }
    if (!_closed) unawaited(resumePending());
  }

  void _createTransfer(String peer, int generation) {
    _transfer?.dispose();
    _transfer = ResumableAttachmentTransfer(
      ownerId: ownerId,
      peerId: peer,
      bridge: cache,
      isDirect: () => ready,
      validateOffer: validateFileOffer,
      checkIncoming: (id) {
        final message = history
            .messagesFor(peer)
            .where((m) => m.id == id && m.incoming)
            .firstOrNull;
        if (message?.deliveryPaused == true) {
          if (message!.failureReason == 'Cancelled') {
            throw const TransferRejected('Cancelled by recipient');
          }
          throw const TransferInterrupted('Paused by recipient');
        }
      },
      onReceipt: (id, time) {
        if (!_current(generation, peer)) return;
        final message = history
            .messagesFor(peer)
            .where(
              (m) =>
                  m.id == id &&
                  !m.incoming &&
                  m.attachmentRef?.isChunked == true,
            )
            .firstOrNull;
        if (message == null || message.status == DeliveryStatus.delivered) {
          return;
        }
        progress.remove(id);
        onReceipt(id, time);
      },
      sendPacket: (id, text) async {
        if (!_current(generation, peer)) throw const TransferInterrupted();
        if (ready) {
          await sendDirectPacket(
            id,
            text,
            DateTime.now().millisecondsSinceEpoch,
          );
        } else {
          if (!_fallbackAuthenticated) throw const TransferInterrupted();
          await sendFallbackPacket(
            id,
            text,
            DateTime.now().millisecondsSinceEpoch,
          );
        }
      },
      onOffer: (id, ref, sentAt) async {
        if (!_current(generation, peer)) throw const TransferInterrupted();
        final existing = history
            .messagesFor(peer)
            .where((m) => m.id == id)
            .firstOrNull;
        if (existing == null) {
          history.add(
            peer,
            PeerMessage(
              id: id,
              text: '[file] ${ref.name}',
              incoming: true,
              status: DeliveryStatus.pending,
              attachmentRef: ref,
              sentAtMilliseconds: sentAt,
            ),
          );
        } else if (!existing.incoming ||
            existing.attachmentRef?.digest != ref.digest ||
            existing.attachmentRef?.size != ref.size ||
            existing.attachmentRef?.chunkedId != ref.chunkedId) {
          throw const TransferRejected('Conflicting file history');
        }
        await history.flush();
        if (history.error != null) {
          throw StateError('Could not persist file history');
        }
        if (!_current(generation, peer)) throw const TransferInterrupted();
      },
      onCompleted: (id, ref) async {
        if (!_current(generation, peer)) throw const TransferInterrupted();
        final message = history
            .messagesFor(peer)
            .where((m) => m.id == id && m.incoming)
            .first;
        final received =
            message.receivedAtMilliseconds ??
            DateTime.now().millisecondsSinceEpoch;
        final previousTime = message.receivedAtMilliseconds,
            previousStatus = message.status;
        message.receivedAtMilliseconds = received;
        message.status = DeliveryStatus.delivered;
        history.changed(peer);
        await history.flush();
        if (history.error != null) {
          message.receivedAtMilliseconds = previousTime;
          message.status = previousStatus;
          history.changed(peer);
          throw StateError('Could not persist delivered file');
        }
        if (!_current(generation, peer)) throw const TransferInterrupted();
        return received;
      },
      onProgress: (id, value, incoming) {
        if (_current(generation, peer)) {
          if (value.phase == FileTransferPhase.completed ||
              history
                  .messagesFor(peer)
                  .any(
                    (m) => m.id == id && m.status == DeliveryStatus.delivered,
                  )) {
            progress.remove(id);
          } else {
            progress[id] = value;
          }
          onChanged?.call();
        }
      },
    );
  }

  Future<void> receiveEncryptedControl(
    String id,
    String text, {
    required bool authenticated,
    String? peer,
  }) async {
    if (_closed ||
        !_capable ||
        !authenticated ||
        peer != _peer ||
        !id.startsWith(DirectFileLink.controlPrefix)) {
      return;
    }
    try {
      await link.receiveSignal(id, text);
    } catch (_) {}
  }

  /// Caller has verified the remote signed envelope against this saved friend.
  /// This never authorizes the Noise/data-relay fallback.
  Future<void> receiveSeedControl(
    String id,
    String text, {
    required String peer,
  }) async {
    if (_closed ||
        !_capable ||
        !_seedAvailable ||
        peer != _peer ||
        !id.startsWith(DirectFileLink.controlPrefix)) {
      return;
    }
    final generation = _generation;
    try {
      final packet = jsonDecode(text);
      await link.receiveSignal(id, text);
      if (_current(generation, peer) &&
          packet is Map &&
          ['offer', 'answer'].contains(packet['t'])) {
        _seedValidated = true;
        _linkChanged();
      }
    } catch (_) {}
  }

  Future<void> receiveFilePacket(
    String id,
    String text, {
    required bool direct,
  }) async {
    if (_closed ||
        !_capable ||
        _transfer == null ||
        (direct ? !ready : !_fallbackAuthenticated)) {
      return;
    }
    await _transfer!.receive(id, text, direct: direct);
  }

  Future<void> sendDirectPacket(String id, String text, int? sentAt) async {
    if (!ready) throw const TransferInterrupted();
    await link.send(
      jsonEncode({
        'v': 1,
        'type': 'packet',
        'id': id,
        'text': text,
        'sentAt': sentAt,
      }),
      bulk: AttachmentTransfer.isBulkPacket(id, text),
    );
  }

  /// Text keeps the same ID across routes so the receiver can deduplicate retries.
  Future<void> sendChatMessage(String id, String text, int sentAt) async {
    if (_pendingMessages.length >= 100 && !_pendingMessages.containsKey(id)) {
      throw const TransferRejected('Message queue is full');
    }
    final pending = _DirectMessage(id, text, sentAt, _clock());
    _pendingMessages[id] = pending;
    try {
      await sendDirectPacket(id, text, sentAt);
    } catch (_) {
      _pendingMessages.remove(id);
      rethrow;
    }
  }

  Future<void> _retryMessages() async {
    if (_retrying || _closed || _peer == null) return;
    _retrying = true;
    final peer = _peer!, generation = _generation;
    try {
      for (final pending in _pendingMessages.values.toList()) {
        if (!_current(generation, peer)) return;
        final message = history
            .messagesFor(peer)
            .where((m) => m.id == pending.id)
            .firstOrNull;
        if (message?.status == DeliveryStatus.delivered) {
          _pendingMessages.remove(pending.id);
          continue;
        }
        if (_clock() - pending.lastSent < 5000) continue;
        if (!ready && !_fallbackAuthenticated) continue;
        if (pending.attempts >= 8) {
          _pendingMessages.remove(pending.id);
          history.setStatus(peer, pending.id, DeliveryStatus.failed);
          onChanged?.call();
          continue;
        }
        pending.lastSent = _clock();
        pending.attempts++;
        try {
          if (ready) {
            await sendDirectPacket(pending.id, pending.text, pending.sentAt);
          } else {
            await sendFallbackPacket(pending.id, pending.text, pending.sentAt);
          }
        } catch (_) {
          // Keep the ID pending until a receipt or an explicit retry failure.
        }
      }
    } finally {
      _retrying = false;
    }
  }

  Future<void> acknowledge(String id, int receivedAt) async {
    if (ready) {
      await link.send(
        jsonEncode({
          'v': 1,
          'type': 'receipt',
          'id': id,
          'receivedAt': receivedAt,
        }),
      );
    }
  }

  Future<void> _frame(String frame) async {
    if (_closed || !ready) return;
    if (_framesInFlight >= 512) {
      unawaited(_resetAfterOverflow());
      return;
    }
    final generation = _generation, peer = _peer!;
    _framesInFlight++;
    final pending = _incoming.then((_) async {
      if (!_current(generation, peer)) return;
      try {
        final value = jsonDecode(frame);
        if (value is! Map<String, dynamic> ||
            value['v'] != 1 ||
            value['id'] is! String ||
            (value['id'] as String).length > 180) {
          return;
        }
        final id = value['id'] as String;
        if (value['type'] == 'capability' &&
            _advertisedCapabilities.contains(id)) {
          if (_peerCapabilities.add(id)) onChanged?.call();
          if (value['reply'] != true) await _sendCapability(id, reply: true);
        } else if (value['type'] == 'receipt') {
          final time = value['receivedAt'];
          if (time is int && time >= 0 && time <= 8640000000000000) {
            _pendingMessages.remove(id);
            onReceipt(id, time);
          }
        } else if (value['type'] == 'packet' && value['text'] is String) {
          final sentAt = value['sentAt'];
          if (sentAt != null &&
              (sentAt is! int || sentAt < 0 || sentAt > 8640000000000000)) {
            return;
          }
          final text = value['text'] as String;
          if (ResumableAttachmentTransfer.isPacketId(id)) {
            await receiveFilePacket(id, text, direct: true);
          } else {
            await onPacket(
              id,
              text,
              value['sentAt'] is int ? value['sentAt'] as int : null,
            );
          }
        }
      } catch (_) {
        /* Bad data never enters another conversation or closes chat. */
      }
    });
    _incoming = pending.catchError((Object _) {});
    try {
      await pending;
    } finally {
      _framesInFlight--;
    }
  }

  Future<void> _resetAfterOverflow() async {
    if (_overflowReset || _closed) return;
    _overflowReset = true;
    try {
      final peer = _peer;
      _generation++;
      _transfer?.dispose();
      _running.clear();
      if (peer != null && _capable) _createTransfer(peer, _generation);
      await link.bind(null, signalingAvailable: false);
      _bindRevision++;
      await (_bindFuture ??= _drainBindings().whenComplete(
        () => _bindFuture = null,
      ));
    } finally {
      _overflowReset = false;
    }
  }

  Iterable<String> get _advertisedCapabilities sync* {
    if (advertiseMessageActions) yield PeerMessageAction.capability;
    if (advertiseFileOffers) yield fileOfferCapability;
  }

  Future<void> _sendCapability(String id, {bool reply = false}) => link.send(
    jsonEncode({'v': 1, 'type': 'capability', 'id': id, 'reply': reply}),
  );

  void _announceActions() {
    if (!ready) return;
    final generation = _generation;
    for (final id in _advertisedCapabilities) {
      if (!_sentCapabilities.add(id)) continue;
      unawaited(
        _sendCapability(id).catchError((Object _) {
          if (_generation == generation) _sentCapabilities.remove(id);
        }),
      );
    }
  }

  void _linkChanged() {
    if (_closed) return;
    if (!ready) {
      _sentCapabilities.clear();
      _peerCapabilities.clear();
      _transfer?.disconnected();
    } else {
      _announceActions();
    }
    onChanged?.call();
    if (ready) unawaited(resumePending());
  }

  Future<int> send(PeerMessage message) async {
    final peer = _peer,
        generation = _generation,
        transfer = _transfer,
        ref = message.attachmentRef;
    if (peer == null || transfer == null || ref?.isChunked != true) {
      throw const TransferRejected('Update both apps to send large files');
    }
    if (!_running.add(message.id)) {
      throw const TransferInterrupted('Transfer is already running');
    }
    var drainNext = true;
    try {
      message.status = DeliveryStatus.pending;
      history.changed(peer);
      final received = await transfer.send(
        message.id,
        ref!,
        sentAtMilliseconds: message.sentAtMilliseconds,
      );
      if (!_current(generation, peer)) throw const TransferInterrupted();
      message.receivedAtMilliseconds = received;
      history.setStatus(peer, message.id, DeliveryStatus.delivered);
      await history.flush();
      return received;
    } on TransferInterrupted {
      drainNext = false;
      if (_current(generation, peer) &&
          !message.deliveryPaused &&
          message.status != DeliveryStatus.delivered) {
        message.status = DeliveryStatus.pending;
        history.changed(peer);
      }
      rethrow;
    } on TransferRejected {
      if (_current(generation, peer) &&
          !message.deliveryPaused &&
          message.status != DeliveryStatus.delivered) {
        history.setStatus(peer, message.id, DeliveryStatus.failed);
      }
      rethrow;
    } catch (_) {
      drainNext = false;
      if (_current(generation, peer) &&
          !message.deliveryPaused &&
          message.status != DeliveryStatus.delivered) {
        message.status = DeliveryStatus.pending;
        history.changed(peer);
      }
      throw const TransferInterrupted();
    } finally {
      if (_current(generation, peer)) {
        _running.remove(message.id);
        if (drainNext) unawaited(resumePending());
      }
    }
  }

  Future<void> resumePending() async {
    if (!autoResume) return;
    if (_closed || !_capable || _peer == null || _transfer == null) return;
    if (!ready && !_fallbackAuthenticated) return;
    for (final message in history.messagesFor(_peer).toList()) {
      if (_running.length >= 2) break;
      if (message.incoming ||
          !message.hasAttachment ||
          message.attachmentRef?.isChunked != true ||
          ![
            DeliveryStatus.pending,
            DeliveryStatus.sent,
          ].contains(message.status) ||
          _running.contains(message.id)) {
        continue;
      }
      final size = message.attachmentRef!.size;
      if (!ready && size > 25 * 1024 * 1024) {
        progress[message.id] = TransferProgressSnapshot(
          confirmedBytes: (progress[message.id]?.confirmedBytes ?? 0).clamp(
            0,
            size,
          ),
          totalBytes: size,
          bytesPerSecond: 0,
          transport: 'Direct',
          phase: FileTransferPhase.waiting,
        );
        continue;
      }
      unawaited(
        send(message).then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _retryTimer?.cancel();
    _pendingMessages.clear();
    _generation++;
    _transfer?.dispose();
    final closingLink = link.close();
    await _subscription?.cancel();
    await closingLink;
  }
}

class _DirectMessage {
  _DirectMessage(this.id, this.text, this.sentAt, this.lastSent);
  final String id, text;
  final int sentAt;
  int lastSent;
  int attempts = 1;
}
