import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../chat/attachment_ref.dart';
import '../chat/cache_policy.dart';
import '../chat/chunked_attachment_bridge.dart';
import '../delivery/delivery_crypto_bridge.dart';
import '../delivery/delivery_envelope.dart';
import 'courier_journal.dart';
import 'courier_models.dart';
import 'courier_service.dart';

class CourierOffer {
  const CourierOffer(this.node, this.item);
  final CourierNode node;
  final Map<String, Object?> item;
}

class CourierReceived {
  const CourierReceived(this.envelope, this.receivedAt, {this.attachment});
  final DeliveryEnvelope envelope;
  final int receivedAt;
  final AttachmentRef? attachment;
}

class _Digest implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest value) => this.value = value;
  @override
  void close() {}
}

/// Receives into the ordinary encrypted chunk cache. Only a bounded plaintext
/// header and one file chunk are in memory; restart resumes from durable chunks.
class CourierReceiver {
  CourierReceiver({
    required this.ownerId,
    required this.crypto,
    required this.service,
    required this.journal,
    required this.cache,
    required this.budget,
    required this.authorize,
    this.authorizeManifest,
    required this.isDeleted,
    required this.existingReceivedAt,
    required this.commit,
    this.cachedEnvelope,
    this.referencesFile,
    this.onProgress,
    int Function()? clock,
    bool Function()? isCurrent,
  }) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
       _isCurrent = isCurrent ?? (() => true);
  final String ownerId;
  final DeliveryCryptoBridge crypto;
  final CourierService service;
  final CourierJournal journal;
  final ChunkedAttachmentBridge? cache;
  final CachePolicy budget;
  final Future<bool> Function(DeliveryEnvelope) authorize;
  final Future<bool> Function(DeliveryEnvelope, Map<String, Object?>)?
  authorizeManifest;
  final bool Function(DeliveryEnvelope) isDeleted;
  final Future<int?> Function(DeliveryEnvelope) existingReceivedAt;
  final Future<void> Function(CourierReceived) commit;
  final DeliveryEnvelope? Function(DeliveryEnvelope)? cachedEnvelope;
  final bool Function(String id)? referencesFile;
  final void Function(DeliveryEnvelope, int verifiedBytes, int totalBytes)?
  onProgress;
  final int Function() _clock;
  final bool Function() _isCurrent;
  final _entries = <String, Map<String, Object?>>{}, _running = <String>{};
  Future<void>? _initialization;
  Future<void> _tail = Future.value();
  bool _closed = false;
  int _queued = 0;
  void _guard() {
    if (_closed || !_isCurrent()) throw StateError('Courier identity changed');
  }

