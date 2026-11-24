import 'dart:typed_data';
import 'dart:convert';

import 'package:cht/chat/cache_policy.dart';
import 'package:cht/chat/managed_attachment_cache.dart';
import 'package:cht/chat/chat_attachment.dart';
import 'package:cht/chat/peer_history.dart';
import 'package:cht/chat/attachment_store.dart';
import 'package:cht/chat/attachment_ref.dart';
import 'package:cht/chat/attachment_source.dart';
import 'package:cht/chat/chunked_attachment_bridge.dart';
import 'package:cht/chat/chunked_file_cache.dart';
import 'package:flutter_test/flutter_test.dart';

import '../groups/swarm_test.dart' show Attachments;

import 'package:cht/groups/swarm/swarm.dart';

import 'room_history_store_test.dart' show Blobs;
import 'durable_outbox_test.dart' show Store;

void main() {
  for (final retainedPieces in [0, 1]) {
    test(
      'aborted group import retains only cached piece bytes count=$retainedPieces',
      () async {
        const owner =
            'did:cht:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
        final policy = CachePolicy(
          ownerId: owner,
          settings: Blobs(),
          availableSpace: () async => null,
        );
        final cache = SparseSwarmCache(
          owner,
          blobs: Blobs(),
          attachments: BudgetedAttachmentStore(
            FailedGroupAttachments(retainedPieces),
            policy,
          ),
        );
        await expectLater(
          cache.importFile(
            groupId: 'group:${'b' * 64}',
            epoch: 1,
            uploaderId: owner,
            fileId: 'c' * 32,
            file: ChatAttachment(
              name: 'fixture.bin',
              mimeType: 'application/octet-stream',
              bytes: Uint8List(swarmPieceSize * 2 + 10),
            ),
          ),
          throwsStateError,
        );
        expect(policy.reservedBytes, retainedPieces * (swarmPieceSize + 32));
        policy.dispose();
      },
    );
  }
  for (final partial in [false, true]) {
    test(
      'aborted streamed staging import releases reservation after cleanup partial=$partial',
      () async {
        final policy = CachePolicy(
          ownerId: 'owner',
          settings: Blobs(),
          availableSpace: () async => null,
        );
        final raw = StagingCache();
        final store = HybridAttachmentStore(
          Attachments(),
          ChunkedFileCache(BudgetedChunkCache(raw, policy)),
        );
        final file = ChatAttachment.fromSource(
          name: 'broken.bin',
          mimeType: 'application/octet-stream',
          source: BrokenSource(partial),
        );
        for (var attempt = 0; attempt < 2; attempt++) {
          await expectLater(store.put('owner', file), throwsStateError);
          expect(policy.reservedBytes, 0);
          expect(raw.ids, isEmpty);
        }
        policy.dispose();
      },
    );
  }
  test(
    'failed atomic legacy import does not leave an empty reservation',
    () async {
      final policy = CachePolicy(
        ownerId: 'owner',
        settings: Blobs(),
        availableSpace: () async => null,
      );
      final store = BudgetedAttachmentStore(
        BridgeAttachmentStore(FailedLegacyBridge()),
        policy,
      );
      await expectLater(
        store.put(
          'owner',
          ChatAttachment(
            name: 'broken.bin',
            mimeType: 'application/octet-stream',
            bytes: Uint8List(20),
          ),
        ),
        throwsStateError,
      );
      expect(policy.reservedBytes, 0);
      policy.dispose();
    },
  );
  test('group pieces share a single full-file reservation', () async {
    const owner =
        'did:cht:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    final settings = Blobs();
    final policy = CachePolicy(
      ownerId: owner,
      settings: settings,
      availableSpace: () async => null,
    );
    final cache = SparseSwarmCache(
      owner,
      blobs: Blobs(),
      attachments: BudgetedAttachmentStore(Attachments(), policy),
    );
    final bytes = Uint8List(swarmPieceSize * 2 + 10);
    final manifest = await cache.importFile(
      groupId: 'group:${'b' * 64}',
      epoch: 1,
      uploaderId: owner,
      fileId: 'c' * 32,
      file: ChatAttachment(
        name: 'fixture.bin',
        mimeType: 'application/octet-stream',
        bytes: bytes,
      ),
    );
    expect(policy.reservedBytes, bytes.length + 32 * manifest.pieceCount);
    expect((await cache.status(manifest)).complete, isTrue);
    await policy.flush();
    expect(
      (jsonDecode(settings.values.values.single)['entries'] as Map).length,
      1,
    );
    policy.dispose();
  });
  test(
    'budget is checked before caching bytes and duplicate files count once',
    () async {
      final policy = CachePolicy(
        ownerId: 'owner',
        settings: Blobs(),
        availableSpace: () async => null,
      );
      final inner = Attachments(),
          store = BudgetedAttachmentStore(inner, policy);
      final file = ChatAttachment(
        name: 'fixture.bin',
        mimeType: 'application/octet-stream',
        bytes: Uint8List(20),
      );
      await store.put('owner', file);
      await store.put('owner', file);
      expect(policy.reservedBytes, 20);
      expect(inner.m.length, 1);
      await expectLater(
        store.put('other', file),
        throwsA(isA<CachePolicyException>()),
      );
      expect(inner.m.length, 1);
      policy.dispose();
    },
  );
  test('cache capacity failure does not poison text history', () async {
    final policy = CachePolicy(
      ownerId: 'owner',
      settings: Blobs(),
      availableSpace: () async => 0,
    );
    final inner = Attachments();
    final history = PeerHistory(
      store: Store(),
      attachments: BudgetedAttachmentStore(inner, policy),
    );
    await history.load('owner');
    await expectLater(
      history.addAttachment(
        'friend',
        PeerMessage(
          id: 'file',
          text: 'file',
          incoming: true,
          status: DeliveryStatus.delivered,
          attachment: ChatAttachment(
            name: 'fixture.bin',
            mimeType: 'application/octet-stream',
            bytes: Uint8List(20),
          ),
        ),
      ),
      throwsA(isA<CachePolicyException>()),
    );
    expect(inner.m, isEmpty);
    expect(history.error, isNull);
    history.add(
      'friend',
      PeerMessage(
        id: 'text',
        text: 'still chatting',
        incoming: true,
        status: DeliveryStatus.delivered,
      ),
    );
    await history.flush();
    expect(history.error, isNull);
    history.dispose();
    policy.dispose();
  });
}

