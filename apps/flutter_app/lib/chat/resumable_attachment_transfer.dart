import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'attachment_ref.dart';
import 'chat_attachment.dart';
import 'chunked_attachment_bridge.dart';
import 'file_transfer_progress.dart';

class TransferInterrupted implements Exception {
  const TransferInterrupted([this.message = 'Waiting for connection']);
  final String message;
  @override
  String toString() => message;
}

class TransferRejected implements Exception {
  const TransferRejected(this.message);
  final String message;
  @override
  String toString() => message;
}

typedef ResumablePacketSender = Future<void> Function(String id, String text);
typedef IncomingFileOffer = Future<void> Function(
  String id,
  AttachmentRef ref,
  int? sentAt,
);
typedef IncomingFileComplete = Future<int> Function(
  String id,
  AttachmentRef ref,
);

/// Durable V2 transfers. Only one cache block per active file is held in memory.
/// Transport authentication/peer binding belongs to the owning connection.
class ResumableAttachmentTransfer {
  ResumableAttachmentTransfer({
    required this.ownerId,
    required this.peerId,
    required this.bridge,
    required this.sendPacket,
    required this.isDirect,
    required this.onOffer,
    required this.onCompleted,
    this.onProgress,
    this.checkIncoming,
    this.onReceipt,
    this.ackTimeout = const Duration(seconds: 45),
  });
  final String ownerId, peerId;
  final ChunkedAttachmentBridge bridge;
  final ResumablePacketSender sendPacket;
  final bool Function() isDirect;
  final IncomingFileOffer onOffer;
  final IncomingFileComplete onCompleted;
  final void Function(String id, TransferProgressSnapshot value, bool incoming)?
  onProgress;
  final Duration ackTimeout;
  final void Function(String id)? checkIncoming;
  final void Function(String id, int receivedAt)? onReceipt;
  static const prefix = 'chtfile2_';
  static const pieceSize = 8 * 1024;
  static bool isPacketId(String? id) => id?.startsWith(prefix) == true;
  final _outgoing = <String, _Outgoing>{};
  final _incoming = <String, _Incoming>{};
  Future<void> _receiving = Future.value();
  bool _closed = false;
  int _generation = 0, _sequence = 0;
  bool get active => _outgoing.isNotEmpty || _incoming.isNotEmpty;
  void _guard(int generation) {
    if (_closed || generation != _generation) throw const TransferInterrupted();
  }

  void _guardSend(int generation, _Outgoing job) {
    _guard(generation);
    if (job.interruption case final error?) throw error;
  }

  void _guardIncoming(String id, _Incoming job, int generation) {
    _guard(generation);
    checkIncoming?.call(id);
    if (!identical(_incoming[id], job)) throw const TransferInterrupted();
  }

  void interrupt(String id) {
    _outgoing[id]?.interrupt(const TransferInterrupted('Transfer paused'));
    _incoming.remove(id);
  }

  Future<void> _packet(Map<String, Object?> body) async {
    if (_closed) throw const TransferInterrupted();
    final encoded = jsonEncode({'v': 2, ...body});
    if (utf8.encode(encoded).length > 14000) {
      throw const TransferRejected('File packet is too large');
    }
    await sendPacket('$prefix${body['id']}_${_sequence++}', encoded);
  }

  void _progress(
    String id,
    int done,
    int total,
    FileTransferPhase phase,
    bool incoming, {
    double rate = 0,
  }) {
    if (!_closed) {
      onProgress?.call(
        id,
        TransferProgressSnapshot(
          confirmedBytes: done,
          totalBytes: total,
          bytesPerSecond: rate,
          transport: isDirect() ? 'Direct' : 'Relay',
          phase: phase,
        ),
        incoming,
      );
    }
  }

