import 'dart:convert';

import '../courier/courier_receiver.dart';
import '../groups/group_controller.dart';
import '../groups/group_models.dart';
import '../groups/swarm/swarm.dart';
import 'delivery_crypto_bridge.dart';
import 'delivery_envelope.dart';

/// Reuses the signed roster, group event and existing piece cache. An outer
/// Courier envelope never substitutes for group membership or event validation.
class GroupDeliverySink {
  GroupDeliverySink({
    required this.controller,
    required this.crypto,
    bool Function()? isCurrent,
  }) : _isCurrent = isCurrent ?? (() => true);
  final GroupController controller;
  final DeliveryCryptoBridge crypto;
  final bool Function() _isCurrent;
  bool get active => _isCurrent() && controller.active;
  (String, int)? scope(DeliveryEnvelope envelope) {
    final match = RegExp(r'^(group:[0-9a-f]{64}):([1-9][0-9]{0,15})$')
        .firstMatch(envelope.scope);
    if (match == null) return null;
    final epoch = int.tryParse(match[2]!);
    return epoch == null ? null : (match[1]!, epoch);
  }

  void _guard() {
    if (!active) throw StateError('Group delivery identity changed');
  }

  Future<bool> authorize(DeliveryEnvelope envelope) async {
    final s = scope(envelope);
    if (!active ||
        s == null ||
        !controller.canSend(s.$1) ||
        controller.group(s.$1)?.contains(envelope.authorId) != true) {
      return false;
    }
    final result = await controller.crypto.groupCall('authorize', {
      'peerId': envelope.authorId,
      'groupId': s.$1,
      'epoch': s.$2,
    });
    return active && result['allowed'] == true;
  }

  Future<bool> authorizeFetch(
    DeliveryEnvelope envelope, {
    int? receivedAt,
  }) async {
    if (envelope.payload['file'] == null) return authorize(envelope);
    final event = await verify(envelope);
    return _recordFileOffer(envelope, _manifest(event), receivedAt: receivedAt);
  }

  Future<bool> authorizeLegacyFile(DeliveryEnvelope envelope) async {
    if (isDeleted(envelope) || !await authorize(envelope)) return false;
    final row = find(envelope), manifest = row?.manifest;
    return manifest != null &&
        row!.sentAt == envelope.sentAt &&
        scope(envelope) == (manifest.groupId, manifest.epoch) &&
        controller.canFetchFile(manifest);
  }

  bool isDeleted(DeliveryEnvelope e) {
    final s = scope(e);
    if (s == null ||
        !active ||
        controller.isDeletedDelivery(s.$1, e.authorId, e.messageId, e.sentAt)) {
      return true;
    }
    final message = find(e);
    return message != null && controller.isMessageRemoved(message);
  }

  GroupMessage? find(DeliveryEnvelope e) {
    final s = scope(e);
    return s == null
        ? null
        : controller
              .messagesFor(s.$1)
              .where((m) => m.id == e.messageId && m.senderId == e.authorId)
              .firstOrNull;
  }

  DeliveryEnvelope? cachedEnvelope(DeliveryEnvelope e) {
    final proof = find(e)?.deliveryEnvelope;
    if (proof == null) return null;
    final result = DeliveryEnvelope.fromJson(proof);
    return result.event['signature'] == e.event['signature'] ? result : null;
  }

