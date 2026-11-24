import 'dart:convert';
import 'dart:async';

import 'package:cht/chat/chat_attachment.dart';
import 'package:cht/courier/courier_receiver.dart';
import 'package:cht/delivery/delivery_envelope.dart';
import 'package:cht/delivery/group_delivery_sink.dart';
import 'package:cht/groups/group_controller.dart';
import 'package:cht/groups/swarm/swarm.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:cht/groups/group_transport.dart';

import '../groups/group_controller_test.dart' as g;
import '../groups/swarm_test.dart' show Blobs, Attachments;
import 'delivery_envelope_test.dart' as root;

class GroupCrypto extends g.ModelCrypto {
  GroupCrypto() : super(accountId: g.friend) {
    includeFriend = true;
  }
  bool allowed = true;
  @override
  Future<Map<String, Object?>> groupCall(
    String op,
    Map<String, Object?> args,
  ) async {
    if (op == 'inspect') {
      return Map<String, Object?>.from(
        jsonDecode(args['event'] as String) as Map,
      );
    }
    if (op == 'authorize') return {'allowed': allowed};
    return super.groupCall(op, args);
  }
}

class FailingRoom extends Blobs {
  bool fail = false;
  @override
  Future<void> saveGroupBlob(String owner, String key, String value) async {
    if (fail && key.startsWith('g-room-')) {
      throw StateError('Synthetic room write failure');
    }
    await super.saveGroupBlob(owner, key, value);
  }
}

class Transport extends ChangeNotifier implements GroupTransport {
  final stream = StreamController<GroupPeerFrame>.broadcast(),
      sent = <String>[];
  @override
  Stream<GroupPeerFrame> get frames => stream.stream;
  @override
  Set<String> get onlinePeers => {g.owner};
  @override
  bool connected(String peer) => peer == g.owner;
  @override
  Future<void> start() async {}
  @override
  Future<void> connect(String peer) async {}
  @override
  Future<void> send(String peer, String text) async {
    sent.add(text);
  }

