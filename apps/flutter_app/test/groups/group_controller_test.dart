import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cht/chat/attachment_source.dart';
import 'package:cht/chat/chat_attachment.dart';
import 'package:cht/groups/group_controller.dart';
import 'package:cht/groups/group_crypto_bridge.dart';
import 'package:cht/groups/group_models.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'swarm_test.dart' show Blobs, Attachments;

const owner =
    'did:cht:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const friend =
    'did:cht:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const gid =
    'group:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';

class ModelCrypto implements GroupCryptoBridge {
  ModelCrypto({this.accountId = owner});

  final String accountId;
  int memberCount = 2;
  bool includeFriend = false;
  final groups = <String, Map<String, Object?>>{};
  Map<String, Object?> view() => {
    'groupId': gid,
    'name': 'Team',
    'ownerId': owner,
    'epoch': 1,
    'closed': false,
    'members': [
      {'identityId': owner, 'displayName': 'Alice'},
      if (includeFriend) {'identityId': friend, 'displayName': 'Bob'},
      if (!includeFriend)
        for (var i = 1; i < memberCount; i++)
          {
            'identityId': 'did:cht:${i.toRadixString(16).padLeft(64, '0')}',
            'displayName': 'Friend $i',
          },
    ],
    'states': <String>[],
  };
  @override
  Future<Map<String, Object?>> groupCall(
    String op,
    Map<String, Object?> args,
  ) async {
    switch (op) {
      case 'create':
        groups[gid] = view();
        return {
          'state': jsonEncode({'groupId': gid}),
        };
      case 'list':
        return {'groups': groups.values.toList()};
      case 'view':
        return groups[gid]!;
      case 'export':
        return {'data': jsonEncode(groups)};
      case 'import':
        groups.addAll(
          (jsonDecode(args['data'] as String) as Map).map(
            (k, v) =>
                MapEntry(k as String, Map<String, Object?>.from(v as Map)),
          ),
        );
        return {};
      case 'sign':
        return {
          'event': jsonEncode({
            ...args,
            'sender': accountId,
            'sentAt': args['now'],
            'epoch': 1,
          }),
        };
      case 'authorize':
        return {'allowed': true};
      case 'invite':
        return {
          'invite': jsonEncode({
            'state': jsonEncode({'groupId': gid}),
            'recipientId': args['peerId'],
          }),
        };
      case 'accept':
        return {
          'receipt': jsonEncode({'invite': args['invite']}),
        };
      case 'leave':
        if (accountId != owner) {
          return {
            'event': jsonEncode({
              'groupId': args['groupId'],
              'kind': 'leave',
              'id': 'leave-${args['now']}',
              'sender': accountId,
            }),
          };
        }
        groups[gid]!['closed'] = true;
        return {
          'state': jsonEncode({'groupId': gid}),
        };
      case 'remove':
        groups[gid]!['epoch'] = (groups[gid]!['epoch'] as int) + 1;
        (groups[gid]!['members'] as List).removeWhere(
          (m) => m['identityId'] == args['peerId'],
        );
        return {
          'state': jsonEncode({'groupId': gid}),
        };
      default:
        throw UnimplementedError(op);
    }
  }
}

class PausedSource implements AttachmentSource {
  final entered = Completer<void>(), gate = Completer<void>();
  @override
  int get length => 8;
  @override
  String get key => 'paused-file';
  @override
  Stream<List<int>> openRead({int start = 0, int? end}) async* {
    if (!entered.isCompleted) entered.complete();
    await gate.future;
    yield Uint8List(8).sublist(start, end);
  }
}

class FailingBlobs extends Blobs {
  int jobs = 0;
  @override
  Future<void> saveGroupBlob(String o, String k, String v) async {
    if (k.startsWith('g-job-') && ++jobs == 2) {
      throw StateError('synthetic disk failure');
    }
    await super.saveGroupBlob(o, k, v);
  }
}