  static String keyFor(Map<String, Object?> item) => sha256
      .convert(
        utf8.encode(
          '${item['from']}\u0000${item['jobId']}\u0000${item['manifestHash']}',
        ),
      )
      .toString();
  String _budgetKey(String key) => 'courier_inbox_$key';
  String _fileId(String key) => 'courier_$key';
  Future<void> initialize() {
    final old = _initialization;
    if (old != null) return old;
    final pending = _initialize();
    _initialization = pending;
    unawaited(
      pending.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          if (identical(_initialization, pending)) _initialization = null;
        },
      ),
    );
    return pending;
  }

  Future<void> _initialize() async {
    await budget.initialize();
    await journal.initialize();
    _guard();
    final source = await journal.read('registry');
    _guard();
    if (source == null) return;
    _entries.clear();
    final ids = List<String>.from(jsonDecode(source) as List);
    if (ids.length > 128 ||
        ids.toSet().length != ids.length ||
        ids.any((id) => !courierHex(id, 64))) {
      throw const FormatException('Invalid Courier inbox registry');
    }
    for (final id in ids) {
      final text = await journal.read('job_$id');
      _guard();
      if (text == null) throw StateError('Courier inbox metadata missing');
      final entry = Map<String, Object?>.from(jsonDecode(text) as Map);
      if (entry.length != 6 ||
          entry['opened'] is! Map ||
          entry['expiresAt'] is! int) {
        throw const FormatException('Invalid Courier inbox job');
      }
      _entries[id] = entry;
      await budget.resizeCourierReservation(
        _budgetKey(id),
        128 * 1024,
        128 * 1024,
      );
    }
  }

  Future<void> _mutate(Future<void> Function() action) {
    if (_closed || _queued >= 16) {
      return Future.error(StateError('Courier inbox busy'));
    }
    _queued++;
    final work = _tail
        .then((_) async {
          _guard();
          await action();
          _guard();
        })
        .whenComplete(() => _queued--);
    _tail = work.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return work;
  }

  Future<void> _save(String key, Map<String, Object?> value) => _mutate(
    () async {
      if (!_entries.containsKey(key)) {
        final author = ((value['opened'] as Map)['event'] as Map)['authorId'];
        if (_entries.length >= 128 ||
            _entries.values
                    .where(
                      (e) =>
                          ((e['opened'] as Map)['event'] as Map)['authorId'] ==
                          author,
                    )
                    .length >=
                32) {
          throw StateError('Courier inbox full');
        }
        await budget.resizeCourierReservation(_budgetKey(key), 128 * 1024, 0);
        _guard();
      }
      await journal.commit({
        'job_$key': jsonEncode(value),
        'registry': jsonEncode({..._entries.keys, key}.toList()),
      }, {});
      _guard();
      _entries[key] = value;
      budget.noteWritten(_budgetKey(key), 128 * 1024);
    },
  );
  Future<Map<String, Object?>> _makeReceipt(
    String key,
    Map<String, Object?> entry,
    int time,
  ) async {
    final opened = entry['opened'] as Map,
        event = opened['event'] as Map,
        now = _clock();
    final receipt = await crypto.deliveryCall('signControl', {
      'kind': 'receipt',
      'challenge': opened['receiptChallenge'],
      'body': {
        'jobId': opened['jobId'],
        'messageId': event['messageId'],
        'manifestHash': opened['manifestHash'],
        'receivedAt': time,
      },
      'now': now,
      'expiresAt': now + 120000,
    });
    _guard();
    await _save(key, {...entry, 'committedAt': time, 'receipt': receipt});
    return receipt;
  }

  Future<Map<String, Object?>?> receive(List<CourierOffer> offers) async {
    _guard();
    if (offers.isEmpty || offers.length > 64) {
      throw const FormatException('Invalid Courier offer set');
    }
    await initialize();
    _guard();
    final item = offers.first.item, key = keyFor(item);
    if (_running.length >= 4 || !_running.add(key)) {
      throw StateError('Courier pickup busy');
    }
    try {
      return await _receive(key, item, offers);
    } finally {
      _running.remove(key);
    }
  }

  Future<Map<String, Object?>?> _receive(
    String key,
    Map<String, Object?> item,
    List<CourierOffer> offers,
  ) async {
    final old = _entries[key];
    if (old?['receipt'] is Map) {
      return Map<String, Object?>.from(old!['receipt'] as Map);
    }
    if (old?['committedAt'] is int) {
      return _makeReceipt(key, old!, old['committedAt'] as int);
    }
    final opened = await crypto.deliveryCall('openManifest', {
      'manifest': item['manifest'],
      'now': _clock(),
    });
    _guard();
    final event = Map<String, Object?>.from(opened['event'] as Map),
        metadata = Map<String, Object?>.from(opened['metadata'] as Map);
    final size = metadata['size'], count = opened['count'];
    if (size is! int ||
        size < 4 ||
        size > courierMaxPackages * courierPackageBytes ||
        count is! int ||
        count !=
            max(3, (size + courierPackageBytes - 1) ~/ courierPackageBytes) ||
        opened['jobId'] != item['jobId'] ||
        opened['manifestHash'] != item['manifestHash'] ||
        event['authorId'] != item['from'] ||
        metadata['contentHash'] is! String ||
        !courierHex(metadata['contentHash'] as String, 64)) {
      throw const FormatException('Invalid Courier reconstruction metadata');
    }
    final provisional = DeliveryEnvelope.fromJson({
      'version': 2,
      'event': event,
      'payload': '{}',
    });
    if (isDeleted(provisional) ||
        !await authorize(provisional) ||
        (authorizeManifest != null &&
            !await authorizeManifest!(provisional, metadata))) {
      return null;
    }
    _guard();
    var entry =
        old ??
        <String, Object?>{
          'opened': opened,
          'manifest': item['manifest'],
          'expiresAt': item['expiresAt'],
          'header': null,
          'committedAt': null,
          'receipt': null,
        };
    if (old == null) await _save(key, entry);
    final partSize = (size + count - 1) ~/ count,
        prefetched = <int, Uint8List>{};
    Future<Uint8List> read(int index) async {
      _guard();
      if (isDeleted(provisional) || !await authorize(provisional)) {
        throw StateError('Delivery scope changed');
      }
      _guard();
      final cached = prefetched.remove(index);
      if (cached != null) return cached;
      for (final offer in offers) {
        final v = offer.item;
        if (v['manifestHash'] != opened['manifestHash'] ||
            v['jobId'] != opened['jobId'] ||
            v['count'] != count ||
            v['root'] != opened['merkleRoot']) {
          continue;
        }
        final available = IndexBitmap.fromEncoded(
          count,
          v['available'] as String,
        );
        if (!available.contains(index) || available.length >= count) continue;
        try {
          final package = await service.readPackage(
            offer.node,
            v,
            bucket: opened['bucket'] as int,
            index: index,
          );
          _guard();
          final plain = await crypto.deliveryCall('decryptPackage', {
            'state': opened['state'],
            'index': index,
            'ciphertext': base64UrlEncode(package.bytes).replaceAll('=', ''),
            'proof': package.metadata['proof'],
            'now': _clock(),
          });
          _guard();
          final bytes = base64Url.decode(
            base64Url.normalize(plain['plaintext'] as String),
          );
          if (bytes.length !=
              (index == count - 1 ? size - index * partSize : partSize)) {
            throw const FormatException('Courier plaintext size mismatch');
          }
          return bytes;
        } catch (_) {
          _guard();
        }
      }
      throw StateError('Courier package unavailable');
    }

    Uint8List header;
    DeliveryEnvelope envelope;
    final known = cachedEnvelope?.call(provisional);
    if (entry['header'] is String) {
      header = base64Url.decode(base64Url.normalize(entry['header'] as String));
    } else if (metadata['offerHeader'] case final String payload) {
      if (utf8.encode(jsonEncode(payload)).length > 11500) {
        throw const FormatException('Courier file offer is too large');
      }
      header = _encodeHeader(
        DeliveryEnvelope.fromJson({
          'version': 2,
          'event': event,
          'payload': payload,
        }),
      );
    } else if (known != null &&
        known.event['signature'] == event['signature']) {
      header = _encodeHeader(known);
    } else {
      final buffer = BytesBuilder(copy: false);
      int? target;
      for (var i = 0; i < count; i++) {
        final bytes = await read(i);
        prefetched[i] = bytes;
        buffer.add(bytes);
        final all = buffer.toBytes();
        if (all.length >= 4) {
          target ??=
              4 + ByteData.sublistView(all, 0, 4).getUint32(0, Endian.big);
          if (target < 5 || target > 65540 || target > size) {
            throw const FormatException('Invalid Courier header length');
          }
        }
        if (target != null && all.length >= target) break;
        if (i >= 2) throw const FormatException('Courier header incomplete');
      }
      final bytes = buffer.takeBytes();
      if (target == null || bytes.length < target) {
        throw const FormatException('Courier header truncated');
      }
      header = Uint8List.sublistView(bytes, 0, target);
    }
    if (header.length < 5 || header.length > 65540 || header.length > size) {
      throw const FormatException('Invalid Courier header length');
    }
    envelope = DeliveryEnvelope.fromJson(
      Map<String, Object?>.from(
        jsonDecode(utf8.decode(header.sublist(4))) as Map,
      ),
    );
    if (envelope.event['signature'] != event['signature']) {
      throw const FormatException('Courier author proof mismatch');
    }
    await envelope.verify(
      crypto,
      author: provisional.authorId,
      scope: provisional.scope,
      messageId: provisional.messageId,
      sentAt: provisional.sentAt,
      now: _clock(),
    );
    _guard();
    if (isDeleted(envelope) || !await authorize(envelope)) return null;
    final existing = await existingReceivedAt(envelope);
    _guard();
    if (existing != null) return _makeReceipt(key, entry, existing);
    entry = {...entry, 'header': base64UrlEncode(header).replaceAll('=', '')};
    await _save(key, entry);
    AttachmentRef? ref;
    final descriptor = envelope.payload['file'];
    if (descriptor != null) {
      if (descriptor is! Map || cache == null) {
        throw StateError('Encrypted file cache unavailable');
      }
      ref = AttachmentRef(
        name: descriptor['name'] as String,
        mimeType: descriptor['mime'] as String,
        size: descriptor['size'] as int,
        digest: descriptor['digest'] as String,
        chunkedId: _fileId(key),
        chunkSize: standardChunkedAttachmentChunkSize,
        caption: descriptor['caption'] as String?,
        groupId: descriptor['groupId'] as String?,
        groupIndex: descriptor['groupIndex'] as int?,
        groupCount: descriptor['groupCount'] as int?,
      );
      if (header.length + ref.size != size) {
        throw const FormatException('Courier file size mismatch');
      }
      final state = await cache!.beginChunkedAttachment(
        ownerId,
        ref.chunkedId!,
        ref.size,
        ref.chunkSize!,
        digest: ref.digest,
      );
      _guard();
      var fileOffset = min(state.contiguousChunks * state.chunkSize, ref.size),
          written = fileOffset;
      var buffer = Uint8List(ref.chunkSize!), used = 0;
      for (
        var index = (header.length + fileOffset) ~/ partSize;
        index < count && fileOffset < ref.size;
        index++
      ) {
        final bytes = await read(index);
        _guard();
        final skip = max(0, header.length + fileOffset - index * partSize);
        for (var offset = skip; offset < bytes.length;) {
          final take = min(buffer.length - used, bytes.length - offset);
          buffer.setRange(used, used + take, bytes, offset);
          used += take;
          offset += take;
          fileOffset += take;
          if (fileOffset > ref.size) {
            throw const FormatException('Courier file overflow');
          }
          if (used == buffer.length || fileOffset == ref.size) {
            await cache!.writeChunkedAttachment(
              ownerId,
              ref.chunkedId!,
              written ~/ ref.chunkSize!,
              Uint8List.sublistView(buffer, 0, used),
            );
            _guard();
            written += used;
            used = 0;
            buffer = Uint8List(ref.chunkSize!);
            onProgress?.call(envelope, written, ref.size);
          }
        }
      }
      if (fileOffset != ref.size) {
        throw const FormatException('Courier file incomplete');
      }
      final completed = await cache!.finishChunkedAttachment(
        ownerId,
        ref.chunkedId!,
        expectedDigest: ref.digest,
      );
      _guard();
      if (!completed.completed || completed.digest != ref.digest) {
        throw const FormatException('Courier file digest mismatch');
      }
    } else if (header.length != size) {
      throw const FormatException('Unexpected Courier payload bytes');
    }
    final digest = _Digest(), hash = sha256.startChunkedConversion(digest);
    hash.add(header);
    if (ref != null) {
      for (
        var index = 0;
        index < chunkCount(ref.size, ref.chunkSize!);
        index++
      ) {
        hash.add(
          await cache!.readChunkedAttachment(ownerId, ref.chunkedId!, index),
        );
        _guard();
      }
    }
    hash.close();
    if (digest.value.toString() != metadata['contentHash']) {
      throw const FormatException('Courier reconstruction hash mismatch');
    }
    if (isDeleted(envelope) || !await authorize(envelope)) return null;
    _guard();
    final time = _clock();
    await commit(CourierReceived(envelope, time, attachment: ref));
    _guard();
    final durableTime = await existingReceivedAt(envelope) ?? time;
    _guard();
    entry = {...entry, 'committedAt': durableTime};
    await _save(key, entry);
    return _makeReceipt(key, entry, durableTime);
  }

  Uint8List _encodeHeader(DeliveryEnvelope envelope) {
    final json = utf8.encode(jsonEncode(envelope.toJson()));
    final header = Uint8List(4 + json.length);
    ByteData.sublistView(header).setUint32(0, json.length, Endian.big);
    header.setRange(4, header.length, json);
    return header;
  }

  /// Called after confirmed receipt deposits; cached owner attachments remain.
  Future<void> confirmed(Map<String, Object?> item) async {
    await initialize();
    final key = keyFor(item);
    if (_running.contains(key)) return;
    await _mutate(() async {
      if (_entries[key]?['receipt'] is! Map) return;
      if (cache != null && referencesFile?.call(_fileId(key)) == false) {
        await cache!.deleteChunkedAttachment(ownerId, _fileId(key));
        _guard();
      }
      await journal.commit(
        {'registry': jsonEncode(_entries.keys.where((k) => k != key).toList())},
        {'job_$key'},
      );
      _guard();
      _entries.remove(key);
      await journal.recover();
      _guard();
      await budget.resizeCourierReservation(
        _budgetKey(key),
        0,
        0,
        afterCleanup: true,
      );
    });
  }

  Future<void> expire() async {
    await initialize();
    for (final pair in _entries.entries.toList()) {
      if (_running.contains(pair.key) ||
          (pair.value['expiresAt'] as int) > _clock()) {
        continue;
      }
      await _mutate(() async {
        if (_running.contains(pair.key)) return;
        // Actual history references protect direct attachments, including a
        // crash after history commit. Group staging has its own durable copy.
        final id = _fileId(pair.key);
        if (referencesFile?.call(id) == false && cache != null) {
          await cache!.deleteChunkedAttachment(ownerId, id);
          _guard();
        }
        await journal.commit(
          {
            'registry': jsonEncode(
              _entries.keys.where((k) => k != pair.key).toList(),
            ),
          },
          {'job_${pair.key}'},
        );
        _guard();
        _entries.remove(pair.key);
        await journal.recover();
        _guard();
        await budget.resizeCourierReservation(
          _budgetKey(pair.key),
          0,
          0,
          afterCleanup: true,
        );
      });
    }
  }

  void close() {
    _closed = true;
    journal.close();
  }
}
