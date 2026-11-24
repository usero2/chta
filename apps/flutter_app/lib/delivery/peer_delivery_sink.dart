import 'package:crypto/crypto.dart';

import '../chat/attachment_ref.dart';
import '../chat/delivery_feedback.dart';
import '../chat/peer_history.dart';
import '../courier/courier_receiver.dart';
import 'delivery_crypto_bridge.dart';
import 'delivery_envelope.dart';

/// The same durable receive boundary for live, repaired and Courier messages.
class PeerDeliverySink {
  PeerDeliverySink({
    required this.ownerId,
    required this.crypto,
    required this.history,
    required this.isTrusted,
    bool Function()? isCurrent,
  }) : _isCurrent = isCurrent ?? (() => true);
  final String ownerId;
  final DeliveryCryptoBridge crypto;
  final PeerHistory history;
  final bool Function(String peer) isTrusted;
  final bool Function() _isCurrent;
  bool get active => _isCurrent() && history.ownerId == ownerId;
  void _guard() {
    if (!active) throw StateError('Delivery identity changed');
  }

  Future<bool> authorize(DeliveryEnvelope envelope) async =>
      active &&
      envelope.authorId != ownerId &&
      isTrusted(envelope.authorId) &&
      envelope.scope == directDeliveryScope(ownerId, envelope.authorId);
  bool isDeleted(DeliveryEnvelope envelope) =>
      !active ||
      history.isDeletedDelivery(
        envelope.authorId,
        envelope.messageId,
        envelope.sentAt,
      );
  PeerMessage? _find(DeliveryEnvelope envelope) => history
      .messagesFor(envelope.authorId)
      .where((m) => m.id == envelope.messageId)
      .firstOrNull;
  DeliveryEnvelope? cachedEnvelope(DeliveryEnvelope incoming) {
    if (!active) return null;
    final source = _find(incoming)?.deliveryEnvelope;
    if (source == null) return null;
    try {
      final result = DeliveryEnvelope.fromJson(source);
      return result.event['signature'] == incoming.event['signature']
          ? result
          : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> verify(DeliveryEnvelope envelope) async {
    _guard();
    if (!await authorize(envelope) || isDeleted(envelope)) {
      throw StateError('Delivery scope unavailable');
    }
    await envelope.verify(
      crypto,
      author: envelope.authorId,
      scope: directDeliveryScope(ownerId, envelope.authorId),
      now: DateTime.now().millisecondsSinceEpoch,
    );
    _guard();
    final payload = envelope.payload;
    if (payload['text'] is! String ||
        payload.keys.any((key) => key != 'text' && key != 'file')) {
      throw const FormatException('Invalid private message descriptor');
    }
    if (payload['file'] == null) {
      validateOutgoingText(payload['text'] as String);
      if (envelope.kind != 'text') {
        throw const FormatException('Message kind mismatch');
      }
    } else if (payload['file'] is! Map ||
        !['file', 'image', 'video', 'audio'].contains(envelope.kind)) {
      throw const FormatException('Attachment kind mismatch');
    }
  }

  Future<void> _matches(PeerMessage message, DeliveryEnvelope envelope) async {
    if (!message.incoming ||
        (message.sentAtMilliseconds != null &&
            message.sentAtMilliseconds != envelope.sentAt)) {
      throw const FormatException('Conflicting message identity');
    }
    final source = message.deliveryEnvelope;
    if (source != null &&
        DeliveryEnvelope.fromJson(source).event['payloadHash'] !=
            envelope.event['payloadHash']) {
      throw const FormatException('Conflicting author payload');
    }
    final file = envelope.payload['file'];
    if (file == null) {
      if (message.hasAttachment || message.text != envelope.payload['text']) {
        throw const FormatException('Conflicting message content');
      }
      return;
    }
    if (file is! Map || !message.hasAttachment) {
      throw const FormatException('Conflicting attachment');
    }
    final ref = message.attachmentRef;
    if (ref != null) {
      if (ref.name != file['name'] ||
          ref.mimeType != file['mime'] ||
          ref.size != file['size'] ||
          ref.digest != file['digest'] ||
          ref.caption != file['caption'] ||
          ref.groupId != file['groupId'] ||
          ref.groupIndex != file['groupIndex'] ||
          ref.groupCount != file['groupCount']) {
        throw const FormatException('Conflicting attachment descriptor');
      }
    } else {
      final attachment = await history.resolveAttachment(message);
      _guard();
      if (attachment.name != file['name'] ||
          attachment.mimeType != file['mime'] ||
          attachment.size != file['size'] ||
          (await sha256.bind(attachment.openRead()).first).toString() !=
              file['digest']) {
        throw const FormatException('Conflicting attachment content');
      }
    }
  }

  Future<int?> existingReceivedAt(DeliveryEnvelope envelope) async {
    _guard();
    final load = history.loadGeneration,
        room = history.conversationGeneration(envelope.authorId);
    final existing = _find(envelope);
    if (existing == null || existing.status != DeliveryStatus.delivered) {
      return null;
    }
    await _matches(existing, envelope);
    await history.flush();
    _guard();
    void check() {
      if (load != history.loadGeneration ||
          room != history.conversationGeneration(envelope.authorId) ||
          !isTrusted(envelope.authorId) ||
          isDeleted(envelope) ||
          !identical(existing, _find(envelope))) {
        throw StateError('Conversation changed during receipt');
      }
    }

    check();
    if (history.error != null) {
      history.changed(envelope.authorId);
      await history.flush();
      _guard();
      check();
    }
    if (history.error != null) {
      throw StateError('Received message is not durable');
    }
    return existing.receivedAtMilliseconds;
  }

  bool referencesFile(String id) =>
      history.cacheReferences.any((entry) => entry.ref.chunkedId == id);
  Future<void> commit(CourierReceived received) async {
    final e = received.envelope;
    _guard();
    final generation = history.loadGeneration,
        room = history.conversationGeneration(e.authorId);
    await verify(e);
    _guard();
    if (generation != history.loadGeneration ||
        room != history.conversationGeneration(e.authorId) ||
        isDeleted(e)) {
      throw StateError('Conversation changed');
    }
    final existing = _find(e);
    if (existing != null) {
      await _matches(existing, e);
      _guard();
      if (existing.status != DeliveryStatus.delivered) {
        if (e.payload['file'] != null && received.attachment == null) {
          throw StateError('Attachment not received');
        }
        existing.attachmentRef = received.attachment ?? existing.attachmentRef;
        existing.attachment = null;
        existing.status = DeliveryStatus.delivered;
      }
      existing.receivedAtMilliseconds ??= received.receivedAt;
      existing.deliveryEnvelope ??= e.toJson();
      history.changed(e.authorId);
    } else {
      final descriptor = e.payload['file'];
      if (descriptor != null) {
        final ref = received.attachment;
        if (ref == null || !_refMatches(ref, descriptor as Map)) {
          throw const FormatException('Received attachment mismatch');
        }
      }
      history.add(
        e.authorId,
        PeerMessage(
          id: e.messageId,
          text: e.payload['text'] as String,
          incoming: true,
          status: DeliveryStatus.delivered,
          sentAtMilliseconds: e.sentAt,
          receivedAtMilliseconds: received.receivedAt,
          attachmentRef: received.attachment,
          deliveryEnvelope: e.toJson(),
        ),
        expectedGeneration: room,
      );
    }
    await history.flush();
    _guard();
    if (history.error != null ||
        generation != history.loadGeneration ||
        room != history.conversationGeneration(e.authorId) ||
        isDeleted(e) ||
        _find(e) == null) {
      throw StateError('Could not persist received message');
    }
  }

  bool _refMatches(AttachmentRef ref, Map descriptor) =>
      ref.name == descriptor['name'] &&
      ref.mimeType == descriptor['mime'] &&
      ref.size == descriptor['size'] &&
      ref.digest == descriptor['digest'] &&
      ref.caption == descriptor['caption'] &&
      ref.groupId == descriptor['groupId'] &&
      ref.groupIndex == descriptor['groupIndex'] &&
      ref.groupCount == descriptor['groupCount'];
}
