import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'chat_attachment.dart';
import 'resumable_attachment_transfer.dart'
    show ResumableAttachmentTransfer, TransferInterrupted;

typedef PacketSender = Future<void> Function(
  String packetId,
  String text,
  int sentAt,
);
typedef AttachmentReceiver = FutureOr<void> Function(
  String transferId,
  ChatAttachment attachment,
  int sentAt,
  int receivedAt,
);
typedef TransferProgress = void Function(
  String transferId,
  double progress,
  bool incoming,
);
typedef TransferFailure = void Function(String transferId, Object error);

class AttachmentTransfer {
  static const String marker = '\u001eCHT_ATTACHMENT_V1:';
  static const String _idPrefix = 'chtatt1_';
  static const int chunkSize = 8 * 1024;
  static const int _windowSize = 8;
  static const int _maxCompleted = 512;
  static const int _maxBuffered = 100 * 1024 * 1024;
  static const Duration _ttl = Duration(minutes: 10);
  final PacketSender sendPacket;
  final AttachmentReceiver onReceived;
  final TransferProgress? onProgress;
  final TransferFailure? onFailure;
  final FutureOr<bool> Function(
    String id,
    String name,
    String mime,
    int size,
    String digest,
  )?
  mayReceive;
  final Duration ackTimeout;
  final int Function()? maxTransferBytes;
  final Map<String, Completer<int?>> _pending = {};
  final Map<String, _Incoming> _incoming = {};
  final Map<String, _Completed> _completed = {};
  bool _disposed = false;
  final _sending = <String, Object>{};
  bool canSendPacket(String id) {
    final end = id.lastIndexOf('_');
    return id.startsWith(_idPrefix) &&
        end > _idPrefix.length &&
        _sending.containsKey(id.substring(_idPrefix.length, end));
  }

  void interrupt(String transferId) {
    _sending.remove(transferId);
    for (final entry in _pending.entries.toList()) {
      if (entry.key.startsWith('$_idPrefix${transferId}_') &&
          !entry.value.isCompleted) {
        entry.value.completeError(const TransferInterrupted('Transfer paused'));
      }
    }
  }

  AttachmentTransfer({
    required this.sendPacket,
    required this.onReceived,
    this.onProgress,
    this.onFailure,
    this.mayReceive,
    this.maxTransferBytes,
    this.ackTimeout = const Duration(seconds: 45),
  });
  static bool isPacketId(String id) => id.startsWith(_idPrefix);

  static bool isBulkPacket(String id, String text) {
    if (isPacketId(id)) return true;
    if (!ResumableAttachmentTransfer.isPacketId(id)) return false;
    // Resumable control frames share the packet ID prefix with file chunks.
    try {
      final packet = jsonDecode(text);
      return packet is Map && packet['type'] == 'part';
    } on FormatException {
      return false;
    }
  }

  static bool _validId(String id) =>
      RegExp(r'^[A-Za-z0-9_-]{1,100}$').hasMatch(id);
  static String _packetId(String id, int index) => '$_idPrefix${id}_$index';

  static void validateOutgoing(String transferId, ChatAttachment attachment) {
    if (!_validId(transferId)) {
      throw const FormatException('Invalid transfer ID');
    }
    final total = ((attachment.bytes.length + chunkSize - 1) ~/ chunkSize)
        .clamp(1, ChatAttachment.maxBytes);
    // Validate the largest possible packet before sending any part of the file.
    final largest =
        marker +
        jsonEncode({
          'id': transferId,
          'i': total - 1,
          'n': total,
          'size': attachment.bytes.length,
          'name': attachment.name,
          'mime': attachment.mimeType,
          'sha256': 'a' * 64,
          ...attachment.presentationJson,
          'data':
              'A' *
              (((attachment.bytes.length.clamp(0, chunkSize) + 2) ~/ 3) * 4),
        });
    _validatePacketSize(largest);
  }