  Future<int> send(
    String id,
    AttachmentRef ref, {
    int? sentAtMilliseconds,
  }) async {
    validateChunkedAttachmentId(id);
    if (!ref.isChunked || ref.chunkSize == null || ref.chunkedId == null) {
      throw const TransferRejected('File is not cached for streaming');
    }
    if (_outgoing.containsKey(id)) {
      throw const TransferInterrupted('Transfer is already running');
    }
    if (_outgoing.length >= 5) {
      throw const TransferInterrupted('Too many active transfers');
    }
    if (ref.size > ChatAttachment.relayMaxBytes && !isDirect()) {
      throw const TransferInterrupted('Waiting for a direct connection');
    }
    final generation = _generation;
    final job = _Outgoing(ref);
    // Reserve synchronously: status can involve slow disk or IndexedDB reads.
    _outgoing[id] = job;
    final clock = Stopwatch()..start();
    var baseline = 0;
    try {
      _guardSend(generation, job);
      final ChunkedAttachmentState cached;
      try {
        cached = await bridge.chunkedAttachmentStatus(ownerId, ref.chunkedId!);
      } catch (_) {
        throw const TransferRejected('Cached file is missing or damaged');
      }
      _guardSend(generation, job);
      if (!cached.completed ||
          cached.size != ref.size ||
          cached.digest != ref.digest ||
          cached.chunkSize != ref.chunkSize ||
          ref.chunkSize! > standardChunkedAttachmentChunkSize) {
        throw const TransferRejected('Cached file failed validation');
      }
      await _packet({
        'type': 'offer',
        'id': id,
        'name': ref.name,
        'mimeType': ref.mimeType,
        'size': ref.size,
        'digest': ref.digest,
        'chunkSize': ref.chunkSize,
        'sentAt': sentAtMilliseconds,
        ...refPresentation(ref),
      });
      var next = await job.resume.future.timeout(ackTimeout);
      _guardSend(generation, job);
      baseline = next * ref.chunkSize!;
      final count = chunkCount(ref.size, ref.chunkSize!);
      while (next < count) {
        _guardSend(generation, job);
        if (ref.size > ChatAttachment.relayMaxBytes && !isDirect()) {
          throw const TransferInterrupted('Waiting for a direct connection');
        }
        final block = await bridge.readChunkedAttachment(
          ownerId,
          ref.chunkedId!,
          next,
        );
        _guardSend(generation, job);
        final expected = (ref.size - next * ref.chunkSize!).clamp(
          0,
          ref.chunkSize!,
        );
        if (block.length != expected) {
          throw const TransferRejected('Cached file chunk is damaged');
        }
        final hash = sha256.convert(block).toString();
        final parts = (block.length + pieceSize - 1) ~/ pieceSize;
        job.expectingNext = next + 1;
        job.block = _completer<int>();
        for (var piece = 0; piece < parts; piece++) {
          _guardSend(generation, job);
          if (ref.size > ChatAttachment.relayMaxBytes && !isDirect()) {
            throw const TransferInterrupted('Waiting for a direct connection');
          }
          final end = ((piece + 1) * pieceSize).clamp(0, block.length);
          await _packet({
            'type': 'part',
            'id': id,
            'block': next,
            'part': piece,
            'parts': parts,
            'blockDigest': hash,
            'data': base64Encode(
              Uint8List.sublistView(block, piece * pieceSize, end),
            ),
          });
        }
        next = await job.block!.future.timeout(ackTimeout);
        _guardSend(generation, job);
        final done = (next * ref.chunkSize!).clamp(0, ref.size);
        _progress(
          id,
          done,
          ref.size,
          FileTransferPhase.sending,
          false,
          rate: clock.elapsedMilliseconds == 0
              ? 0
              : (done - baseline) * 1000 / clock.elapsedMilliseconds,
        );
      }
      if (!job.done.isCompleted) await _packet({'type': 'finish', 'id': id});
      final received = await job.done.future.timeout(
        const Duration(minutes: 10),
      );
      _guardSend(generation, job);
      _progress(id, ref.size, ref.size, FileTransferPhase.completed, false);
      return received;
    } on TransferRejected {
      _progress(id, 0, ref.size, FileTransferPhase.failed, false);
      rethrow;
    } catch (error) {
      _progress(
        id,
        (job.confirmed * ref.chunkSize!).clamp(0, ref.size),
        ref.size,
        FileTransferPhase.waiting,
        false,
      );
      throw error is TransferInterrupted ? error : const TransferInterrupted();
    } finally {
      _outgoing.remove(id);
      clock.stop();
    }
  }

