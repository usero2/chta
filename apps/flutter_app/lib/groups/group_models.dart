import 'dart:convert';

import 'swarm/swarm.dart';

class GroupMember {
  const GroupMember({required this.identityId, required this.displayName});
  final String identityId, displayName;
  factory GroupMember.fromJson(Map<String, dynamic> v) => GroupMember(
    identityId: v['identityId'] as String,
    displayName: v['displayName'] as String,
  );
}

class GroupView {
  GroupView({
    required this.groupId,
    required this.name,
    required this.ownerId,
    required this.epoch,
    required this.closed,
    required this.members,
    required this.states,
  });
  final String groupId, name, ownerId;
  final int epoch;
  final bool closed;
  final List<GroupMember> members;
  final List<String> states;
  bool contains(String id) => members.any((m) => m.identityId == id);
  String nameFor(String id) =>
      members.where((m) => m.identityId == id).firstOrNull?.displayName ??
      'Member';
  factory GroupView.fromJson(Map<String, dynamic> v) => GroupView(
    groupId: v['groupId'] as String,
    name: v['name'] as String,
    ownerId: v['ownerId'] as String,
    epoch: v['epoch'] as int,
    closed: v['closed'] as bool,
    members: (v['members'] as List)
        .map((m) => GroupMember.fromJson(Map<String, dynamic>.from(m as Map)))
        .toList(),
    states: (v['states'] as List).cast<String>(),
  );
}

class GroupInvitation {
  GroupInvitation({
    required this.id,
    required this.source,
    required this.groupId,
    required this.name,
    required this.ownerId,
    required this.expiresAt,
  });
  final String id, source, groupId, name, ownerId;
  final int expiresAt;
  Map<String, Object?> toJson() => {
    'id': id,
    'source': source,
    'groupId': groupId,
    'name': name,
    'ownerId': ownerId,
    'expiresAt': expiresAt,
  };
  factory GroupInvitation.fromJson(Map<String, dynamic> v) => GroupInvitation(
    id: v['id'] as String,
    source: v['source'] as String,
    groupId: v['groupId'] as String,
    name: v['name'] as String,
    ownerId: v['ownerId'] as String,
    expiresAt: v['expiresAt'] as int,
  );
}

class GroupMessage {
  GroupMessage({
    required this.id,
    required this.groupId,
    required this.senderId,
    required this.senderName,
    required this.text,
    required this.event,
    required this.sentAt,
    required this.recipients,
    this.receivedAt,
    this.manifest,
    Map<String, int>? receipts,
  }) : receipts = receipts ?? {};
  final String id, groupId, senderId, senderName, text, event;
  final int sentAt;
  final int? receivedAt;
  final List<String> recipients;
  final SwarmManifest? manifest;
  final Map<String, int> receipts;
  String get key => '$senderId:$id';
  Map<String, Object?> toJson() => {
    'id': id,
    'groupId': groupId,
    'senderId': senderId,
    'senderName': senderName,
    'text': text,
    'event': event,
    'sentAt': sentAt,
    'receivedAt': receivedAt,
    'recipients': recipients,
    'receipts': receipts,
    if (manifest != null) 'manifest': manifest!.toJson(),
  };
  factory GroupMessage.fromJson(Map<String, dynamic> v) => GroupMessage(
    id: v['id'] as String,
    groupId: v['groupId'] as String,
    senderId: v['senderId'] as String,
    senderName: v['senderName'] as String,
    text: v['text'] as String,
    event: v['event'] as String,
    sentAt: v['sentAt'] as int,
    receivedAt: v['receivedAt'] as int?,
    recipients: (v['recipients'] as List).cast<String>(),
    receipts: Map<String, dynamic>.from(v['receipts'] as Map)
        .cast<String, int>(),
    manifest: v['manifest'] == null
        ? null
        : SwarmManifest.fromJson(
            Map<String, dynamic>.from(v['manifest'] as Map),
          ),
  );
}

class GroupControlJob {
  GroupControlJob({
    required this.id,
    required this.peerId,
    required this.body,
    this.lastSent = 0,
  });
  final String id, peerId;
  final Map<String, dynamic> body;
  int lastSent;
  Map<String, Object?> toJson() => {'id': id, 'peerId': peerId, 'body': body};
  factory GroupControlJob.fromJson(Map<String, dynamic> v) => GroupControlJob(
    id: v['id'] as String,
    peerId: v['peerId'] as String,
    body: Map<String, dynamic>.from(v['body'] as Map),
  );
  late final String encoded = jsonEncode({'v': 1, 'jobId': id, ...body});
  late final int encodedBytes = utf8.encode(encoded).length;
}
