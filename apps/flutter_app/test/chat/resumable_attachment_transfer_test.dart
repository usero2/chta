import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cht/chat/attachment_ref.dart';
import 'package:cht/chat/chunked_attachment_bridge.dart';
import 'package:cht/chat/resumable_attachment_transfer.dart';

void main() {
  test(
    'durable blocks resume after interruption and never buffer a file',
    () async {
      final sender = _Cache(), receiver = _Cache();
      const owner = 'owner',
          peer = 'peer',
          id = 'file-transfer-fixture-01',
          cacheId = 'sender-cache-fixture-01';
      final data = Uint8List.fromList(List.generate(131072, (i) => i % 251));
      await sender.beginChunkedAttachment(owner, cacheId, data.length, 16384);
      for (var i = 0; i < 8; i++) {
        await sender.writeChunkedAttachment(
          owner,
          cacheId,
          i,
          Uint8List.sublistView(data, i * 16384, (i + 1) * 16384),
        );
      }
      final state = await sender.finishChunkedAttachment(owner, cacheId);
      final ref = AttachmentRef(
        name: 'sample.bin',
        mimeType: 'application/octet-stream',
        size: data.length,
        digest: state.digest!,
        chunkedId: cacheId,
        chunkSize: 16384,
      );
      late ResumableAttachmentTransfer a, b;
      var completed = 0, offered = 0, interrupted = false;
      a = ResumableAttachmentTransfer(
        ownerId: owner,
        peerId: peer,
        bridge: sender,
        isDirect: () => true,
        sendPacket: (packet, text) async {
          if (!interrupted && receiver.writes == 2) {
            interrupted = true;
            throw StateError('link lost');
          }
          await b.receive(packet, text, direct: true);
        },
        onOffer: (id, ref, sentAt) async {},
        onCompleted: (id, ref) async => 1,
        ackTimeout: const Duration(milliseconds: 200),
      );
      b = ResumableAttachmentTransfer(
        ownerId: peer,
        peerId: owner,
        bridge: receiver,
        isDirect: () => true,
        sendPacket: (packet, text) async {
          await a.receive(packet, text, direct: true);
        },
        onOffer: (id, ref, sentAt) async {
          offered++;
        },
        onCompleted: (id, ref) async {
          completed++;
          return 1234;
        },
      );
      await expectLater(
        a.send(id, ref, sentAtMilliseconds: 1),
        throwsA(isA<TransferInterrupted>()),
      );
      expect(receiver.writes, 2);
      expect(await a.send(id, ref, sentAtMilliseconds: 1), 1234);
      expect(receiver.writes, 8);
      expect(completed, 1);
      expect(offered, 2);
      expect(receiver.maxWrite, 16384);
      expect(receiver.states.values.single.completed, true);
      a.dispose();
      b.dispose();
    },
  );
  test('a large file offer on relay is rejected before cache allocation', () async {
    final cache = _Cache();
    final transfer = ResumableAttachmentTransfer(
      ownerId: 'owner',
      peerId: 'peer',
      bridge: cache,
      isDirect: () => false,
      sendPacket: (id, text) async {},
      onOffer: (id, ref, time) async {},
      onCompleted: (id, ref) async => 1,
    );
    await transfer.receive(
      'chtfile2_offer',
      '{"v":2,"type":"offer","id":"file-transfer-fixture-02","name":"large.bin","mimeType":"application/octet-stream","size":134217728,"digest":"${'a' * 64}","chunkSize":262144}',
      direct: false,
    );
    expect(cache.states, isEmpty);
    transfer.dispose();
  });
  test('same-id sends reserve a slot before cache lookup', () async {
    final cache = _Cache()..statusGate = Completer<void>();
    const key = 'source-cache-fixture-02';
    await cache.beginChunkedAttachment('owner', key, 0, 262144);
    final state = await cache.finishChunkedAttachment('owner', key);
    final ref = AttachmentRef(
      name: 'empty.bin',
      mimeType: 'application/octet-stream',
      size: 0,
      digest: state.digest!,
      chunkedId: key,
      chunkSize: 262144,
    );
    final transfer = ResumableAttachmentTransfer(
      ownerId: 'owner',
      peerId: 'peer',
      bridge: cache,
      isDirect: () => true,
      sendPacket: (id, text) async {},
      onOffer: (id, ref, time) async {},
      onCompleted: (id, ref) async => 1,
      ackTimeout: const Duration(milliseconds: 20),
    );
    final firstCheck = expectLater(
      transfer.send('same-transfer-fixture-01', ref),
      throwsA(isA<TransferInterrupted>()),
    );
    final duplicateCheck = expectLater(
      transfer.send('same-transfer-fixture-01', ref),
      throwsA(isA<TransferInterrupted>()),
    );
    expect(cache.statusCalls, 1);
    transfer.disconnected();
    cache.statusGate!.complete();
    await firstCheck;
    await duplicateCheck;
    transfer.dispose();
  });
  test('completed offer rechecks current bytes before Delivered', () async {
    final cache = _Cache();
    const id = 'completed-fixture-001';
    final key = sha256.convert(utf8.encode('peer:$id')).toString();
    await cache.beginChunkedAttachment('owner', key, 4, 4);
    await cache.writeChunkedAttachment(
      'owner',
      key,
      0,
      Uint8List.fromList([1, 2, 3, 4]),
    );
    final complete = await cache.finishChunkedAttachment('owner', key);
    cache.blocks[key]![0][0] = 99;
    final replies = <String>[];
    var delivered = false;
    final transfer = ResumableAttachmentTransfer(
      ownerId: 'owner',
      peerId: 'peer',
      bridge: cache,
      isDirect: () => true,
      sendPacket: (id, text) async {
        replies.add(text);
      },
      onOffer: (id, ref, time) async {},
      onCompleted: (id, ref) async {
        delivered = true;
        return 1;
      },
    );
    await transfer.receive(
      'chtfile2_offer',
      jsonEncode({
        'v': 2,
        'type': 'offer',
        'id': id,
        'name': 'small.bin',
        'mimeType': 'application/octet-stream',
        'size': 4,
        'digest': complete.digest!,
        'chunkSize': 4,
      }),
      direct: true,
    );
    expect(delivered, false);
    expect(replies.single, contains('error'));
    transfer.dispose();
  });
  test(
    'invalid file timestamps never enter history or allocate cache',
    () async {
      final cache = _Cache();
      var offered = false;
      final transfer = ResumableAttachmentTransfer(
        ownerId: 'owner',
        peerId: 'peer',
        bridge: cache,
        isDirect: () => true,
        sendPacket: (id, text) async {},
        onOffer: (id, ref, time) async {
          offered = true;
        },
        onCompleted: (id, ref) async => 1,
      );
      await transfer.receive(
        'chtfile2_offer',
        jsonEncode({
          'v': 2,
          'type': 'offer',
          'id': 'bad-timestamp-fixture-01',
          'name': 'empty.bin',
          'mimeType': 'application/octet-stream',
          'size': 0,
          'digest': 'a' * 64,
          'chunkSize': 262144,
          'sentAt': 9000000000000000000,
        }),
        direct: true,
      );
      expect(offered, false);
      expect(cache.states, isEmpty);
      transfer.dispose();
    },
  );
}

