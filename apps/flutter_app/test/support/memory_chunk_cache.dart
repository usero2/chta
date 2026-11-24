import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cht/chat/chunked_attachment_bridge.dart';

class MemoryChunkCache implements ChunkedAttachmentBridge {
  bool failDelete = false;
  final entries =
      <
        String,
        ({
          int size,
          int chunk,
          Map<int, Uint8List> parts,
          bool done,
          String? digest,
        })
      >{};
  int writes = 0;
  @override
  Future<ChunkedAttachmentState> beginChunkedAttachment(
    String owner,
    String id,
    int size,
    int chunkSize, {
    String? digest,
  }) async {
    final old = entries[id];
    if (old != null &&
        (old.size != size || old.chunk != chunkSize || old.digest != digest)) {
      throw StateError('Cache conflict');
    }
    entries.putIfAbsent(
      id,
      () => (
        size: size,
        chunk: chunkSize,
        parts: {},
        done: false,
        digest: digest,
      ),
    );
    return chunkedAttachmentStatus(owner, id);
  }

  @override
  Future<ChunkedAttachmentState> chunkedAttachmentStatus(
    String owner,
    String id,
  ) async {
    final e = entries[id];
    if (e == null) throw StateError('Missing cache');
    return ChunkedAttachmentState(
      id: id,
      size: e.size,
      chunkSize: e.chunk,
      contiguousChunks: e.parts.length,
      completed: e.done,
      digest: e.digest,
    );
  }

  @override
  Future<void> writeChunkedAttachment(
    String owner,
    String id,
    int index,
    Uint8List bytes,
  ) async {
    final e = entries[id]!;
    if (index != e.parts.length ||
        bytes.length !=
            (index == chunkCount(e.size, e.chunk) - 1
                ? e.size - index * e.chunk
                : e.chunk)) {
      throw StateError('Invalid chunk');
    }
    e.parts[index] = Uint8List.fromList(bytes);
    writes++;
  }

  @override
  Future<Uint8List> readChunkedAttachment(
    String owner,
    String id,
    int index,
  ) async => Uint8List.fromList(entries[id]!.parts[index]!);
  @override
  Future<ChunkedAttachmentState> finishChunkedAttachment(
    String owner,
    String id, {
    String? expectedDigest,
  }) async {
    final e = entries[id]!, builder = BytesBuilder(copy: false);
    for (var i = 0; i < chunkCount(e.size, e.chunk); i++) {
      builder.add(e.parts[i]!);
    }
    final bytes = builder.takeBytes(),
        digest = sha256.convert(bytes).toString();
    if (bytes.length != e.size ||
        expectedDigest != null && digest != expectedDigest) {
      throw const FormatException('Digest mismatch');
    }
    entries[id] = (
      size: e.size,
      chunk: e.chunk,
      parts: e.parts,
      done: true,
      digest: digest,
    );
    return chunkedAttachmentStatus(owner, id);
  }

  @override
  Future<void> deleteChunkedAttachment(String owner, String id) async {
    if (failDelete) throw StateError('Disk busy');
    entries.remove(id);
  }
}
