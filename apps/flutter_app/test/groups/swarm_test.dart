import 'dart:typed_data';
import 'dart:convert';

import 'package:cht/chat/attachment_ref.dart';
import 'package:cht/chat/attachment_store.dart';
import 'package:cht/chat/chat_attachment.dart';
import 'package:cht/groups/group_blob_bridge.dart';
import 'package:cht/groups/swarm/swarm.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

class Blobs implements GroupBlobBridge {
  final m = <String, String>{};
  @override
  Future<String?> loadGroupBlob(String o, String k) async => m['$o:$k'];
  @override
  Future<void> saveGroupBlob(String o, String k, String v) async {
    m['$o:$k'] = v;
  }

  @override
  Future<void> deleteGroupBlob(String o, String k) async {
    m.remove('$o:$k');
  }
}

class Attachments implements AttachmentStore {
  final m = <String, Uint8List>{};
  @override
  Future<AttachmentRef> put(String o, ChatAttachment f) async {
    final d = sha256.convert(f.bytes).toString();
    m['$o:$d'] = f.bytes;
    return AttachmentRef(
      name: f.name,
      mimeType: f.mimeType,
      size: f.size,
      digest: d,
    );
  }

  @override
  Future<ChatAttachment> read(String o, AttachmentRef r) async =>
      ChatAttachment(
        name: r.name,
        mimeType: r.mimeType,
        bytes: m['$o:${r.digest}']!,
      );
}