class FailedLegacyBridge implements AttachmentBridge {
  @override
  Future<String?> loadPeerAttachment(String owner, String digest) async => null;
  @override
  Future<void> savePeerAttachment(
    String owner,
    String digest,
    String data,
  ) async {
    throw StateError('Synthetic write failure');
  }
}

class FailedGroupAttachments extends Attachments {
  FailedGroupAttachments(this.allowed);
  final int allowed;
  int count = 0;
  @override
  Future<AttachmentRef> put(String owner, ChatAttachment file) async {
    if (count++ >= allowed) throw StateError('Synthetic group import failure');
    return super.put(owner, file);
  }
}

class BrokenSource implements AttachmentSource {
  BrokenSource(this.partial);
  final bool partial;
  @override
  int get length => 2 * standardChunkedAttachmentChunkSize;
  @override
  String get key => 'broken-source';
  @override
  Stream<List<int>> openRead({int start = 0, int? end}) async* {
    if (partial) yield Uint8List(standardChunkedAttachmentChunkSize);
    throw StateError('Synthetic source disappeared');
  }
}

class StagingCache implements ChunkedAttachmentBridge {
  final ids = <String>{};
  @override
  Future<ChunkedAttachmentState> beginChunkedAttachment(
    String owner,
    String id,
    int size,
    int chunkSize, {
    String? digest,
  }) async {
    ids.add(id);
    return ChunkedAttachmentState(
      id: id,
      size: size,
      chunkSize: chunkSize,
      contiguousChunks: 0,
      completed: false,
      digest: digest,
    );
  }

  @override
  Future<void> writeChunkedAttachment(
    String owner,
    String id,
    int index,
    Uint8List bytes,
  ) async {}
  @override
  Future<void> deleteChunkedAttachment(String owner, String id) async {
    ids.remove(id);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