class _Cache implements ChunkedAttachmentBridge {
  final states = <String, ChunkedAttachmentState>{};
  final blocks = <String, List<Uint8List>>{};
  int writes = 0, maxWrite = 0;
  int statusCalls = 0;
  Completer<void>? statusGate;
  @override
  Future<ChunkedAttachmentState> beginChunkedAttachment(
    String owner,
    String id,
    int size,
    int chunkSize, {
    String? digest,
  }) async {
    if (states.containsKey(id)) return states[id]!;
    blocks[id] = [];
    return states[id] = ChunkedAttachmentState(
      id: id,
      size: size,
      chunkSize: chunkSize,
      contiguousChunks: 0,
      completed: false,
      digest: digest,
    );
  }

  @override
  Future<ChunkedAttachmentState> chunkedAttachmentStatus(
    String owner,
    String id,
  ) async {
    statusCalls++;
    await statusGate?.future;
    return states[id]!;
  }

  @override
  Future<void> writeChunkedAttachment(
    String owner,
    String id,
    int index,
    Uint8List bytes,
  ) async {
    final s = states[id]!;
    if (index < s.contiguousChunks) return;
    if (index != s.contiguousChunks) throw StateError('gap');
    writes++;
    if (bytes.length > maxWrite) maxWrite = bytes.length;
    blocks[id]!.add(Uint8List.fromList(bytes));
    states[id] = ChunkedAttachmentState(
      id: id,
      size: s.size,
      chunkSize: s.chunkSize,
      contiguousChunks: index + 1,
      completed: false,
      digest: s.digest,
    );
  }

  @override
  Future<Uint8List> readChunkedAttachment(
    String owner,
    String id,
    int index,
  ) async => blocks[id]![index];
  @override
  Future<ChunkedAttachmentState> finishChunkedAttachment(
    String owner,
    String id, {
    String? expectedDigest,
  }) async {
    final s = states[id]!;
    final bytes = BytesBuilder();
    for (final b in blocks[id]!) {
      bytes.add(b);
    }
    final digest = sha256.convert(bytes.takeBytes()).toString();
    if (expectedDigest != null && digest != expectedDigest) {
      throw StateError('digest');
    }
    return states[id] = ChunkedAttachmentState(
      id: id,
      size: s.size,
      chunkSize: s.chunkSize,
      contiguousChunks: s.contiguousChunks,
      completed: true,
      digest: digest,
    );
  }

  @override
  Future<void> deleteChunkedAttachment(String owner, String id) async {
    states.remove(id);
    blocks.remove(id);
  }
}