void main() {
  const owner =
      'did:cht:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const group =
      'group:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  const file = 'cccccccccccccccccccccccccccccccc';
  test('canonical Merkle roots for empty and abc', () async {
    final cache = SparseSwarmCache(
      owner,
      blobs: Blobs(),
      attachments: Attachments(),
    );
    final empty = await cache.importFile(
      groupId: group,
      epoch: 1,
      uploaderId: owner,
      fileId: file,
      file: ChatAttachment(
        name: 'empty.bin',
        mimeType: 'application/octet-stream',
        bytes: Uint8List(0),
      ),
    );
    expect(
      empty.merkleRoot,
      '395c2f5598a1643a205154c6f4c46ce36895b28e6c35660a95e5c6fd5ef9aeab',
    );
    final abc = await cache.importFile(
      groupId: group,
      epoch: 1,
      uploaderId: owner,
      fileId: 'dddddddddddddddddddddddddddddddd',
      file: ChatAttachment(
        name: 'abc.bin',
        mimeType: 'application/octet-stream',
        bytes: Uint8List.fromList([97, 98, 99]),
      ),
    );
    expect(
      abc.merkleRoot,
      '3ff3f22b0f8c2a1553022e4cba10e16915655cf0d3f4c908c950ab539ec2d9b6',
    );
  });
  test('relay source waits when file exceeds 25 MiB', () async {
    const peer =
        'did:cht:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    final manifest = SwarmManifest(
      groupId: group,
      epoch: 1,
      uploaderId: owner,
      fileId: file,
      name: 'large.bin',
      mimeType: 'application/octet-stream',
      size: swarmMaxRelayBytes + 1,
      pieceSize: swarmPieceSize,
      digest: List.filled(64, 'a').join(),
      merkleRoot: List.filled(64, 'b').join(),
    );
    final sent = <String>[];
    final transfer = SwarmTransfer(
      owner,
      cache: SparseSwarmCache(
        owner,
        blobs: Blobs(),
        attachments: Attachments(),
      ),
      authorize: (_, _) => true,
      peers: (_) => [peer],
      isDirect: (_) => false,
      send: (_, frame) async {
        sent.add(frame);
      },
      onComplete: (_) {},
    );
    transfer.register(manifest);
    final bits = base64UrlEncode([
      1,
      ...List<int>.filled((manifest.pieceCount + 7) ~/ 8 - 1, 0),
    ]);
    await transfer.receive(
      peer,
      'chta-swarm-v1:${jsonEncode({'kind': 'have', 'fileId': file, 'manifest': manifest.identityHash, 'bits': bits})}',
    );
    await transfer.tick();
    expect(transfer.progressFor(file)!.waitingForDirect, isTrue);
    expect(sent.where((frame) => frame.contains('"kind":"request"')), isEmpty);
    transfer.close();
  });
  test('revoked source receives no piece requests after advertising', () async {
    const peer =
        'did:cht:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    final manifest = SwarmManifest(
      groupId: group,
      epoch: 1,
      uploaderId: owner,
      fileId: file,
      name: 'small.bin',
      mimeType: 'application/octet-stream',
      size: 1,
      pieceSize: swarmPieceSize,
      digest: List.filled(64, 'a').join(),
      merkleRoot: List.filled(64, 'b').join(),
    );
    var authorized = true;
    final sent = <String>[];
    final transfer = SwarmTransfer(
      owner,
      cache: SparseSwarmCache(
        owner,
        blobs: Blobs(),
        attachments: Attachments(),
      ),
      authorize: (_, _) => authorized,
      peers: (_) => [peer],
      isDirect: (_) => true,
      send: (_, frame) async {
        sent.add(frame);
      },
      onComplete: (_) {},
    );
    transfer.register(manifest);
    await transfer.receive(
      peer,
      'chta-swarm-v1:${jsonEncode({
        'kind': 'have',
        'fileId': file,
        'manifest': manifest.identityHash,
        'bits': base64UrlEncode([1]),
      })}',
    );
    authorized = false;
    await transfer.tick();
    expect(sent.where((frame) => frame.contains('"kind":"request"')), isEmpty);
    await expectLater(
      transfer.receive(
        peer,
        'chta-swarm-v1:${jsonEncode({
          'kind': 'have',
          'fileId': file,
          'manifest': manifest.identityHash,
          'bits': base64UrlEncode([1]),
        })}',
      ),
      throwsFormatException,
    );
    transfer.close();
  });
  test('restart reads disjoint verified pieces and exact range', () async {
    final blobs = Blobs(), attachments = Attachments();
    final source = Uint8List.fromList(List.generate(600000, (i) => i % 251));
    final a = SparseSwarmCache(owner, blobs: blobs, attachments: attachments);
    final manifest = await a.importFile(
      groupId: group,
      epoch: 1,
      uploaderId: owner,
      fileId: file,
      file: ChatAttachment(
        name: 'video.mp4',
        mimeType: 'video/mp4',
        bytes: source,
      ),
    );
    final b = SparseSwarmCache(owner, blobs: blobs, attachments: attachments);
    expect((await b.status(manifest)).complete, isTrue);
    final opened = await b.open(manifest);
    expect(
      await opened
          .openRead(start: 260000, end: 270000)
          .expand((x) => x)
          .toList(),
      source.sublist(260000, 270000),
    );
  });
  test('corrupt piece and wrong index proof are rejected', () async {
    final source = Uint8List.fromList(List.generate(300000, (i) => i % 251));
    final a = SparseSwarmCache(
      owner,
      blobs: Blobs(),
      attachments: Attachments(),
    );
    final manifest = await a.importFile(
      groupId: group,
      epoch: 1,
      uploaderId: owner,
      fileId: file,
      file: ChatAttachment(
        name: 'x.bin',
        mimeType: 'application/octet-stream',
        bytes: source,
      ),
    );
    final piece = await a.readPiece(manifest, 0);
    final b = SparseSwarmCache(
      owner,
      blobs: Blobs(),
      attachments: Attachments(),
    );
    await b.begin(manifest);
    await expectLater(
      b.putPiece(manifest, 1, piece.bytes, piece.proof),
      throwsFormatException,
    );
    final corrupt = Uint8List.fromList(piece.bytes)..[0] ^= 1;
    await expectLater(
      b.putPiece(manifest, 0, corrupt, piece.proof),
      throwsFormatException,
    );
    expect((await b.status(manifest)).available, isEmpty);
    await b.putPiece(manifest, 0, piece.bytes, piece.proof);
    expect((await b.status(manifest)).available, {0});
  });
  test('offline uploader is replaced by complementary B and C sources', () async {
    final source = Uint8List.fromList(List.generate(600000, (i) => i % 251));
    SparseSwarmCache cache(String o) =>
        SparseSwarmCache(o, blobs: Blobs(), attachments: Attachments());
    const b =
        'did:cht:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    const c =
        'did:cht:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
    const d =
        'did:cht:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';
    final aCache = cache(owner), bCache = cache(b), cCache = cache(c);
    final dBlobs = Blobs(), dAttachments = Attachments();
    final firstD = SparseSwarmCache(
      d,
      blobs: dBlobs,
      attachments: dAttachments,
    );
    final manifest = await aCache.importFile(
      groupId: group,
      epoch: 1,
      uploaderId: owner,
      fileId: file,
      file: ChatAttachment(
        name: 'x.bin',
        mimeType: 'application/octet-stream',
        bytes: source,
      ),
    );
    for (final i in [0, 2]) {
      final p = await aCache.readPiece(manifest, i);
      await bCache.putPiece(manifest, i, p.bytes, p.proof);
    }
    final one = await aCache.readPiece(manifest, 1);
    await cCache.putPiece(manifest, 1, one.bytes, one.proof);
    final first = await aCache.readPiece(manifest, 0);
    await firstD.putPiece(manifest, 0, first.bytes, first.proof);
    final dCache = SparseSwarmCache(
      d,
      blobs: dBlobs,
      attachments: dAttachments,
    );
    expect((await dCache.status(manifest)).available, {0});
    final peers = <String, SwarmTransfer>{};
    final used = <String>{};
    SwarmTransfer node(
      String id,
      SparseSwarmCache local,
      List<String> others,
    ) => SwarmTransfer(
      id,
      cache: local,
      authorize: (peer, m) => others.contains(peer),
      peers: (_) => others,
      isDirect: (_) => true,
      send: (peer, frame) async {
        if (frame.contains('"kind":"part"') && (id == b || id == c)) {
          used.add(id);
        }
        await peers[peer]!.receive(id, frame);
      },
      onComplete: (_) => {},
    );
    peers[b] = node(b, bCache, [c, d]);
    peers[c] = node(c, cCache, [b, d]);
    peers[d] = node(d, dCache, [b, c]);
    for (final t in peers.values) {
      t.register(manifest);
    }
    await peers[b]!.tick();
    await peers[c]!.tick();
    for (var i = 0; i < 8 && !(await dCache.status(manifest)).complete; i++) {
      await peers[d]!.tick();
    }
    expect((await dCache.status(manifest)).complete, isTrue);
    expect(used, {b, c});
    final result = await dCache.open(manifest);
    expect(
      sha256
          .convert(await result.openRead().expand((part) => part).toList())
          .toString(),
      manifest.digest,
    );
  });
}