class FailOnceReceiptBlobs extends Blobs {
  int failedReceiptWrites = 0;
  bool failReceiptWrite = true;

  @override
  Future<void> saveGroupBlob(String o, String k, String v) async {
    if (failReceiptWrite && k.startsWith('g-job-')) {
      failReceiptWrite = false;
      failedReceiptWrites++;
      throw StateError('synthetic receipt write failure');
    }
    await super.saveGroupBlob(o, k, v);
  }
}

void main() {
  test(
    'group history and offline outbox restore; local delete keeps membership',
    () async {
      final blobs = Blobs(), attachments = Attachments();
      var c = GroupController(
        ownerId: owner,
        crypto: ModelCrypto(),
        blobs: blobs,
        attachments: attachments,
        displayName: () => 'Alice',
      );
      await c.initialize();
      await c.createGroup('Team', []);
      expect(await c.sendText(gid, '**offline hello**'), isTrue);
      expect(c.messagesFor(gid).single.text, '**offline hello**');
      expect(c.pendingJobCount, 1);
      await c.close();
      c = GroupController(
        ownerId: owner,
        crypto: ModelCrypto(),
        blobs: blobs,
        attachments: attachments,
        displayName: () => 'Alice',
      );
      await c.initialize();
      expect(c.messagesFor(gid).single.text, '**offline hello**');
      expect(c.pendingJobCount, 1);
      await c.clearConversation(gid);
      expect(c.messagesFor(gid), isEmpty);
      expect(c.pendingJobCount, 0);
      expect(c.groups.single.groupId, gid);
      await c.close();
      final restored = GroupController(
        ownerId: owner,
        crypto: ModelCrypto(),
        blobs: blobs,
        attachments: attachments,
        displayName: () => 'Alice',
      );
      await restored.initialize();
      expect(restored.messagesFor(gid), isEmpty);
      expect(restored.groups, hasLength(1));
      expect(restored.pendingJobCount, 0);
      await restored.close();
    },
  );
  test(
    'closed controller never signs or persists a new outgoing message',
    () async {
      final c = GroupController(
        ownerId: owner,
        crypto: ModelCrypto(),
        blobs: Blobs(),
        attachments: Attachments(),
        displayName: () => 'Alice',
      );
      await c.initialize();
      await c.createGroup('Team', []);
      await c.close();
      expect(await c.sendText(gid, 'too late'), isFalse);
    },
  );
  test(
    'partial outbox write never publishes a message or orphan recipient job',
    () async {
      final blobs = FailingBlobs(), crypto = ModelCrypto()..memberCount = 3;
      final c = GroupController(
        ownerId: owner,
        crypto: crypto,
        blobs: blobs,
        attachments: Attachments(),
        displayName: () => 'Alice',
      );
      await c.initialize();
      await c.createGroup('Team', []);
      expect(await c.sendText(gid, 'must stay a draft'), isFalse);
      expect(c.messagesFor(gid), isEmpty);
      expect(c.pendingJobCount, 0);
      await c.close();
      final restored = GroupController(
        ownerId: owner,
        crypto: ModelCrypto(),
        blobs: blobs,
        attachments: Attachments(),
        displayName: () => 'Alice',
      );
      await restored.initialize();
      expect(restored.messagesFor(gid), isEmpty);
      expect(restored.pendingJobCount, 0);
      await restored.close();
    },
  );
  test(
    'offline outbox has an aggregate byte budget as well as a job count',
    () async {
      final c = GroupController(
        ownerId: owner,
        crypto: ModelCrypto()..memberCount = 16,
        blobs: Blobs(),
        attachments: Attachments(),
        displayName: () => 'Alice',
      );
      await c.initialize();
      await c.createGroup('Team', []);
      var rejected = false;
      for (var i = 0; i < 40; i++) {
        if (!await c.sendText(gid, 'x' * 32700)) {
          rejected = true;
          break;
        }
      }
      expect(rejected, isTrue);
      expect(c.pendingJobBytes, lessThanOrEqualTo(16 * 1024 * 1024));
      await c.close();
    },
  );
  test('owner closes group without sending its pending invitations', () async {
    final c = GroupController(
      ownerId: owner,
      crypto: ModelCrypto(),
      blobs: Blobs(),
      attachments: Attachments(),
      displayName: () => 'Alice',
    );
    await c.initialize();
    await c.createGroup('Team', []);
    await c.invite(gid, friend);
    expect(c.pendingJobCount, 1);
    await c.leaveGroup(gid);
    expect(c.groups.single.closed, isTrue);
    expect(c.pendingJobCount, 1);
    await c.close();
  });
  test('membership change during file import preserves the draft', () async {
    final c = GroupController(
      ownerId: owner,
      crypto: ModelCrypto(),
      blobs: Blobs(),
      attachments: Attachments(),
      displayName: () => 'Alice',
    );
    await c.initialize();
    await c.createGroup('Team', []);
    final source = PausedSource();
    final sending = c.sendBatch(gid, '', [
      ChatAttachment.fromSource(
        name: 'paused.bin',
        mimeType: 'application/octet-stream',
        source: source,
      ),
    ]);
    await source.entered.future;
    await c.removeMember(gid, 'did:cht:${'1'.padLeft(64, '0')}');
    source.gate.complete();
    expect(await sending, isFalse);
    expect(c.messagesFor(gid), isEmpty);
    await c.close();
  });
  test('file completion retries receipt and persistence after a transient write failure', () async {
    final blobs = FailOnceReceiptBlobs(), attachments = Attachments();
    final crypto = ModelCrypto();
    var c = GroupController(
      ownerId: owner,
      crypto: crypto,
      blobs: blobs,
      attachments: attachments,
      displayName: () => 'Alice',
    );
    await c.initialize();
    await c.createGroup('Team', []);
    final fileId = List.filled(32, 'd').join();
    final file = ChatAttachment(
      name: 'empty.bin',
      mimeType: 'application/octet-stream',
      bytes: Uint8List(0),
    );
    final manifest = await c.cache.importFile(
      groupId: gid,
      epoch: 1,
      uploaderId: friend,
      fileId: fileId,
      file: file,
    );
    await c.close();

    final message = GroupMessage(
      id: 'incoming-file',
      groupId: gid,
      senderId: friend,
      senderName: 'Bob',
      text: 'empty.bin',
      event: '{}',
      sentAt: 1,
      recipients: const [],
      manifest: manifest,
    );
    final index = Map<String, dynamic>.from(
      jsonDecode(blobs.m['$owner:groups-index-v1']!) as Map,
    );
    index['rooms'] = {gid: 1};
    blobs.m['$owner:groups-index-v1'] = jsonEncode(index);
    final roomKey = sha256.convert(utf8.encode(gid)).toString();
    blobs.m['$owner:g-room-$roomKey-0'] = jsonEncode({
      'messages': [message.toJson()],
    });

    c = GroupController(
      ownerId: owner,
      crypto: crypto,
      blobs: blobs,
      attachments: attachments,
      displayName: () => 'Alice',
    );
    await c.initialize();
    await c.swarm.tick();
    await c.flush();
    expect(blobs.failedReceiptWrites, 1);
    expect(c.pendingJobCount, 0);

    await Future<void>.delayed(const Duration(milliseconds: 2100));
    await c.flush();
    expect(c.pendingJobCount, 1);
    final saved = jsonDecode(blobs.m['$owner:groups-index-v1']!) as Map;
    expect(saved['completedFiles'], contains(fileId));
    await c.close();
  });

  test(
    'a locally left accepted invitation sends leave after owner finalizes it',
    () async {
      final blobs = Blobs();
      final crypto = ModelCrypto(accountId: friend)..memberCount = 1;
      var c = GroupController(
        ownerId: friend,
        crypto: crypto,
        blobs: blobs,
        attachments: Attachments(),
        displayName: () => 'Bob',
      );
      await c.initialize();
      final groupId = await c.createGroup('Team', []);
      await c.close();

      const invitationId = 'pending-invite';
      final index = Map<String, dynamic>.from(
        jsonDecode(blobs.m['$friend:groups-index-v1']!) as Map,
      );
      index['invitations'] = [invitationId];
      blobs.m['$friend:groups-index-v1'] = jsonEncode(index);
      blobs.m['$friend:g-invite-$invitationId'] = jsonEncode({
        'id': invitationId,
        'source': jsonEncode({
          'state': jsonEncode({'groupId': groupId}),
        }),
        'groupId': groupId,
        'name': 'Team',
        'ownerId': owner,
        'expiresAt': DateTime.now().millisecondsSinceEpoch + 60000,
      });

      c = GroupController(
        ownerId: friend,
        crypto: crypto,
        blobs: blobs,
        attachments: Attachments(),
        displayName: () => 'Bob',
      );
      await c.initialize();
      await c.acceptInvitation(invitationId);
      await c.leaveGroup(groupId);
      expect(c.canSend(groupId), isFalse);
      expect(c.pendingJobCount, 0);
      await c.close();

      crypto.includeFriend = true;
      crypto.groups[groupId] = crypto.view();
      final finalized = Map<String, dynamic>.from(
        jsonDecode(blobs.m['$friend:groups-index-v1']!) as Map,
      );
      finalized['core'] = jsonEncode(crypto.groups);
      blobs.m['$friend:groups-index-v1'] = jsonEncode(finalized);

      c = GroupController(
        ownerId: friend,
        crypto: crypto,
        blobs: blobs,
        attachments: Attachments(),
        displayName: () => 'Bob',
      );
      await c.initialize();
      expect(c.canSend(groupId), isFalse);
      expect(c.pendingJobCount, 1);
      final jobIds =
          (jsonDecode(blobs.m['$friend:groups-index-v1']!) as Map)
                  .cast<String, dynamic>()['jobs']
              as List;
      final job = jsonDecode(blobs.m['$friend:g-job-${jobIds.single}']!) as Map;
      expect(job['peerId'], owner);
      expect(
        (jsonDecode(job['body']['source'] as String) as Map)['kind'],
        'leave',
      );
      await c.close();
    },
  );
  test('history boundary rejects before saving an unrestorable room', () async {
    final blobs = Blobs();
    var c = GroupController(
      ownerId: owner,
      crypto: ModelCrypto(),
      blobs: blobs,
      attachments: Attachments(),
      displayName: () => 'Alice',
    );
    await c.initialize();
    await c.createGroup('Team', []);
    await c.close();
    final index =
        jsonDecode(blobs.m['$owner:groups-index-v1']!) as Map<String, dynamic>;
    index['rooms'] = {gid: 10000};
    blobs.m['$owner:groups-index-v1'] = jsonEncode(index);
    final hash = sha256.convert(utf8.encode(gid)).toString();
    for (var page = 0; page < 313; page++) {
      blobs.m['$owner:g-room-$hash-$page'] = jsonEncode({
        'messages': List.generate(
          32,
          (i) => {
            'id': 'old-${page * 32 + i}',
            'groupId': gid,
            'senderId': owner,
            'senderName': 'Alice',
            'text': 'old',
            'event': '{}',
            'sentAt': 1,
            'receivedAt': null,
            'recipients': <String>[],
            'receipts': <String, int>{},
          },
        ),
      });
    }
    c = GroupController(
      ownerId: owner,
      crypto: ModelCrypto(),
      blobs: blobs,
      attachments: Attachments(),
      displayName: () => 'Alice',
    );
    await c.initialize();
    expect(c.messagesFor(gid), hasLength(10000));
    expect(await c.sendText(gid, 'keep as draft'), isFalse);
    expect(c.messagesFor(gid), hasLength(10000));
    await c.close();
  });
}