  Future<int?> send(
    String transferId,
    ChatAttachment attachment,
    int sentAt,
  ) async {
    if (_disposed) throw StateError('Transfer disposed');
    if (!_validId(transferId)) {
      throw const FormatException('Invalid transfer ID');
    }
    _validatePolicy(attachment.bytes.length);
    final hash = sha256.convert(attachment.bytes).toString();
    final count = (attachment.bytes.length + chunkSize - 1) ~/ chunkSize;
    final total = count == 0 ? 1 : count;
    validateOutgoing(transferId, attachment);
    if (_sending.containsKey(transferId)) {
      throw const TransferInterrupted('Transfer already running');
    }
    final token = Object();
    _sending[transferId] = token;
    void guard() {
      if (!identical(_sending[transferId], token)) {
        throw const TransferInterrupted('Transfer paused');
      }
    }

    int? receipt;
    var acknowledged = 0;
    try {
      for (var base = 0; base < total; base += _windowSize) {
        guard();
        _validatePolicy(attachment.bytes.length);
        final jobs = <Future<_AckResult>>[];
        final window = <String, Completer<int?>>{};
        final failure = Completer<_AckResult>();
        try {
          final limit = (base + _windowSize).clamp(0, total);
          for (var i = base; i < limit; i++) {
            guard();
            if (_disposed) throw StateError('Transfer disposed');
            final start = i * chunkSize;
            final end = (start + chunkSize).clamp(0, attachment.bytes.length);
            final id = _packetId(transferId, i);
            if (_pending.containsKey(id)) {
              throw StateError('Transfer already sending');
            }
            final pending = Completer<int?>();
            _pending[id] = pending;
            window[id] = pending;
            // Observe failures immediately even while the remaining packets are queued.
            jobs.add(
              pending.future
                  .timeout(ackTimeout)
                  .then(
                    (value) {
                      acknowledged++;
                      onProgress?.call(transferId, acknowledged / total, false);
                      return _AckResult(value, null, null);
                    },
                    onError: (Object error, StackTrace stack) {
                      final result = _AckResult(null, error, stack);
                      if (!failure.isCompleted) failure.complete(result);
                      return result;
                    },
                  ),
            );
            final text =
                marker +
                jsonEncode({
                  'id': transferId,
                  'i': i,
                  'n': total,
                  'size': attachment.bytes.length,
                  'name': attachment.name,
                  'mime': attachment.mimeType,
                  'sha256': hash,
                  ...attachment.presentationJson,
                  'data': base64Encode(attachment.bytes.sublist(start, end)),
                });
            await sendPacket(id, text, sentAt);
            guard();
            if (failure.isCompleted) {
              final result = await failure.future;
              Error.throwWithStackTrace(result.error!, result.stack!);
            }
          }
          final results = await Future.any<List<_AckResult>>([
            Future.wait(jobs),
            failure.future.then((result) => [result]),
          ]);
          for (final result in results) {
            if (result.error != null) {
              Error.throwWithStackTrace(result.error!, result.stack!);
            }
          }
          for (final result in results) {
            final timestamp = result.value;
            if (timestamp != null && (receipt == null || timestamp > receipt)) {
              receipt = timestamp;
            }
          }
        } catch (_) {
          for (final pending in window.values) {
            if (!pending.isCompleted) {
              pending.completeError(StateError('Transfer cancelled'));
            }
          }
          await Future.wait(jobs);
          rethrow;
        } finally {
          for (final entry in window.entries) {
            if (identical(_pending[entry.key], entry.value)) {
              _pending.remove(entry.key);
            }
          }
        }
      }
      guard();
      return receipt;
    } catch (error) {
      onFailure?.call(transferId, error);
      rethrow;
    } finally {
      if (identical(_sending[transferId], token)) _sending.remove(transferId);
    }
  }

  bool acknowledge(String packetId, {int? receivedAtMilliseconds}) {
    final pending = _pending[packetId];
    if (pending != null && !pending.isCompleted) {
      pending.complete(receivedAtMilliseconds);
    }
    return isPacketId(packetId);
  }

  static void _validatePacketSize(String text) {
    // Ciphertext/base64 plus envelope overhead remains below the relay frame cap.
    if (text.length > 12000 ||
        ((utf8.encode(text).length + 2) ~/ 3) * 4 + 1024 > 24000) {
      throw const FormatException('Attachment metadata is too long');
    }
  }

  bool fail(String packetId) {
    final pending = _pending[packetId];
    if (pending != null && !pending.isCompleted) {
      pending.completeError(StateError('Attachment packet failed'));
    }
    return isPacketId(packetId);
  }

