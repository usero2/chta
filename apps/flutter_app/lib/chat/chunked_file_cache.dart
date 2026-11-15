import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'chunked_attachment_bridge.dart';

/// Bounded streaming operations over durable encrypted chunk storage.
class ChunkedFileCache {
  ChunkedFileCache(this.bridge);

  final ChunkedAttachmentBridge bridge;

  /// Stores [source] sequentially and returns the completed state with SHA-256.
  /// At most one cache chunk is staged in memory by this helper.
  Future<ChunkedAttachmentState> importStream(
    String ownerId,
    String id,
    int size,
    Stream<List<int>> source, {
    int chunkSize = standardChunkedAttachmentChunkSize,
  }) async {
    validateChunkedAttachmentId(id);
    if (ownerId.isEmpty) throw ArgumentError.value(ownerId, 'ownerId');
    if (size < 0 || size > maxChunkedAttachmentSize) {
      throw ArgumentError.value(size, 'size', 'must be between 0 and 10 GiB');
    }
    if (chunkSize <= 0 || chunkSize > maxChunkedAttachmentChunkSize) {
      throw ArgumentError.value(
        chunkSize,
        'chunkSize',
        'must be between 1 byte and 1 MiB',
      );
    }

    await bridge.beginChunkedAttachment(ownerId, id, size, chunkSize);
    final digestSink = _DigestCollector();
    final hashInput = sha256.startChunkedConversion(digestSink);
    final staging = Uint8List(chunkSize);
    var used = 0;
    var consumed = 0;
    var index = 0;

    Future<void> flush() async {
      if (used == 0) return;
      final chunk = Uint8List.fromList(staging.sublist(0, used));
      await bridge.writeChunkedAttachment(ownerId, id, index++, chunk);
      used = 0;
    }

    await for (final part in source) {
      if (part.length > size - consumed) {
        hashInput.close();
        throw const FormatException(
          'Attachment stream is longer than its declared size',
        );
      }
      consumed += part.length;
      var offset = 0;
      while (offset < part.length) {
        final remaining = part.length - offset;
        final capacity = chunkSize - used;
        final count = capacity < remaining ? capacity : remaining;
        final segment = part.sublist(offset, offset + count);
        hashInput.add(segment);
        staging.setRange(used, used + count, segment);
        used += count;
        offset += count;
        if (used == chunkSize) await flush();
      }
    }
    if (consumed != size) {
      hashInput.close();
      throw const FormatException(
        'Attachment stream is shorter than its declared size',
      );
    }
    await flush();
    hashInput.close();
    final digest = digestSink.value.toString();
    final completed = await bridge.finishChunkedAttachment(
      ownerId,
      id,
      expectedDigest: digest,
    );
    if (!completed.completed ||
        completed.id != id ||
        completed.size != size ||
        completed.chunkSize != chunkSize ||
        completed.digest != digest ||
        completed.contiguousChunks != chunkCount(size, chunkSize)) {
      throw StateError(
        'Chunked attachment bridge returned an invalid completed state',
      );
    }
    return completed;
  }

  /// Reads the half-open byte range [start, end) from a completed attachment.
  /// Each bridge read is one stored chunk; the full file is never assembled.
  Stream<List<int>> openRead(
    String ownerId,
    String id, {
    int start = 0,
    int? end,
  }) async* {
    validateChunkedAttachmentId(id);
    if (ownerId.isEmpty) throw ArgumentError.value(ownerId, 'ownerId');
    final state = await bridge.chunkedAttachmentStatus(ownerId, id);
    if (state.id != id ||
        state.size < 0 ||
        state.size > maxChunkedAttachmentSize ||
        state.chunkSize <= 0 ||
        state.chunkSize > maxChunkedAttachmentChunkSize) {
      throw StateError('Chunked attachment bridge returned invalid metadata');
    }
    final rangeEnd = end ?? state.size;
    if (start < 0 || rangeEnd < start || rangeEnd > state.size) {
      throw RangeError(
        'Requested range [$start, $rangeEnd) is outside 0..${state.size}',
      );
    }
    if (!state.completed) {
      throw StateError('Only completed attachments can be read');
    }
    if (state.contiguousChunks != chunkCount(state.size, state.chunkSize) ||
        state.digest == null) {
      throw StateError('Completed attachment is missing chunks or digest');
    }
    if (start == rangeEnd) return;

    final first = start ~/ state.chunkSize;
    final lastExclusive = (rangeEnd + state.chunkSize - 1) ~/ state.chunkSize;
    for (var index = first; index < lastExclusive; index++) {
      final chunk = await bridge.readChunkedAttachment(ownerId, id, index);
      final chunkStart = index * state.chunkSize;
      final remaining = state.size - chunkStart;
      final expectedLength = remaining < state.chunkSize
          ? remaining
          : state.chunkSize;
      if (chunk.length != expectedLength) {
        throw StateError(
          'Chunked attachment bridge returned a malformed chunk',
        );
      }
      final relativeStart = start - chunkStart;
      final relativeEnd = rangeEnd - chunkStart;
      final from = relativeStart < 0
          ? 0
          : (relativeStart > chunk.length ? chunk.length : relativeStart);
      final to = relativeEnd < 0
          ? 0
          : (relativeEnd > chunk.length ? chunk.length : relativeEnd);
      if (to > from) yield Uint8List.sublistView(chunk, from, to);
    }
  }
}

class _DigestCollector implements Sink<Digest> {
  Digest? _value;

  Digest get value => _value ?? (throw StateError('SHA-256 was not finalized'));

  @override
  void add(Digest data) => _value = data;

  @override
  void close() {}
}