  @override
  bool isDirect(String peer) => false;
  @override
  Future<void> close() async {
    await stream.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<DeliveryEnvelope> message({
  String id = 'original',
  SwarmManifest? manifest,
}) async {
  final source = jsonEncode({
    'groupId': g.gid,
    'sender': g.owner,
    'id': id,
    'epoch': 1,
    'kind': manifest == null ? 'message' : 'file',
    'sentAt': 1000,
    'payload': jsonEncode(manifest?.toJson() ?? {'text': 'hello'}),
  });
  return DeliveryEnvelope.create(
    root.Crypto(),
    scope: '${g.gid}:1',
    messageId: id,
    sentAt: 1000,
    kind: 'group',
    payload: {
      'groupEvent': source,
      'text': manifest?.name ?? 'hello',
      if (manifest != null)
        'file': {
          'name': manifest.name,
          'mime': manifest.mimeType,
          'size': manifest.size,
          'digest': manifest.digest,
        },
    },
  );
}

void main() {
  test(
    'failed group history is ineligible for a duplicate receipt until saved',
    () async {
      final blobs = FailingRoom(),
          controller = GroupController(
            ownerId: g.friend,
            crypto: GroupCrypto(),
            blobs: blobs,
            attachments: Attachments(),
            displayName: () => 'Bob',
          );
      await controller.initialize();
      await controller.createGroup('Team', []);
      final sink = GroupDeliverySink(
            controller: controller,
            crypto: root.Crypto(),
          ),
          e = await message();
      blobs.fail = true;
      await expectLater(
        sink.commit(CourierReceived(e, 2000)),
        throwsStateError,
      );
      expect(await sink.existingReceivedAt(e), isNull);
      blobs.fail = false;
      await sink.commit(CourierReceived(e, 4000));
      expect(await sink.existingReceivedAt(e), 2000);
      await controller.close();
    },
  );
  test('nonfriend roster peers negotiate Courier capability over authenticated group transport and remember it', () async {
    final blobs = Blobs(),
        controller = GroupController(
          ownerId: g.friend,
          crypto: GroupCrypto(),
          blobs: blobs,
          attachments: Attachments(),
          displayName: () => 'Bob',
        ),
        transport = Transport();
    await controller.initialize();
    await controller.createGroup('Team', []);
    controller.setCourierEnabled(true);
    await controller.attachTransport(transport);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(transport.sent, contains('chta-group-cap-v1:courier-v1'));
    transport.stream.add(
      GroupPeerFrame(g.owner, 'chta-group-cap-v1:courier-v1'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await controller.flush();
    expect(controller.supportsCourier(g.owner), isTrue);
    await controller.close();
    final restored = GroupController(
      ownerId: g.friend,
      crypto: GroupCrypto(),
      blobs: blobs,
      attachments: Attachments(),
      displayName: () => 'Bob',
    );
    await restored.initialize();
    expect(restored.supportsCourier(g.owner), isTrue);
    await restored.close();
  });
  test('group Courier commits the original signed event once, preserves receive time and rejects deleted or revoked scopes', () async {
    final blobs = Blobs(),
        crypto = GroupCrypto(),
        controller = GroupController(
          ownerId: g.friend,
          crypto: crypto,
          blobs: blobs,
          attachments: Attachments(),
          displayName: () => 'Bob',
        );
    await controller.initialize();
    await controller.createGroup('Team', []);
    final sink = GroupDeliverySink(
      controller: controller,
      crypto: root.Crypto(),
    );
    final e = await message();
    await sink.commit(CourierReceived(e, 2000));
    await sink.commit(CourierReceived(e, 4000));
    expect(controller.messagesFor(g.gid), hasLength(1));
    expect(await sink.existingReceivedAt(e), 2000);
    expect(controller.messagesFor(g.gid).single.deliveryEnvelope, isNotNull);
    crypto.allowed = false;
    expect(await sink.authorize(e), isFalse);
    await expectLater(sink.commit(CourierReceived(e, 5000)), throwsStateError);
    crypto.allowed = true;
    await controller.clearConversation(g.gid);
    final unseen = await message(id: 'unseen');
    expect(sink.isDeleted(unseen), isTrue);
    await expectLater(
      sink.commit(CourierReceived(unseen, 5000)),
      throwsStateError,
    );
    expect(controller.messagesFor(g.gid), isEmpty);
    await controller.close();
  });
  test('group Courier imports a verified file into the existing swarm before acknowledging its event', () async {
    final blobs = Blobs(),
        attachments = Attachments(),
        crypto = GroupCrypto(),
        controller = GroupController(
          ownerId: g.friend,
          crypto: crypto,
          blobs: blobs,
          attachments: Attachments(),
          displayName: () => 'Bob',
        );
    await controller.initialize();
    await controller.createGroup('Team', []);
    final file = ChatAttachment(
      name: 'small.bin',
      mimeType: 'application/octet-stream',
      bytes: Uint8List.fromList([1, 2, 3]),
    );
    final manifest =
        await SparseSwarmCache(
          g.owner,
          blobs: blobs,
          attachments: attachments,
        ).importFile(
          groupId: g.gid,
          epoch: 1,
          uploaderId: g.owner,
          fileId: 'd' * 32,
          file: file,
        );
    final ref = await controller.attachments.put(g.friend, file),
        sink = GroupDeliverySink(controller: controller, crypto: root.Crypto()),
        e = await message(manifest: manifest);
    await expectLater(sink.commit(CourierReceived(e, 2000)), throwsStateError);
    await sink.commit(CourierReceived(e, 2000, attachment: ref));
    expect((await controller.cache.status(manifest)).complete, isTrue);
    expect(
      await (await controller.openFile(manifest))
          .openRead()
          .expand((bytes) => bytes)
          .toList(),
      [1, 2, 3],
    );
    expect(await sink.existingReceivedAt(e), 2000);
    await controller.close();
  });
}