  static Map<String, Object?> refPresentation(AttachmentRef ref) => {
    if (ref.caption != null) 'caption': ref.caption,
    if (ref.groupId != null) 'groupId': ref.groupId,
    if (ref.groupIndex != null) 'groupIndex': ref.groupIndex,
    if (ref.groupCount != null) 'groupCount': ref.groupCount,
  };

  Future<void> receive(
    String packetId,
    String text, {
    required bool direct,
  }) async {
    if (_closed ||
        !isPacketId(packetId) ||
        text.length > 14000 ||
        utf8.encode(text).length > 14000) {
      return;
    }
    Map<String, dynamic> value;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic> ||
          decoded['v'] != 2 ||
          decoded['id'] is! String) {
        return;
      }
      value = decoded;
      validateChunkedAttachmentId(value['id'] as String);
    } catch (_) {
      return;
    }
    final type = value['type'];
    if (['resume', 'ack', 'complete', 'error'].contains(type)) {
      _control(value);
      return;
    }
    final generation = _generation;
    final pending = _receiving.then((_) async {
      if (_closed || generation != _generation) return;
      try {
        await _receive(value, direct, generation);
      } catch (error) {
        if (_closed || generation != _generation) return;
        final id = value['id'] as String;
        final job = _incoming.remove(id);
        _progress(
          id,
          0,
          job?.ref.size ?? 0,
          error is TransferInterrupted
              ? FileTransferPhase.waiting
              : FileTransferPhase.failed,
          true,
        );
        try {
          await _packet({
            'type': 'error',
            'id': id,
            'retryable': error is TransferInterrupted,
            'message': error is TransferInterrupted
                ? 'Waiting for a direct connection'
                : 'Could not verify or save the file. Retry after checking storage.',
          });
        } catch (_) {}
      }
    });
    _receiving = pending.catchError((Object _) {});
    await pending;
  }

  void _control(Map<String, dynamic> value) {
    if (value['type'] == 'complete') {
      final received = value['receivedAt'];
      if (received is! int || received < 0 || received > 8640000000000000) {
        return;
      }
      onReceipt?.call(value['id'] as String, received);
    }
    final job = _outgoing[value['id']];
    if (job == null) return;
    final next = value['next'];
    final count = chunkCount(job.ref.size, job.ref.chunkSize!);
    switch (value['type']) {
      case 'resume':
        if (next is! int || next < 0 || next > count) return;
        if (!job.resume.isCompleted) {
          job.confirmed = next;
          job.resume.complete(next);
        }
      case 'ack':
        if (next is! int || next != job.expectingNext || next > count) return;
        job.confirmed = next;
        if (job.block?.isCompleted == false) job.block!.complete(next);
      case 'complete':
        final received = value['receivedAt'];
        if (received is! int || received < 0 || received > 8640000000000000) {
          return;
        }
        if (!job.resume.isCompleted) job.resume.complete(count);
        if (!job.done.isCompleted) job.done.complete(received);
      case 'error':
        job.interrupt(
          value['retryable'] == true
              ? const TransferInterrupted('Waiting for a direct connection')
              : const TransferRejected(
                  'The recipient could not save or verify the file',
                ),
        );
    }
  }

  Future<void> _receive(
    Map<String, dynamic> value,
    bool direct,
    int generation,
  ) async {
    final id = value['id'] as String;
    checkIncoming?.call(id);
    switch (value['type']) {
      case 'offer':
        final sentAt = value['sentAt'];
        if (sentAt != null &&
            (sentAt is! int || sentAt < 0 || sentAt > 8640000000000000)) {
          throw const TransferRejected('Invalid file timestamp');
        }
        if (value['size'] is! int ||
            value['chunkSize'] is! int ||
            value['name'] is! String ||
            value['mimeType'] is! String ||
            value['digest'] is! String) {
          throw const TransferRejected('Invalid file offer');
        }
        final size = value['size'] as int,
            chunkSize = value['chunkSize'] as int;
        if (size > ChatAttachment.relayMaxBytes && !direct) {
          throw const TransferInterrupted('Waiting for a direct connection');
        }
        if (chunkSize <= 0 ||
            chunkSize > standardChunkedAttachmentChunkSize ||
            chunkCount(size, chunkSize) > 100000) {
          throw const TransferRejected('Invalid file block size');
        }
        if (_incoming.length >= 8 && !_incoming.containsKey(id)) {
          throw const TransferRejected('Too many incoming files');
        }
        final localId = sha256.convert(utf8.encode('$peerId:$id')).toString();
        final ref = AttachmentRef(
          name: value['name'] as String,
          mimeType: value['mimeType'] as String,
          size: size,
          digest: value['digest'] as String,
          chunkedId: localId,
          chunkSize: chunkSize,
          caption: value['caption'] as String?,
          groupId: value['groupId'] as String?,
          groupIndex: value['groupIndex'] as int?,
          groupCount: value['groupCount'] as int?,
        );
        final state = await bridge.beginChunkedAttachment(
          ownerId,
          localId,
          size,
          chunkSize,
          digest: ref.digest,
        );
        _guard(generation);
        if (state.size != size ||
            state.chunkSize != chunkSize ||
            (state.digest != null && state.digest != ref.digest)) {
          throw const TransferRejected('File offer metadata mismatch');
        }
        await onOffer(
          id,
          ref,
          value['sentAt'] is int ? value['sentAt'] as int : null,
        );
        _guard(generation);
        checkIncoming?.call(id);
        final job = _Incoming(ref, state.contiguousChunks);
        _incoming[id] = job;
        if (state.completed) {
          // Completion metadata is not a substitute for current readable bytes.
          final verified = await bridge.finishChunkedAttachment(
            ownerId,
            localId,
            expectedDigest: ref.digest,
          );
          _guardIncoming(id, job, generation);
          if (!verified.completed ||
              verified.digest != ref.digest ||
              verified.size != size) {
            throw const TransferRejected(
              'Cached file failed final verification',
            );
          }
          await _complete(id, job, generation);
        } else {
          _progress(
            id,
            (state.contiguousChunks * chunkSize).clamp(0, size),
            size,
            FileTransferPhase.receiving,
            true,
          );
          await _packet({
            'type': 'resume',
            'id': id,
            'next': state.contiguousChunks,
          });
        }
      case 'part':
        final job = _incoming[id];
        if (job == null) return;
        if (job.ref.size > ChatAttachment.relayMaxBytes && !direct) {
          throw const TransferInterrupted();
        }
        final block = value['block'],
            part = value['part'],
            parts = value['parts'],
            hash = value['blockDigest'],
            data = value['data'];
        if (block is! int ||
            part is! int ||
            parts is! int ||
            hash is! String ||
            data is! String ||
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash) ||
            data.length > ((pieceSize + 2) ~/ 3) * 4) {
          throw const TransferRejected('Invalid file piece');
        }
        if (block < job.next) {
          if (part == parts - 1) {
            await _packet({'type': 'ack', 'id': id, 'next': job.next});
          }
          return;
        }
        if (block != job.next ||
            block >= chunkCount(job.ref.size, job.ref.chunkSize!)) {
          throw const TransferRejected('File block is out of order');
        }
        final length = (job.ref.size - block * job.ref.chunkSize!).clamp(
          0,
          job.ref.chunkSize!,
        );
        final expectedParts = (length + pieceSize - 1) ~/ pieceSize;
        if (parts != expectedParts || part < 0 || part >= parts) {
          throw const TransferRejected('Invalid file piece bounds');
        }
        final bytes = base64Decode(data);
        if (bytes.length != (length - part * pieceSize).clamp(0, pieceSize)) {
          throw const TransferRejected('Invalid file piece length');
        }
        if (job.pieces == null) {
          job.pieces = List<Uint8List?>.filled(parts, null);
          job.blockDigest = hash;
        }
        if (job.blockDigest != hash) {
          throw const TransferRejected('Conflicting file block digest');
        }
        final previous = job.pieces![part];
        if (previous != null && base64Encode(previous) != data) {
          throw const TransferRejected('Conflicting duplicate file piece');
        }
        job.pieces![part] = bytes;
        if (job.pieces!.every((piece) => piece != null)) {
          final builder = BytesBuilder(copy: false);
          for (final piece in job.pieces!) {
            builder.add(piece!);
          }
          final blockBytes = builder.takeBytes();
          if (sha256.convert(blockBytes).toString() != hash) {
            throw const TransferRejected('File block checksum mismatch');
          }
          await bridge.writeChunkedAttachment(
            ownerId,
            job.ref.chunkedId!,
            job.next,
            blockBytes,
          );
          _guardIncoming(id, job, generation);
          job.next++;
          job.pieces = null;
          job.blockDigest = null;
          final done = (job.next * job.ref.chunkSize!).clamp(0, job.ref.size);
          _progress(
            id,
            done,
            job.ref.size,
            FileTransferPhase.receiving,
            true,
            rate: job.clock.elapsedMilliseconds == 0
                ? 0
                : (done - job.baseline) * 1000 / job.clock.elapsedMilliseconds,
          );
          await _packet({'type': 'ack', 'id': id, 'next': job.next});
        }
      case 'finish':
        final job = _incoming[id];
        if (job == null) return;
        if (job.ref.size > ChatAttachment.relayMaxBytes && !direct) {
          throw const TransferInterrupted();
        }
        _progress(
          id,
          job.ref.size,
          job.ref.size,
          FileTransferPhase.verifying,
          true,
        );
        final state = await bridge.finishChunkedAttachment(
          ownerId,
          job.ref.chunkedId!,
          expectedDigest: job.ref.digest,
        );
        _guardIncoming(id, job, generation);
        if (!state.completed ||
            state.digest != job.ref.digest ||
            state.size != job.ref.size) {
          throw const TransferRejected('File failed final verification');
        }
        await _complete(id, job, generation);
    }
  }

  Future<void> _complete(String id, _Incoming job, int generation) async {
    _guardIncoming(id, job, generation);
    final received = await onCompleted(id, job.ref);
    _guardIncoming(id, job, generation);
    _progress(
      id,
      job.ref.size,
      job.ref.size,
      FileTransferPhase.completed,
      true,
    );
    await _packet({'type': 'complete', 'id': id, 'receivedAt': received});
    _incoming.remove(id);
  }

  void disconnected() {
    _generation++;
    for (final job in _outgoing.values) {
      job.interrupt(const TransferInterrupted());
    }
    _incoming.clear();
  }

  void dispose() {
    if (_closed) return;
    disconnected();
    _closed = true;
  }
}

Completer<T> _completer<T>() {
  final value = Completer<T>();
  unawaited(
    value.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
  );
  return value;
}

class _Outgoing {
  _Outgoing(this.ref);
  final AttachmentRef ref;
  final resume = _completer<int>(), done = _completer<int>();
  Completer<int>? block;
  int confirmed = 0, expectingNext = 0;
  Object? interruption;
  void interrupt(Object error) {
    interruption = error;
    if (!resume.isCompleted) resume.completeError(error);
    if (block?.isCompleted == false) block!.completeError(error);
    if (!done.isCompleted) done.completeError(error);
  }
}

class _Incoming {
  _Incoming(this.ref, this.next)
    : baseline = (next * ref.chunkSize!).clamp(0, ref.size);
  final AttachmentRef ref;
  final int baseline;
  int next;
  List<Uint8List?>? pieces;
  String? blockDigest;
  final clock = Stopwatch()..start();
}