  Future<Map<String, Object?>> verify(DeliveryEnvelope e) async {
    _guard();
    if (isDeleted(e) || !await authorize(e)) {
      throw StateError('Group delivery scope unavailable');
    }
    await e.verify(
      crypto,
      author: e.authorId,
      scope: e.scope,
      now: DateTime.now().millisecondsSinceEpoch,
    );
    _guard();
    final p = e.payload;
    if (!['group', 'file'].contains(e.kind) ||
        p['groupEvent'] is! String ||
        p['text'] is! String ||
        p.keys.any((k) => !['groupEvent', 'text', 'file'].contains(k))) {
      throw const FormatException('Invalid group delivery');
    }
    final event = await controller.crypto.groupCall('inspect', {
      'event': p['groupEvent'],
    });
    _guard();
    final s = scope(e)!;
    if (event['groupId'] != s.$1 ||
        event['epoch'] != s.$2 ||
        event['sender'] != e.authorId ||
        event['id'] != e.messageId ||
        event['sentAt'] != e.sentAt ||
        !['message', 'file'].contains(event['kind'])) {
      throw const FormatException('Group event binding mismatch');
    }
    final original = Map<String, Object?>.from(
      jsonDecode(event['payload'] as String) as Map,
    );
    if (event['kind'] == 'message') {
      if (e.kind != 'group' ||
          p['file'] != null ||
          original.length != 1 ||
          original['text'] != p['text']) {
        throw const FormatException('Group text mismatch');
      }
    } else {
      final manifest = SwarmManifest.fromJson(original), file = p['file'];
      if (manifest.groupId != s.$1 ||
          manifest.epoch != s.$2 ||
          manifest.uploaderId != e.authorId ||
          file is! Map ||
          file['name'] != manifest.name ||
          file['mime'] != manifest.mimeType ||
          file['size'] != manifest.size ||
          file['digest'] != manifest.digest ||
          file['caption'] != manifest.caption ||
          p['text'] != (manifest.caption ?? manifest.name)) {
        throw const FormatException('Group file mismatch');
      }
    }
    final old = find(e);
    if (old != null &&
        (old.event != p['groupEvent'] ||
            (old.deliveryEnvelope != null &&
                DeliveryEnvelope.fromJson(old.deliveryEnvelope!)
                        .event['payloadHash'] !=
                    e.event['payloadHash']))) {
      throw const FormatException('Conflicting group event');
    }
    return event;
  }

  Future<int?> existingReceivedAt(DeliveryEnvelope e) async {
    _guard();
    final m = find(e);
    if (m == null) return null;
    await verify(e);
    await controller.flush();
    _guard();
    if (!controller.isDurableMessage(m) ||
        !identical(find(e), m) ||
        isDeleted(e)) {
      return null;
    }
    if (m.manifest != null &&
        (!controller.canFetchFile(m.manifest!) ||
            !controller.hasCompletedFile(m.manifest!) ||
            !(await controller.cache.status(m.manifest!)).complete)) {
      return null;
    }
    return m.receivedAt;
  }

  // Courier staging is copied into the group's swarm cache. It is not a history
  // attachment, so the inbox can discard it after its receipt has been deposited.
  bool referencesFile(String id) => false;

  SwarmManifest _manifest(Map<String, Object?> event) => SwarmManifest.fromJson(
    Map<String, Object?>.from(jsonDecode(event['payload'] as String) as Map),
  );

  Future<bool> _recordFileOffer(
    DeliveryEnvelope e,
    SwarmManifest manifest, {
    int? receivedAt,
  }) => controller.recordFileOffer(
    e.authorId,
    e.payload['groupEvent'] as String,
    e.toJson(),
    manifest,
    receivedAt: receivedAt,
  );

  Future<void> commit(CourierReceived received) async {
    final e = received.envelope, event = await verify(e), s = scope(e)!;
    _guard();
    final generation = controller.conversationGeneration(s.$1),
        existing = await existingReceivedAt(e);
    _guard();
    if (existing != null) {
      final m = find(e)!;
      await controller.saveDeliveryMetadata(m, envelope: e.toJson());
      return;
    }
    SwarmManifest? manifest;
    if (event['kind'] == 'file') {
      manifest = _manifest(event);
      final accepted = await _recordFileOffer(
        e,
        manifest,
        receivedAt: received.receivedAt,
      );
      _guard();
      if (!accepted) throw StateError('Group file has not been accepted');
      final ref = received.attachment;
      if (ref == null) throw StateError('Group attachment missing');
      final file = await controller.attachments.read(controller.ownerId, ref);
      _guard();
      if (generation != controller.conversationGeneration(s.$1) ||
          !await authorize(e) ||
          isDeleted(e) ||
          !controller.canFetchFile(manifest)) {
        throw StateError('Group changed');
      }
      final imported = await controller.cache.importFile(
        groupId: s.$1,
        epoch: s.$2,
        uploaderId: e.authorId,
        fileId: manifest.fileId,
        file: file.withPresentation(caption: manifest.caption),
        cover: manifest.cover,
      );
      _guard();
      if (jsonEncode(imported.toJson()) != jsonEncode(manifest.toJson())) {
        throw const FormatException('Group swarm manifest mismatch');
      }
    }
    if (generation != controller.conversationGeneration(s.$1) ||
        !await authorize(e) ||
        isDeleted(e)) {
      throw StateError('Group changed');
    }
    await controller.acceptDelivery(
      e.authorId,
      e.payload['groupEvent'] as String,
      e.toJson(),
      received.receivedAt,
      file: manifest,
    );
    _guard();
  }
}
