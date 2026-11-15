import 'dart:typed_data';

import 'chunked_attachment_bridge_stub.dart'
    if (dart.library.js_interop) 'chunked_attachment_bridge_web.dart'
    as platform;

const int maxChunkedAttachmentSize = 10 * 1024 * 1024 * 1024;
const int maxChunkedAttachmentChunkSize = 1024 * 1024;
const int standardChunkedAttachmentChunkSize = 256 * 1024;

final RegExp _safeChunkedAttachmentId = RegExp(r'^[A-Za-z0-9_-]{16,96}$');
final RegExp _sha256Hex = RegExp(r'^[0-9a-f]{64}$');

/// Capability for encrypted, owner-scoped chunk storage.
///
/// Implementations must make each write durable before reporting progress and
/// must not expose storage paths through this API.
abstract interface class ChunkedAttachmentBridge {
  Future<ChunkedAttachmentState> beginChunkedAttachment(
    String ownerId,
    String id,
    int size,
    int chunkSize, {
    String? digest,
  });

  Future<ChunkedAttachmentState> chunkedAttachmentStatus(
    String ownerId,
    String id,
  );

  Future<void> writeChunkedAttachment(
    String ownerId,
    String id,
    int index,
    Uint8List bytes,
  );

  Future<Uint8List> readChunkedAttachment(String ownerId, String id, int index);

  Future<ChunkedAttachmentState> finishChunkedAttachment(
    String ownerId,
    String id, {
    String? expectedDigest,
  });

  Future<void> deleteChunkedAttachment(String ownerId, String id);
}

/// Marker implemented only by the browser core that owns the IndexedDB cache.
abstract interface class BrowserChunkedStorageHost {}

/// Validated progress metadata returned by a [ChunkedAttachmentBridge].
class ChunkedAttachmentState {
  ChunkedAttachmentState({
    required this.id,
    required this.size,
    required this.chunkSize,
    required this.contiguousChunks,
    required this.completed,
    required this.digest,
  }) {
    validateChunkedAttachmentId(id);
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
    final count = chunkCount(size, chunkSize);
    if (contiguousChunks < 0 || contiguousChunks > count) {
      throw ArgumentError.value(
        contiguousChunks,
        'contiguousChunks',
        'outside attachment bounds',
      );
    }
    if (digest != null && !_sha256Hex.hasMatch(digest!)) {
      throw ArgumentError.value(
        digest,
        'digest',
        'must be a lowercase SHA-256 hex digest',
      );
    }
    if (completed && (contiguousChunks != count || digest == null)) {
      throw ArgumentError(
        'completed state must contain every chunk and a digest',
      );
    }
  }

  final String id;
  final int size;
  final int chunkSize;
  final int contiguousChunks;
  final bool completed;
  final String? digest;

  Map<String, Object?> toJson() => {
    'id': id,
    'size': size,
    'chunkSize': chunkSize,
    'contiguousChunks': contiguousChunks,
    'completed': completed,
    'digest': digest,
  };

  factory ChunkedAttachmentState.fromJson(Object? value) {
    if (value is! Map<String, Object?>) {
      throw const FormatException('Chunked attachment state must be an object');
    }
    const fields = {
      'id',
      'size',
      'chunkSize',
      'contiguousChunks',
      'completed',
      'digest',
    };
    final keys = value.keys.toSet();
    final hasVersion = keys.contains('version');
    if (!keys.containsAll(fields) ||
        keys.any((key) => !fields.contains(key) && key != 'version') ||
        (!hasVersion && value.length != fields.length) ||
        (hasVersion &&
            (value.length != fields.length + 1 || value['version'] != 2))) {
      throw const FormatException(
        'Chunked attachment state has missing or unknown fields',
      );
    }
    final id = value['id'];
    final size = value['size'];
    final chunkSize = value['chunkSize'];
    final contiguousChunks = value['contiguousChunks'];
    final completed = value['completed'];
    final digest = value['digest'];
    if (id is! String ||
        size is! int ||
        chunkSize is! int ||
        contiguousChunks is! int ||
        completed is! bool ||
        (digest != null && digest is! String)) {
      throw const FormatException(
        'Chunked attachment state contains invalid field types',
      );
    }
    try {
      return ChunkedAttachmentState(
        id: id,
        size: size,
        chunkSize: chunkSize,
        contiguousChunks: contiguousChunks,
        completed: completed,
        digest: digest as String?,
      );
    } on ArgumentError catch (error) {
      throw FormatException('Invalid chunked attachment state: $error');
    }
  }
}

/// Returns only an explicitly supplied supported implementation. Platform
/// adapters can be added by conditional imports without exposing unsupported
/// platforms as if they had storage capability.
ChunkedAttachmentBridge? createChunkedAttachmentBridge({Object? bridge}) =>
    bridge is ChunkedAttachmentBridge
        ? bridge
        : platform.createPlatformChunkedAttachmentBridge(bridge);

void validateChunkedAttachmentId(String id) {
  if (!_safeChunkedAttachmentId.hasMatch(id)) {
    throw ArgumentError.value(
      id,
      'id',
      'must be 16–96 ASCII letters, digits, _ or -',
    );
  }
}

int chunkCount(int size, int chunkSize) =>
    size == 0 ? 0 : (size + chunkSize - 1) ~/ chunkSize;