  Future<bool> receive(
    String packetId,
    String text,
    int? sentAt,
    int receivedAt,
  ) async {
    if (!text.startsWith(marker)) return false;
    if (_disposed) throw StateError('Transfer disposed');
    _cleanup();
    _validatePacketSize(text);
    dynamic obj;
    try {
      obj = jsonDecode(text.substring(marker.length));
    } catch (_) {
      throw const FormatException('Invalid attachment packet');
    }
    if (obj is! Map<String, dynamic>) {
      throw const FormatException('Invalid attachment packet');
    }
    final id = obj['id'];
    final i = obj['i'];
    final n = obj['n'];
    final size = obj['size'];
    final name = obj['name'];
    final mime = obj['mime'];
    final hash = obj['sha256'];
    final data = obj['data'];
    ChatAttachment.validatePresentation(
      obj['caption'],
      obj['groupId'],
      obj['groupIndex'],
      obj['groupCount'],
    );
    final presentation = <String, Object?>{
      for (final key in ['caption', 'groupId', 'groupIndex', 'groupCount'])
        if (obj[key] != null) key: obj[key],
    };
    final presentationKey = jsonEncode(presentation);
    if (id is! String ||
        !_validId(id) ||
        i is! int ||
        n is! int ||
        size is! int ||
        name is! String ||
        mime is! String ||
        hash is! String ||
        data is! String) {
      throw const FormatException('Invalid attachment fields');
    }
    ChatAttachment.validateMetadata(name, mime, size);
    _validatePolicy(size);
    final expectedCount = size == 0 ? 1 : (size + chunkSize - 1) ~/ chunkSize;
    if (n != expectedCount ||
        i < 0 ||
        i >= n ||
        packetId != _packetId(id, i) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
      throw const FormatException('Invalid attachment bounds');
    }
    if (mayReceive != null && !await mayReceive!(id, name, mime, size, hash)) {
      return false;
    }
    if (_disposed) return false;
    final expectedLength = i == n - 1 ? size - i * chunkSize : chunkSize;
    if (data.length != ((expectedLength + 2) ~/ 3) * 4 ||
        !RegExp(r'^[A-Za-z0-9+/]*={0,2}$').hasMatch(data)) {
      throw const FormatException('Invalid attachment data');
    }
    Uint8List chunk;
    try {
      chunk = base64Decode(data);
    } catch (_) {
      throw const FormatException('Invalid attachment data');
    }
    if (chunk.length != expectedLength || base64Encode(chunk) != data) {
      throw const FormatException('Invalid attachment data');
    }
    final completed = _completed[id];
    if (completed != null) {
      if (completed.name != name ||
          completed.mime != mime ||
          completed.size != size ||
          completed.count != n ||
          completed.hash != hash ||
          completed.presentation != presentationKey) {
        throw const FormatException('Conflicting attachment metadata');
      }
      return true;
    }
    var state = _incoming[id];
    if (state == null) {
      if (_incoming.length >= 2 ||
          _incoming.values.fold<int>(0, (sum, s) => sum + s.size) + size >
              _maxBuffered) {
        throw const FormatException('Too many incoming attachments');
      }
      state = _Incoming(
        name,
        mime,
        size,
        n,
        hash,
        sentAt ?? receivedAt,
        presentationKey,
      );
      _incoming[id] = state;
    }
    if (state.name != name ||
        state.mime != mime ||
        state.size != size ||
        state.count != n ||
        state.hash != hash ||
        state.presentation != presentationKey) {
      throw const FormatException('Conflicting attachment metadata');
    }
    state.updated = DateTime.now();
    if (state.chunks.contains(i)) {
      final start = i * chunkSize;
      for (var j = 0; j < chunk.length; j++) {
        if (state.buffer[start + j] != chunk[j]) {
          throw const FormatException('Conflicting attachment chunk');
        }
      }
    } else {
      state.buffer.setRange(i * chunkSize, i * chunkSize + chunk.length, chunk);
      state.chunks.add(i);
      state.received++;
      onProgress?.call(id, state.received / n, true);
    }
    if (state.received == n) {
      // Concurrent final-chunk duplicates share the same durable write.
      await (state.saving ??= (() async {
        final output = state!.buffer;
        if (sha256.convert(output).toString() != hash) {
          _incoming.remove(id);
          throw const FormatException('Attachment checksum mismatch');
        }
        await onReceived(
          id,
          ChatAttachment.fromOwnedBytes(
            name: name,
            mimeType: mime,
            bytes: output,
            caption: presentation['caption'] as String?,
            groupId: presentation['groupId'] as String?,
            groupIndex: presentation['groupIndex'] as int?,
            groupCount: presentation['groupCount'] as int?,
          ),
          state.sentAt,
          receivedAt,
        );
        if (_disposed || !identical(_incoming[id], state)) {
          throw StateError('Transfer reset');
        }
        _incoming.remove(id);
        if (_completed.length >= _maxCompleted) {
          _completed.remove(_completed.keys.first);
        }
        _completed[id] = _Completed(name, mime, size, n, hash, presentationKey);
      })()).whenComplete(() => state!.saving = null);
    }
    return true;
  }

  void _validatePolicy(int size) {
    final limit = maxTransferBytes?.call() ?? ChatAttachment.relayMaxBytes;
    if (limit < 0 || limit > ChatAttachment.maxBytes || size > limit) {
      throw const FormatException('Attachment exceeds transfer limit');
    }
  }

  void _cleanup() {
    final cutoff = DateTime.now().subtract(_ttl);
    _incoming.removeWhere((_, state) => state.updated.isBefore(cutoff));
    _completed.removeWhere((_, state) => state.updated.isBefore(cutoff));
  }

  void reset() {
    for (final pending in _pending.values) {
      if (!pending.isCompleted) {
        pending.completeError(StateError('Transfer reset'));
      }
    }
    _pending.clear();
    _incoming.clear();
    _completed.clear();
  }

  void dispose() {
    reset();
    _disposed = true;
  }
}

class _Incoming {
  final String name, mime, hash, presentation;
  final int size, count, sentAt;
  final Set<int> chunks = {};
  late final Uint8List buffer = Uint8List(size);
  int received = 0;
  DateTime updated = DateTime.now();
  Future<void>? saving;
  _Incoming(
    this.name,
    this.mime,
    this.size,
    this.count,
    this.hash,
    this.sentAt,
    this.presentation,
  );
}

class _Completed {
  final String name, mime, hash, presentation;
  final int size, count;
  final DateTime updated = DateTime.now();
  _Completed(
    this.name,
    this.mime,
    this.size,
    this.count,
    this.hash,
    this.presentation,
  );
}

class _AckResult {
  final int? value;
  final Object? error;
  final StackTrace? stack;
  _AckResult(this.value, this.error, this.stack);
}
