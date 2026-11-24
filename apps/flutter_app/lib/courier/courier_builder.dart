import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../chat/cache_policy.dart';
import '../chat/chat_attachment.dart';
import '../delivery/delivery_crypto_bridge.dart';
import '../delivery/delivery_envelope.dart';
import 'courier_merkle.dart';
import 'courier_policy.dart';
import 'sender_job.dart';
import 'sender_jobs.dart';

class _Digest implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest digest) => value = digest;
  @override
  void close() {}
}

class CourierBuilder {
  CourierBuilder({
    required this.jobs,
    required this.crypto,
    required this.budget,
    int Function()? clock,
  }) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);
  final CourierSenderJobs jobs;
  final DeliveryCryptoBridge crypto;
  final CachePolicy budget;
  final int Function() _clock;
  static String reservationKey(String id) => 'courier_send_$id';
  Future<CourierSenderJob> prepare({
    required String id,
    required String peerId,
    required DeliveryEnvelope envelope,
    ChatAttachment? file,
    bool Function()? isCurrent,
  }) => jobs.withPreparation(
    id,
    () => _prepare(
      id: id,
      peerId: peerId,
      envelope: envelope,
      file: file,
      isCurrent: isCurrent,
    ),
  );
  Future<CourierSenderJob> _prepare({
    required String id,
    required String peerId,
    required DeliveryEnvelope envelope,
    ChatAttachment? file,
    bool Function()? isCurrent,
  }) async {
    void guard() {
      if (isCurrent?.call() == false) {
        throw StateError('Courier preparation interrupted');
      }
    }

    guard();
    await jobs.initialize();
    guard();
    final payload = CourierPayload(envelope, file: file),
        descriptor = envelope.payload['file'];
    if (file != null &&
        (descriptor is! Map ||
            descriptor['name'] != file.name ||
            descriptor['mime'] != file.mimeType ||
            descriptor['size'] != file.size ||
            descriptor['digest'] is! String)) {
      throw const FormatException('Missing signed attachment descriptor');
    }
    if (file == null && descriptor != null) {
      throw const FormatException('Missing delivery attachment');
    }
    final existing = jobs.find(id);
    if (existing != null &&
        (existing.peerId != peerId ||
            existing.messageId != envelope.messageId ||
            existing.scope != envelope.scope ||
            existing.event['signature'] != envelope.event['signature'] ||
            existing.packageCount != payload.packageCount ||
            existing.terminal)) {
      throw StateError('Courier job changed');
    }
    if (existing?.manifest != null) return existing!;
    const headerBudget = 1024 * 1024;
    final estimate =
            headerBudget +
            payload.packageCount *
                CourierPolicy.packageCost(payload.packageSize + 40),
        key = reservationKey(id);
    await budget.resizeCourierReservation(
      key,
      estimate,
      budget.entryWritten(key),
    );
    guard();
    try {
      if (existing == null) {
        final now = _clock(),
            expires = now + CourierPolicy.retentionMilliseconds;
        final created = await crypto.deliveryCall('newJob', {
          'peerId': peerId,
          'jobId': id,
          'scope': envelope.scope,
          'count': payload.packageCount,
          'now': now,
          'expiresAt': expires,
        });
        guard();
        await jobs.create(
          CourierSenderJob(
            id: id,
            peerId: peerId,
            messageId: envelope.messageId,
            scope: envelope.scope,
            sentAt: envelope.sentAt,
            expiresAt: expires,
            packageCount: payload.packageCount,
            protectedState: created['state'] as String,
            mailbox: created['mailbox'] as String,
            mailboxBucket: created['bucket'] as int,
            receiptChallenge: created['receiptChallenge'] as String,
            event: envelope.event,
          ),
        );
        guard();
      }
    } catch (_) {
      if (jobs.find(id) == null) {
        try {
          await jobs.journal.recover();
          await budget.resizeCourierReservation(key, 0, 0, afterCleanup: true);
        } catch (_) {
          /* Keep uncertain staging reserved until owner recovery. */
        }
      }
      rethrow;
    }
    final job = jobs.find(id)!;
    final fullDigest = _Digest(),
        fileDigest = _Digest(),
        full = sha256.startChunkedConversion(fullDigest),
        fileHash = sha256.startChunkedConversion(fileDigest);
    var index = 0, offset = 0;
    final headerSize = payload.size - (file?.size ?? 0);
    try {
      await for (final plain in payload.packages()) {
        guard();
        full.add(plain);
        if (file != null && offset + plain.length > headerSize) {
          fileHash.add(plain.sublist(max(0, headerSize - offset)));
        }
        offset += plain.length;
        final plainHash = sha256.convert(plain).toString();
        if (jobs.find(id)!.hasPackage(index)) {
          if (await jobs.preparedPlaintextHash(id, index) != plainHash) {
            await jobs.cancel(id);
            throw const FormatException(
              'Attachment changed during preparation',
            );
          }
        } else {
          final result = await crypto.deliveryCall('encryptPackage', {
            'state': job.protectedState,
            'index': index,
            'plaintext': base64UrlEncode(plain).replaceAll('=', ''),
            'now': _clock(),
          });
          guard();
          final bytes = base64Url.decode(
            base64Url.normalize(result['ciphertext'] as String),
          );
          await jobs.stagePackage(id, index, bytes, plaintextHash: plainHash);
          guard();
        }
        index++;
        budget.noteWritten(
          key,
          min(
            estimate,
            headerBudget +
                jobs.find(id)!.readyCount *
                    CourierPolicy.packageCost(payload.packageSize + 40),
          ),
        );
      }
      full.close();
      fileHash.close();
      if (file != null &&
          (descriptor as Map)['digest'] != fileDigest.value.toString()) {
        await jobs.cancel(id);
        throw const FormatException('Attachment digest changed');
      }
      final tree = await CourierMerkleTree.build(await jobs.packageHashes(id));
      guard();
      final sealed = await crypto.deliveryCall('sealManifest', {
        'state': job.protectedState,
        'event': envelope.event,
        'metadata': {
          'size': payload.size,
          'contentHash': fullDigest.value.toString(),
          'merkleRoot': tree.root,
          'name': file?.name ?? 'message',
          'mime': file?.mimeType ?? 'application/vnd.chta.delivery+json',
        },
        'now': _clock(),
      });
      guard();
      await jobs.setManifest(
        id,
        Map<String, Object?>.from(sealed['manifest'] as Map),
        sealed['manifestHash'] as String,
        tree.root,
      );
      guard();
      await budget.complete(key);
      return jobs.find(id)!;
    } catch (_) {
      try {
        full.close();
      } catch (_) {}
      try {
        fileHash.close();
      } catch (_) {}
      rethrow;
    }
  }
}
