import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'chunked_attachment_bridge.dart';

@JS('chtCore.beginChunkedAttachment')
external JSPromise<JSString> _begin(
  JSString ownerId, JSString id, JSNumber size, JSNumber chunkSize,
  JSString? digest,
);
@JS('chtCore.chunkedAttachmentStatus')
external JSPromise<JSString> _status(JSString ownerId, JSString id);
@JS('chtCore.writeChunkedAttachment')
external JSPromise<JSAny?> _write(
  JSString ownerId, JSString id, JSNumber index, JSUint8Array bytes,
);
@JS('chtCore.readChunkedAttachment')
external JSPromise<JSUint8Array> _read(
  JSString ownerId, JSString id, JSNumber index,
);
@JS('chtCore.finishChunkedAttachment')
external JSPromise<JSString> _finish(
  JSString ownerId, JSString id, JSString digest,
);
@JS('chtCore.deleteChunkedAttachment')
external JSPromise<JSAny?> _delete(JSString ownerId, JSString id);

ChunkedAttachmentBridge? createPlatformChunkedAttachmentBridge(Object? bridge) =>
    bridge is BrowserChunkedStorageHost ? const _WebChunkedAttachmentBridge() : null;

class _WebChunkedAttachmentBridge implements ChunkedAttachmentBridge {
  const _WebChunkedAttachmentBridge();

  ChunkedAttachmentState _decode(String source) =>
      ChunkedAttachmentState.fromJson(jsonDecode(source));

  @override
  Future<ChunkedAttachmentState> beginChunkedAttachment(
    String ownerId,
    String id,
    int size,
    int chunkSize, {
    String? digest,
  }) async => _decode((await _begin(
    ownerId.toJS, id.toJS, size.toJS, chunkSize.toJS, digest?.toJS,
  ).toDart).toDart);

  @override
  Future<ChunkedAttachmentState> chunkedAttachmentStatus(
    String ownerId,
    String id,
  ) async => _decode((await _status(ownerId.toJS, id.toJS).toDart).toDart);

  @override
  Future<void> writeChunkedAttachment(
    String ownerId,
    String id,
    int index,
    Uint8List bytes,
  ) async {
    if (bytes.length > maxChunkedAttachmentChunkSize) {
      throw const FormatException('Attachment chunk is too large');
    }
    await _write(ownerId.toJS, id.toJS, index.toJS, bytes.toJS).toDart;
  }

  @override
  Future<Uint8List> readChunkedAttachment(
    String ownerId,
    String id,
    int index,
  ) async {
    final bytes = (await _read(ownerId.toJS, id.toJS, index.toJS).toDart).toDart;
    if (bytes.length > maxChunkedAttachmentChunkSize) {
      throw const FormatException('Attachment chunk is too large');
    }
    return bytes;
  }

  @override
  Future<ChunkedAttachmentState> finishChunkedAttachment(
    String ownerId,
    String id, {
    String? expectedDigest,
  }) async {
    final state = await chunkedAttachmentStatus(ownerId, id);
    final count = chunkCount(state.size, state.chunkSize);
    if (state.contiguousChunks != count) {
      throw StateError('Attachment is missing chunks');
    }
    final collector = _DigestCollector();
    final input = sha256.startChunkedConversion(collector);
    for (var index = 0; index < count; index++) {
      final bytes = await readChunkedAttachment(ownerId, id, index);
      final expectedLength = (state.size - index * state.chunkSize) < state.chunkSize
          ? state.size - index * state.chunkSize
          : state.chunkSize;
      if (bytes.length != expectedLength) {
        throw StateError('Attachment cache contains a malformed chunk');
      }
      input.add(bytes);
    }
    input.close();
    final actualDigest = collector.digest.toString();
    if (expectedDigest != null && expectedDigest != actualDigest) {
      throw StateError('Attachment digest does not match stored bytes');
    }
    if (state.completed && state.digest != actualDigest) {
      throw StateError('Completed attachment digest does not match stored bytes');
    }
    return _decode((await _finish(
      ownerId.toJS, id.toJS, actualDigest.toJS,
    ).toDart).toDart);
  }

  @override
  Future<void> deleteChunkedAttachment(String ownerId, String id) async {
    await _delete(ownerId.toJS, id.toJS).toDart;
  }
}

class _DigestCollector implements Sink<Digest> {
  Digest? _digest;
  Digest get digest => _digest ?? (throw StateError('SHA-256 not finalized'));
  @override
  void add(Digest data) => _digest = data;
  @override
  void close() {}
}
