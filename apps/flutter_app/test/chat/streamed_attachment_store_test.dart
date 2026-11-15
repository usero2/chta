import 'dart:typed_data';

import 'package:cht/chat/attachment_source.dart';
import 'package:cht/chat/attachment_store.dart';
import 'package:cht/chat/chat_attachment.dart';
import 'package:cht/chat/chunked_attachment_bridge.dart';
import 'package:cht/chat/chunked_file_cache.dart';
import 'package:cht/chat/peer_history.dart';
import 'package:cht/chat/peer_history_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'history durably imports source and reopens a lazy owner-bound attachment',
    () async {
      final bridge = _Chunks();
      final cache = HybridAttachmentStore(
        BridgeAttachmentStore(_Legacy()),
        ChunkedFileCache(bridge),
      );
      final historyStore = _History();
      final history = PeerHistory(store: historyStore, attachments: cache);
      await history.load('alice');
      final source = _Source();
      final message = PeerMessage(
        id: 'one',
        text: '[file] sample.bin',
        incoming: false,
        status: DeliveryStatus.pending,
        attachment: ChatAttachment.fromSource(
          name: 'sample.bin',
          mimeType: 'application/octet-stream',
          source: source,
        ),
      );
      await history.addAttachment('peer', message);
      expect(source.reads, 1);
      expect(message.attachment, isNull);
      expect(message.attachmentRef!.isChunked, isTrue);
      expect(historyStore.data['alice'], isNot(contains('"bytes"')));
      final reopened = PeerHistory(store: historyStore, attachments: cache);
      await reopened.load('alice');
      final restored = reopened.messagesFor('peer').single;
      expect(restored.status, DeliveryStatus.pending);
      final file = await reopened.resolveAttachment(restored);
      expect(file.isStreamed, isTrue);
      expect(await file.openRead(start: 2, end: 5).expand((v) => v).toList(), [
        2,
        3,
        4,
      ]);
      expect(source.reads, 1);
      await reopened.load('bob');
      await expectLater(file.openRead().toList(), throwsStateError);
      await expectLater(reopened.resolveAttachment(restored), throwsStateError);
    },
  );
}

class _Source implements AttachmentSource {
  @override
  int get length => 6;
  @override
  String get key => 'test-source';
  int reads = 0;
  @override
  Stream<List<int>> openRead({int start = 0, int? end}) {
    reads++;
    return Stream.value([0, 1, 2, 3, 4, 5].sublist(start, end));
  }
}

class _Legacy implements AttachmentBridge {
  @override
  Future<String?> loadPeerAttachment(String ownerId, String digest) async =>
      null;
  @override
  Future<void> savePeerAttachment(
    String ownerId,
    String digest,
    String data,
  ) async {}
}

class _History implements PeerHistoryStore {
  final data = <String, String>{};
  @override
  Future<String?> load(String ownerId) async => data[ownerId];
  @override
  Future<void> save(String ownerId, String source) async =>
      data[ownerId] = source;
}

class _Chunks implements ChunkedAttachmentBridge {
  String? owner, id;
  int? size, chunkSize;
  String? digest;
  final chunks = <int, Uint8List>{};
  ChunkedAttachmentState get state => ChunkedAttachmentState(
    id: id!,
    size: size!,
    chunkSize: chunkSize!,
    contiguousChunks: chunks.length,
    completed: digest != null,
    digest: digest,
  );
  void check(String o, String i) {
    if (o != owner || i != id) throw StateError('wrong owner');
  }

  @override
  Future<ChunkedAttachmentState> beginChunkedAttachment(
    String ownerId,
    String id,
    int size,
    int chunkSize, {
    String? digest,
  }) async {
    owner = ownerId;
    this.id = id;
    this.size = size;
    this.chunkSize = chunkSize;
    return state;
  }

  @override
  Future<ChunkedAttachmentState> chunkedAttachmentStatus(
    String ownerId,
    String id,
  ) async {
    check(ownerId, id);
    return state;
  }

  @override
  Future<void> writeChunkedAttachment(
    String ownerId,
    String id,
    int index,
    Uint8List bytes,
  ) async {
    check(ownerId, id);
    chunks[index] = bytes;
  }

  @override
  Future<Uint8List> readChunkedAttachment(
    String ownerId,
    String id,
    int index,
  ) async {
    check(ownerId, id);
    return chunks[index]!;
  }

  @override
  Future<ChunkedAttachmentState> finishChunkedAttachment(
    String ownerId,
    String id, {
    String? expectedDigest,
  }) async {
    check(ownerId, id);
    digest = expectedDigest;
    return state;
  }

  @override
  Future<void> deleteChunkedAttachment(String ownerId, String id) async {
    check(ownerId, id);
    chunks.clear();
  }
}
