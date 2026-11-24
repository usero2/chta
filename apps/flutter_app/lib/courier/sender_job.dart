import 'dart:convert';

import 'courier_models.dart';

class CourierSenderJob {
  CourierSenderJob({
    required this.id,
    required this.peerId,
    required this.messageId,
    required this.scope,
    required this.sentAt,
    required this.expiresAt,
    required this.packageCount,
    required this.protectedState,
    required this.mailbox,
    required this.mailboxBucket,
    required this.receiptChallenge,
    required Map<String, Object?> event,
    this.status = CourierJobStatus.preparing,
    this.revision = 0,
    this.allocationRevision = 0,
    String? ready,
    List<String> nodeIds = const [],
    List<String> activeNodeIds = const [],
    Map<String, Object?>? manifest,
    this.manifestHash,
    this.merkleRoot,
    this.receivedAt,
    this.cancelled = false,
  }) : event = Map.unmodifiable(event),
       nodeIds = List.unmodifiable(nodeIds),
       activeNodeIds = List.unmodifiable(activeNodeIds),
       manifest = manifest == null ? null : Map.unmodifiable(manifest),
       _ready = ready == null
           ? IndexBitmap(packageCount)
           : IndexBitmap.fromEncoded(packageCount, ready) {
    if (!courierHex(id, 32) ||
        !RegExp(r'^did:cht:[0-9a-f]{64}$').hasMatch(peerId) ||
        messageId.isEmpty ||
        messageId.length > 256 ||
        scope.isEmpty ||
        scope.length > 256 ||
        sentAt < 0 ||
        sentAt > 9007199254740991 ||
        expiresAt < sentAt ||
        expiresAt > 9007199254740991 ||
        protectedState.isEmpty ||
        protectedState.length > 8192 ||
        !courierHex(mailbox, 64) ||
        mailboxBucket < 0 ||
        mailboxBucket > 9007199254740991 ~/ 86400000 ||
        expiresAt <= mailboxBucket * 86400000 ||
        expiresAt > (mailboxBucket + 2) * 86400000 ||
        receiptChallenge.length != 43 ||
        revision < 0 ||
        revision > 9007199254740990 ||
        allocationRevision < 0 ||
        allocationRevision > revision ||
        nodeIds.length > courierMaxHistoricalNodes ||
        nodeIds.toSet().length != nodeIds.length ||
        nodeIds.any((n) => !courierHex(n, 64)) ||
        activeNodeIds.toSet().length != activeNodeIds.length ||
        activeNodeIds.any((n) => !nodeIds.contains(n)) ||
        (manifestHash != null && !courierHex(manifestHash!, 64)) ||
        (merkleRoot != null && !courierHex(merkleRoot!, 64)) ||
        (receivedAt != null &&
            (receivedAt! < 0 || receivedAt! > 9007199254740991)) ||
        utf8.encode(jsonEncode(event)).length > 16384) {
      throw const FormatException('Invalid Courier sender job');
    }
  }
  final String id,
      peerId,
      messageId,
      scope,
      protectedState,
      mailbox,
      receiptChallenge;
  final int sentAt,
      expiresAt,
      packageCount,
      revision,
      allocationRevision,
      mailboxBucket;
  final Map<String, Object?> event;
  final CourierJobStatus status;
  final List<String> nodeIds, activeNodeIds;
  final Map<String, Object?>? manifest;
  final String? manifestHash, merkleRoot;
  final int? receivedAt;
  final bool cancelled;
  final IndexBitmap _ready;
  int get readyCount => _ready.length;
  bool hasPackage(int index) => _ready.contains(index);
  String get readyEncoded => _ready.encoded;
  bool get terminal => [
    CourierJobStatus.cancelled,
    CourierJobStatus.expired,
    CourierJobStatus.delivered,
    CourierJobStatus.failed,
  ].contains(status);
  Map<String, Object?> toJson() => {
    'version': 1,
    'id': id,
    'peerId': peerId,
    'messageId': messageId,
    'scope': scope,
    'sentAt': sentAt,
    'expiresAt': expiresAt,
    'packageCount': packageCount,
    'protectedState': protectedState,
    'mailbox': mailbox,
    'mailboxBucket': mailboxBucket,
    'receiptChallenge': receiptChallenge,
    'event': event,
    'status': status.name,
    'revision': revision,
    'allocationRevision': allocationRevision,
    'ready': readyEncoded,
    'nodeIds': nodeIds,
    'activeNodeIds': activeNodeIds,
    'manifest': manifest,
    'manifestHash': manifestHash,
    'merkleRoot': merkleRoot,
    'receivedAt': receivedAt,
    'cancelled': cancelled,
  };
  factory CourierSenderJob.fromJson(Map<String, Object?> value) {
    if (value['version'] != 1 || value.length != 24) {
      throw const FormatException('Invalid sender job schema');
    }
    return CourierSenderJob(
      id: value['id'] as String,
      peerId: value['peerId'] as String,
      messageId: value['messageId'] as String,
      scope: value['scope'] as String,
      sentAt: value['sentAt'] as int,
      expiresAt: value['expiresAt'] as int,
      packageCount: value['packageCount'] as int,
      protectedState: value['protectedState'] as String,
      mailbox: value['mailbox'] as String,
      mailboxBucket: value['mailboxBucket'] as int,
      receiptChallenge: value['receiptChallenge'] as String,
      event: Map<String, Object?>.from(value['event'] as Map),
      status: CourierJobStatus.values.byName(value['status'] as String),
      revision: value['revision'] as int,
      allocationRevision: value['allocationRevision'] as int,
      ready: value['ready'] as String,
      nodeIds: List<String>.from(value['nodeIds'] as List),
      activeNodeIds: List<String>.from(value['activeNodeIds'] as List),
      manifest: value['manifest'] == null
          ? null
          : Map<String, Object?>.from(value['manifest'] as Map),
      manifestHash: value['manifestHash'] as String?,
      merkleRoot: value['merkleRoot'] as String?,
      receivedAt: value['receivedAt'] as int?,
      cancelled: value['cancelled'] as bool,
    );
  }
}
