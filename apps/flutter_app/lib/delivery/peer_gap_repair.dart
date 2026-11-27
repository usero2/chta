import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../chat/delivery_feedback.dart';
import '../chat/file_offer.dart';
import '../chat/peer_history.dart';
import '../groups/group_blob_bridge.dart';
import 'delivery_envelope.dart';
import 'gap_repair.dart';
import 'peer_delivery_sink.dart';

const _legacyPrefix = 'chta-gap-original-v1:';

class ProtectedGapCursor {
  ProtectedGapCursor(this.storage, this.owner, this.peer);
  final GroupBlobBridge storage;
  final String owner, peer;
  String _key(String scope) =>
      'gap_${sha256.convert(utf8.encode('$peer\u0000$scope'))}';
  Future<int> resume(String scope, String snapshot) async {
    final source = await storage.loadGroupBlob(owner, _key(scope));
    if (source == null) return 0;
    final value = jsonDecode(source) as Map;
    return value['snapshot'] == snapshot ? value['next'] as int : 0;
  }

  Future<void> checkpoint(String scope, String snapshot, int next) =>
      storage.saveGroupBlob(
        owner,
        _key(scope),
        jsonEncode({'snapshot': snapshot, 'next': next}),
      );
}

class PeerGapRepair {
  PeerGapRepair({required this.sink, required this.peer});
  final PeerDeliverySink sink;
  final String peer;
  PeerHistory get history => sink.history;
  String get scope => directDeliveryScope(sink.ownerId, peer);
  bool get active => sink.active && sink.isTrusted(peer);
  bool contains(String id) =>
      history.error == null && history.messagesFor(peer).any((m) => m.id == id);

  List<GapRecord> rows() => [
    for (final m
        in history
            .messagesFor(peer)
            .reversed
            .where(
              (m) =>
                  !m.incoming &&
                  !m.hasAttachment &&
                  !isFileOfferEvent(m.id) &&
                  !m.deliveryPaused &&
                  m.sentAtMilliseconds != null &&
                  (m.status == DeliveryStatus.delivered ||
                      m.status == DeliveryStatus.sent),
            )
            .take(GapRepair.maxRecords))
      GapRecord(
        m.id,
        m.deliveryEnvelope == null
            ? '$_legacyPrefix${jsonEncode({'id': m.id, 'sentAt': m.sentAtMilliseconds, 'text': m.text})}'
            : DeliveryEnvelope.fromJson(m.deliveryEnvelope!).toWire(),
      ),
  ];

  /// Legacy data can only be imported from the authenticated original author.
  Future<void> commit(GapRecord row) async {
    if (!active) throw StateError('Private repair session changed');
    final load = history.loadGeneration,
        room = history.conversationGeneration(peer);
    final DeliveryEnvelope? envelope;
    final int sentAt;
    final String text;
    if (row.source.startsWith(deliveryWirePrefix)) {
      envelope = DeliveryEnvelope.fromWire(row.source);
      if (envelope.authorId != peer ||
          envelope.scope != scope ||
          envelope.messageId != row.id ||
          envelope.kind != 'text' ||
          envelope.payload['file'] != null) {
        throw const FormatException('Private repair event binding mismatch');
      }
      sentAt = envelope.sentAt;
      if (history.isDeletedDelivery(peer, row.id, sentAt)) return;
      await sink.verify(envelope);
      text = envelope.payload['text'] as String;
    } else if (row.source.startsWith(_legacyPrefix)) {
      envelope = null;
      final value =
          jsonDecode(row.source.substring(_legacyPrefix.length)) as Map;
      if (value.length != 3 ||
          value['id'] != row.id ||
          value['sentAt'] is! int ||
          value['text'] is! String) {
        throw const FormatException('Invalid original-author record');
      }
      text = value['text'] as String;
      sentAt = value['sentAt'] as int;
      validateOutgoingText(text);
      if (sentAt < 0 ||
          sentAt > DateTime.now().millisecondsSinceEpoch + 300000) {
        throw const FormatException('Invalid original timestamp');
      }
    } else {
      throw const FormatException('Unknown private repair record');
    }
    if (!active ||
        history.loadGeneration != load ||
        history.conversationGeneration(peer) != room) {
      throw StateError('Private conversation changed');
    }
    if (history.isDeletedDelivery(peer, row.id, sentAt)) return;
    final existing = history
        .messagesFor(peer)
        .where((m) => m.id == row.id)
        .firstOrNull;
    if (existing == null) {
      history.add(
        peer,
        PeerMessage(
          id: row.id,
          text: text,
          incoming: true,
          status: DeliveryStatus.delivered,
          sentAtMilliseconds: sentAt,
          deliveryEnvelope: envelope?.toJson(),
          repaired: true,
        ),
        expectedGeneration: room,
      );
    } else {
      if (!existing.incoming ||
          existing.hasAttachment ||
          existing.text != text ||
          (existing.sentAtMilliseconds != null &&
              existing.sentAtMilliseconds != sentAt)) {
        throw const FormatException('Conflicting private repair record');
      }
      if (history.error != null) history.changed(peer);
    }
    await history.flush();
    if (!active ||
        history.error != null ||
        history.loadGeneration != load ||
        history.conversationGeneration(peer) != room) {
      throw StateError('Private repair not saved');
    }
  }
}
