import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'attachment_ref.dart';
import 'attachment_source.dart';
import 'chat_attachment.dart';
import 'chunked_attachment_bridge.dart';
import 'chunked_file_cache.dart';
import 'cache_policy.dart';
import 'managed_attachment_cache.dart';
import 'attachment_store_stub.dart'
    if (dart.library.io) 'attachment_store_native.dart'
    if (dart.library.js_interop) 'attachment_store_web.dart';

abstract interface class AttachmentBridge {
  Future<void> savePeerAttachment(String ownerId, String digest, String data);
  Future<String?> loadPeerAttachment(String ownerId, String digest);
}

abstract interface class AttachmentStore {
  Future<AttachmentRef> put(String ownerId, ChatAttachment file);
  Future<ChatAttachment> read(String ownerId, AttachmentRef ref);
}

class MissingAttachmentException extends StateError {
  MissingAttachmentException() : super('Attachment is missing from cache');
}

AttachmentStore createAttachmentStore({
  Object? bridge,
  CachePolicy? cachePolicy,
}) {
  final legacy = bridge is AttachmentBridge
      ? BridgeAttachmentStore(bridge)
      : createPlatformAttachmentStore();
  final chunks = cachePolicy == null
      ? createChunkedAttachmentBridge(bridge: bridge)
      : managedChunkCache(bridge, cachePolicy);
  final store = chunks == null
      ? legacy
      : HybridAttachmentStore(legacy, ChunkedFileCache(chunks));
  return cachePolicy == null
      ? store
      : BudgetedAttachmentStore(store, cachePolicy);
}

/// Routes legacy byte attachments through their original cache and durable
/// source attachments through the encrypted chunk cache.
class HybridAttachmentStore implements AttachmentStore {
  HybridAttachmentStore(this.legacy, this.cache);
  final AttachmentStore legacy;
  final ChunkedFileCache cache;

  @override
  Future<AttachmentRef> put(String ownerId, ChatAttachment file) async {
    if (!file.isStreamed) return legacy.put(ownerId, file);
    final id = _newChunkedId();
    final ChunkedAttachmentState state;
    try {
      state = await cache.importStream(ownerId, id, file.size, file.openRead());
    } catch (_) {
      // This ID was created only for this unpublished local import, never for
      // a received/paused job. Release its reservation only after deletion.
      try {
        await cache.bridge.deleteChunkedAttachment(ownerId, id);
      } catch (_) {}
      rethrow;
    }
    return AttachmentRef(
      name: file.name,
      mimeType: file.mimeType,
      size: file.size,
      digest: state.digest!,
      chunkedId: id,
      chunkSize: state.chunkSize,
      caption: file.caption,
      groupId: file.groupId,
      groupIndex: file.groupIndex,
      groupCount: file.groupCount,
    );
  }

  @override
  Future<ChatAttachment> read(String ownerId, AttachmentRef ref) async {
    if (!ref.isChunked) return legacy.read(ownerId, ref);
    final state = await cache.bridge.chunkedAttachmentStatus(
      ownerId,
      ref.chunkedId!,
    );
    if (!state.completed ||
        state.size != ref.size ||
        state.chunkSize != ref.chunkSize ||
        state.digest != ref.digest) {
      throw const FormatException(
        'Cached attachment metadata does not match reference',
      );
    }
    return ChatAttachment.fromSource(
      name: ref.name,
      mimeType: ref.mimeType,
      source: ChunkedAttachmentSource(cache, ownerId, ref.chunkedId!, ref.size),
      caption: ref.caption,
      groupId: ref.groupId,
      groupIndex: ref.groupIndex,
      groupCount: ref.groupCount,
    );
  }
}

class ChunkedAttachmentSource implements AttachmentSource {
  ChunkedAttachmentSource(this.cache, this.ownerId, this.id, this.length);
  final ChunkedFileCache cache;
  final String ownerId, id;
  @override
  final int length;
  @override
  String get key => '$ownerId:$id';
  @override
  Stream<List<int>> openRead({int start = 0, int? end}) =>
      cache.openRead(ownerId, id, start: start, end: end);
}

String _newChunkedId() {
  final random = Random.secure();
  final bytes = Uint8List.fromList(
    List.generate(24, (_) => random.nextInt(256)),
  );
  return base64UrlEncode(bytes).replaceAll('=', '');
}

class BridgeAttachmentStore implements AttachmentStore {
  BridgeAttachmentStore(this.bridge);
  final AttachmentBridge bridge;
  @override
  Future<AttachmentRef> put(String ownerId, ChatAttachment file) async {
    if (file.isStreamed) {
      throw UnsupportedError('Encrypted chunk cache is unavailable');
    }
    final digest = sha256.convert(file.bytes).toString();
    await bridge.savePeerAttachment(ownerId, digest, base64Encode(file.bytes));
    return AttachmentRef(
      name: file.name,
      mimeType: file.mimeType,
      size: file.bytes.length,
      digest: digest,
      caption: file.caption,
      groupId: file.groupId,
      groupIndex: file.groupIndex,
      groupCount: file.groupCount,
    );
  }

  @override
  Future<ChatAttachment> read(String ownerId, AttachmentRef ref) async {
    final data = await bridge.loadPeerAttachment(ownerId, ref.digest);
    if (data == null) throw MissingAttachmentException();
    if (data.length > ((ChatAttachment.maxBytes + 2) ~/ 3) * 4) {
      throw const FormatException('Invalid cached attachment');
    }
    final bytes = base64Decode(data);
    if (bytes.length != ref.size ||
        sha256.convert(bytes).toString() != ref.digest) {
      throw const FormatException('Cached attachment is damaged');
    }
    return ChatAttachment.fromOwnedBytes(
      name: ref.name,
      mimeType: ref.mimeType,
      bytes: bytes,
      caption: ref.caption,
      groupId: ref.groupId,
      groupIndex: ref.groupIndex,
      groupCount: ref.groupCount,
    );
  }
}
