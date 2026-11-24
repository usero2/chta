import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'attachment_ref.dart';
import 'attachment_store.dart';
import 'chat_attachment.dart';
import 'chunked_attachment_bridge.dart';
import 'cache_policy.dart';

class BudgetedAttachmentStore implements AttachmentStore {
  BudgetedAttachmentStore(this.inner, this.policy);
  final AttachmentStore inner;
  final CachePolicy policy;
  static final _reservationZone = Object();
  final _admitted = <String>{};
  Future<void> _legacyWrites = Future.value();
  Future<T> withReservation<T>(
    String key,
    int size,
    Future<T> Function() operation,
  ) async {
    await policy.reserve(
      key,
      size,
      recheckSpace: !_admitted.contains(key),
      expandRetained: true,
    );
    _admitted.add(key);
    return runZoned(operation, zoneValues: {_reservationZone: (this, key)});
  }

  void _owner(String owner) {
    if (owner != policy.ownerId) {
      throw const CachePolicyException('Identity changed');
    }
  }

  @override
  Future<AttachmentRef> put(String owner, ChatAttachment file) async {
    _owner(owner);
    final reserved = Zone.current[_reservationZone];
    if (file.isStreamed ||
        reserved is (BudgetedAttachmentStore, String) &&
            identical(reserved.$1, this)) {
      return inner.put(owner, file);
    }
    final key = 'blob_${sha256.convert(file.bytes)}';
    final result = _legacyWrites.then((_) async {
      await policy.reserve(key, file.size);
      try {
        final ref = await inner.put(owner, file);
        policy.noteWritten(key, file.size);
        await policy.complete(key);
        return ref;
      } catch (_) {
        // Only a definitive missing result permits rollback. An unreadable
        // or possibly committed blob keeps its conservative reservation.
        try {
          await inner.read(
            owner,
            AttachmentRef(
              name: file.name,
              mimeType: file.mimeType,
              size: file.size,
              digest: key.substring(5),
            ),
          );
        } on MissingAttachmentException {
          try {
            await policy.release(key);
          } catch (_) {}
        } catch (_) {}
        rethrow;
      }
    });
    _legacyWrites = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  @override
  Future<ChatAttachment> read(String owner, AttachmentRef ref) {
    _owner(owner);
    return inner.read(owner, ref);
  }
}

class BudgetedChunkCache implements ChunkedAttachmentBridge {
  BudgetedChunkCache(this.inner, this.policy);
  final ChunkedAttachmentBridge inner;
  final CachePolicy policy;
  final _sizes = <String, ({int size, int chunk})>{};
  void _owner(String owner) {
    if (owner != policy.ownerId) {
      throw const CachePolicyException('Identity changed');
    }
  }

  void _written(ChunkedAttachmentState state) {
    _sizes[state.id] = (size: state.size, chunk: state.chunkSize);
    policy.noteWritten(
      'chunk_${state.id}',
      (state.contiguousChunks * state.chunkSize).clamp(0, state.size),
    );
  }

  @override
  Future<ChunkedAttachmentState> beginChunkedAttachment(
    String owner,
    String id,
    int size,
    int chunkSize, {
    String? digest,
  }) async {
    _owner(owner);
    if (policy.entrySize('chunk_$id') > 0) {
      try {
        _written(await inner.chunkedAttachmentStatus(owner, id));
      } catch (_) {
        /* The core validates existence and metadata at begin. */
      }
    }
    await policy.reserve('chunk_$id', size);
    final state = await inner.beginChunkedAttachment(
      owner,
      id,
      size,
      chunkSize,
      digest: digest,
    );
    _written(state);
    if (state.completed) await policy.complete('chunk_$id');
    return state;
  }

  @override
  Future<ChunkedAttachmentState> chunkedAttachmentStatus(
    String owner,
    String id,
  ) async {
    _owner(owner);
    final state = await inner.chunkedAttachmentStatus(owner, id);
    _written(state);
    return state;
  }

  @override
  Future<void> writeChunkedAttachment(
    String owner,
    String id,
    int index,
    Uint8List bytes,
  ) async {
    _owner(owner);
    await inner.writeChunkedAttachment(owner, id, index, bytes);
    final state = _sizes[id];
    if (state != null) {
      policy.noteWritten(
        'chunk_$id',
        (index * state.chunk + bytes.length).clamp(0, state.size),
      );
    }
  }

  @override
  Future<Uint8List> readChunkedAttachment(String owner, String id, int index) {
    _owner(owner);
    return inner.readChunkedAttachment(owner, id, index);
  }

  @override
  Future<ChunkedAttachmentState> finishChunkedAttachment(
    String owner,
    String id, {
    String? expectedDigest,
  }) async {
    _owner(owner);
    final state = await inner.finishChunkedAttachment(
      owner,
      id,
      expectedDigest: expectedDigest,
    );
    _written(state);
    if (state.completed) await policy.complete('chunk_$id');
    return state;
  }

  @override
  Future<void> deleteChunkedAttachment(String owner, String id) async {
    _owner(owner);
    await inner.deleteChunkedAttachment(owner, id);
    await policy.release('chunk_$id');
    _sizes.remove(id);
  }
}

ChunkedAttachmentBridge? managedChunkCache(Object? bridge, CachePolicy policy) {
  final inner = createChunkedAttachmentBridge(bridge: bridge);
  return inner == null ? null : BudgetedChunkCache(inner, policy);
}
