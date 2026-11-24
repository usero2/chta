import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../chat/attachment_ref.dart';
import '../../chat/attachment_source.dart';
import '../../chat/attachment_store.dart';
import '../../chat/managed_attachment_cache.dart';
import '../../chat/cache_policy.dart';
import '../../chat/chat_attachment.dart';
import '../group_blob_bridge.dart';

const swarmPieceSize = 256 * 1024;
const swarmPartSize = 8 * 1024;
const swarmMaxFrameBytes = 16 * 1024;
const swarmMaxPieces = 40960;
const swarmMaxDirectBytes = 10 * 1024 * 1024 * 1024;
const swarmMaxRelayBytes = 25 * 1024 * 1024;
final _digestPattern = RegExp(r'^[0-9a-f]{64}$');
final _filePattern = RegExp(r'^[0-9a-f]{32}$');
final _ownerPattern = RegExp(r'^did:cht:[0-9a-f]{64}$');
final _groupPattern = RegExp(r'^group:[0-9a-f]{64}$');

/// Unsigned content model. Callers must first verify the enclosing signed group file event.
class SwarmManifest {
  SwarmManifest({
    required this.groupId,
    required this.epoch,
    required this.uploaderId,
    required this.fileId,
    required this.name,
    required this.mimeType,
    required this.size,
    required this.pieceSize,
    required this.digest,
    required this.merkleRoot,
    this.caption,
  }) {
    if (!_groupPattern.hasMatch(groupId) ||
        epoch < 1 ||
        !_ownerPattern.hasMatch(uploaderId) ||
        !_filePattern.hasMatch(fileId) ||
        pieceSize != swarmPieceSize ||
        size < 0 ||
        size > swarmMaxDirectBytes ||
        ((size + pieceSize - 1) ~/ pieceSize) > swarmMaxPieces ||
        !_digestPattern.hasMatch(digest) ||
        !_digestPattern.hasMatch(merkleRoot)) {
      throw const FormatException('Invalid swarm manifest');
    }
    ChatAttachment.validateStreamedMetadata(name, mimeType, size);
    ChatAttachment.validatePresentation(caption, null, null, null);
  }
  final String groupId, uploaderId, fileId, name, mimeType, digest, merkleRoot;
  final int epoch, size, pieceSize;
  final String? caption;
  int get pieceCount => (size + pieceSize - 1) ~/ pieceSize;
  int pieceLength(int index) {
    if (index < 0 || index >= pieceCount) {
      throw RangeError.index(index, List.filled(pieceCount, null));
    }
    return min(pieceSize, size - index * pieceSize);
  }

  Map<String, Object?> toJson() => {
    'groupId': groupId,
    'epoch': epoch,
    'uploaderId': uploaderId,
    'fileId': fileId,
    'name': name,
    'mimeType': mimeType,
    'size': size,
    'pieceSize': pieceSize,
    'digest': digest,
    'merkleRoot': merkleRoot,
    if (caption != null) 'caption': caption,
  };
  factory SwarmManifest.fromJson(Map<String, dynamic> json) {
    const required = {
      'groupId',
      'epoch',
      'uploaderId',
      'fileId',
      'name',
      'mimeType',
      'size',
      'pieceSize',
      'digest',
      'merkleRoot',
    };
    if (!json.keys.toSet().containsAll(required) ||
        json.keys.any((k) => !required.contains(k) && k != 'caption') ||
        json['groupId'] is! String ||
        json['epoch'] is! int ||
        json['uploaderId'] is! String ||
        json['fileId'] is! String ||
        json['name'] is! String ||
        json['mimeType'] is! String ||
        json['size'] is! int ||
        json['pieceSize'] is! int ||
        json['digest'] is! String ||
        json['merkleRoot'] is! String ||
        (json['caption'] != null && json['caption'] is! String)) {
      throw const FormatException('Invalid swarm manifest');
    }
    return SwarmManifest(
      groupId: json['groupId'],
      epoch: json['epoch'],
      uploaderId: json['uploaderId'],
      fileId: json['fileId'],
      name: json['name'],
      mimeType: json['mimeType'],
      size: json['size'],
      pieceSize: json['pieceSize'],
      digest: json['digest'],
      merkleRoot: json['merkleRoot'],
      caption: json['caption'],
    );
  }
  String get identityHash =>
      sha256.convert(utf8.encode(jsonEncode(toJson()))).toString();
}

class SwarmPiece {
  SwarmPiece(this.bytes, this.proof);
  final Uint8List bytes;
  final List<String> proof;
}

class SwarmCacheStatus {
  SwarmCacheStatus(this.verifiedBytes, this.complete, this.available);
  final int verifiedBytes;
  final bool complete;
  final Set<int> available;
}

Uint8List _u32(int n) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, n, Endian.big);
List<int> _leaf(int index, List<int> bytes) =>
    sha256.convert([0, ..._u32(index), ..._u32(bytes.length), ...bytes]).bytes;
List<int> _padding(int index) => sha256.convert([2, ..._u32(index)]).bytes;
List<int> _parent(List<int> left, List<int> right) =>
    sha256.convert([1, ...left, ...right]).bytes;
String _hex(List<int> bytes) =>
    bytes.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
List<int> _unhex(String value) => [
  for (var i = 0; i < value.length; i += 2)
    int.parse(value.substring(i, i + 2), radix: 16),
];
int _treeWidth(int n) {
  var width = 1;
  while (width < max(1, n)) {
    width *= 2;
  }
  return width;
}

int _depth(int n) {
  var width = _treeWidth(n), d = 0;
  while (width > 1) {
    width ~/= 2;
    d++;
  }
  return d;
}

List<List<List<int>>> _tree(List<List<int>> leaves) {
  final width = _treeWidth(leaves.length);
  var level = <List<int>>[
    ...leaves,
    for (var i = leaves.length; i < width; i++) _padding(i),
  ];
  final levels = <List<List<int>>>[level];
  while (level.length > 1) {
    level = [
      for (var i = 0; i < level.length; i += 2) _parent(level[i], level[i + 1]),
    ];
    levels.add(level);
  }
  return levels;
}

List<String> _proof(List<List<List<int>>> levels, int index) {
  final out = <String>[];
  var at = index;
  for (var level = 0; level < levels.length - 1; level++) {
    out.add(_hex(levels[level][at ^ 1]));
    at >>= 1;
  }
  return out;
}

bool _verify(SwarmManifest m, int index, List<int> bytes, List<String> proof) {
  if (index < 0 ||
      index >= m.pieceCount ||
      bytes.length != m.pieceLength(index) ||
      proof.length != _depth(m.pieceCount)) {
    return false;
  }
  var hash = _leaf(index, bytes), at = index;
  for (final sibling in proof) {
    if (!_digestPattern.hasMatch(sibling)) return false;
    final other = _unhex(sibling);
    hash = at.isEven ? _parent(hash, other) : _parent(other, hash);
    at >>= 1;
  }
  return _hex(hash) == m.merkleRoot;
}

class SparseSwarmCache {
  SparseSwarmCache(
    this.ownerId, {
    required this.blobs,
    required this.attachments,
  }) {
    if (!_ownerPattern.hasMatch(ownerId)) {
      throw const FormatException('Invalid cache owner');
    }
  }
  final String ownerId;
  final GroupBlobBridge blobs;
  final AttachmentStore attachments;
  final _locks = <String, Future<void>>{};
  String _pageKey(SwarmManifest m, int page) =>
      'sw_${m.identityHash}_${page.toRadixString(16)}';
  String _context(SwarmManifest m, int index) =>
      'cht-swarm-piece-v1\u0000$ownerId\u0000${m.groupId}\u0000${m.uploaderId}\u0000${m.fileId}\u0000${m.epoch}\u0000$index\u0000${m.identityHash}';
  Future<Map<String, dynamic>> _page(SwarmManifest m, int page) async {
    final raw = await blobs.loadGroupBlob(ownerId, _pageKey(m, page));
    if (raw == null) return {};
    final value = jsonDecode(raw);
    if (value is! Map<String, dynamic> || value.length > 128) {
      throw const FormatException('Invalid swarm cache page');
    }
    return value;
  }

  Future<T> _serial<T>(String key, Future<T> Function() action) async {
    final previous = _locks[key];
    final done = Completer<void>();
    _locks[key] = done.future;
    if (previous != null) await previous;
    try {
      return await action();
    } finally {
      done.complete();
      if (identical(_locks[key], done.future)) _locks.remove(key);
    }
  }

  Future<void> begin(SwarmManifest manifest) async {
    await status(manifest);
  }

  Future<SwarmManifest> importFile({
    required String groupId,
    required int epoch,
    required String uploaderId,
    required String fileId,
    required ChatAttachment file,
  }) async {
    ChatAttachment.validateStreamedMetadata(
      file.name,
      file.mimeType,
      file.size,
    );
    if (file.size > swarmMaxDirectBytes) {
      throw const FormatException('File exceeds Direct limit');
    }
    final leaves = <List<int>>[];
    await for (final piece in _chunks(file)) {
      leaves.add(_leaf(leaves.length, piece));
    }
    final digest = (await sha256.bind(file.openRead()).first).toString();
    final levels = _tree(leaves);
    final m = SwarmManifest(
      groupId: groupId,
      epoch: epoch,
      uploaderId: uploaderId,
      fileId: fileId,
      name: file.name,
      mimeType: file.mimeType,
      size: file.size,
      pieceSize: swarmPieceSize,
      digest: digest,
      merkleRoot: _hex(levels.last.single),
      caption: file.caption,
    );
    final managed = attachments is BudgetedAttachmentStore
        ? attachments as BudgetedAttachmentStore
        : null;
    final reservation = 'swarm_${m.identityHash}';
    final existed = (managed?.policy.entrySize(reservation) ?? 0) > 0;
    try {
      var index = 0;
      await for (final bytes in _chunks(file)) {
        await putPiece(m, index, bytes, _proof(levels, index));
        index++;
      }
      if (index != m.pieceCount) {
        throw const FormatException('Source changed during import');
      }
      if (!(await status(m)).complete) {
        throw const FormatException('Source digest changed during import');
      }
      return m;
    } catch (_) {
      if (managed != null && !existed) {
        try {
          await managed.policy.retainCached(reservation);
        } catch (_) {}
      }
      rethrow;
    }
  }

  Stream<Uint8List> _chunks(ChatAttachment file) async* {
    var buffer = BytesBuilder(copy: false), read = 0;
    await for (final part in file.openRead()) {
      for (var start = 0; start < part.length;) {
        final take = min(swarmPieceSize - buffer.length, part.length - start);
        buffer.add(part.sublist(start, start + take));
        start += take;
        read += take;
        if (buffer.length == swarmPieceSize) {
          yield buffer.takeBytes();
          buffer = BytesBuilder(copy: false);
        }
      }
    }
    if (read != file.size) throw const FormatException('Source size changed');
    if (buffer.length > 0) yield buffer.takeBytes();
  }

  Future<void> putPiece(
    SwarmManifest m,
    int index,
    Uint8List bytes,
    List<String> proof,
  ) async {
    if (!_verify(m, index, bytes, proof)) {
      throw const FormatException('Invalid swarm piece proof');
    }
    final pageNumber = index ~/ 128, key = _pageKey(m, pageNumber);
    final managed = attachments is BudgetedAttachmentStore
        ? attachments as BudgetedAttachmentStore
        : null;
    final reservation = 'swarm_${m.identityHash}';
    Future<void> writePiece() => _serial(key, () async {
      final page = await _page(m, pageNumber);
      final fresh = !page.containsKey('$index');
      final context = sha256.convert(utf8.encode(_context(m, index))).bytes;
      final wrapped = Uint8List.fromList([...context, ...bytes]);
      final ref = await attachments.put(
        ownerId,
        ChatAttachment.fromOwnedBytes(
          name: 'piece.bin',
          mimeType: 'application/octet-stream',
          bytes: wrapped,
        ),
      );
      if (fresh && managed != null) {
        managed.policy.noteWritten(
          reservation,
          managed.policy.entryWritten(reservation) + wrapped.length,
        );
      }
      page['$index'] = {'ref': ref.toJson(), 'proof': proof};
      await blobs.saveGroupBlob(ownerId, key, jsonEncode(page));
    });
    if (managed == null) {
      await writePiece();
    } else {
      await managed.withReservation(
        reservation,
        m.size + 32 * m.pieceCount,
        writePiece,
      );
    }
  }

  Future<SwarmPiece> readPiece(SwarmManifest m, int index) async {
    m.pieceLength(index);
    final page = await _page(m, index ~/ 128), entry = page['$index'];
    if (entry is! Map<String, dynamic> ||
        entry['ref'] is! Map<String, dynamic> ||
        entry['proof'] is! List) {
      throw StateError('Piece is unavailable');
    }
    final proof = (entry['proof'] as List).cast<String>();
    final ref = AttachmentRef.fromJson(entry['ref']);
    final file = await attachments.read(ownerId, ref);
    final wrapped = file.bytes;
    final context = sha256.convert(utf8.encode(_context(m, index))).bytes;
    if (wrapped.length != 32 + m.pieceLength(index) ||
        !listEquals(wrapped.sublist(0, 32), context)) {
      throw const FormatException('Wrong swarm piece context');
    }
    final bytes = Uint8List.fromList(wrapped.sublist(32));
    if (!_verify(m, index, bytes, proof)) {
      throw const FormatException('Cached swarm piece failed proof');
    }
    return SwarmPiece(bytes, proof);
  }

  Future<SwarmCacheStatus> status(SwarmManifest m) async {
    final available = <int>{};
    var total = 0;
    for (
      var pageNumber = 0;
      pageNumber < (m.pieceCount + 127) ~/ 128;
      pageNumber++
    ) {
      final page = await _page(m, pageNumber);
      for (final key in page.keys) {
        final index = int.tryParse(key);
        if (index == null || index < 0 || index >= m.pieceCount) {
          throw const FormatException('Invalid swarm cache index');
        }
        try {
          await readPiece(m, index);
          available.add(index);
          total += m.pieceLength(index);
        } catch (_) {
          /* Corrupt cached bytes are never advertised. */
        }
      }
    }
    final all = available.length == m.pieceCount;
    if (attachments case BudgetedAttachmentStore(policy: final policy)) {
      if (available.isNotEmpty) {
        try {
          await policy.accountExisting(
            'swarm_${m.identityHash}',
            m.size + 32 * m.pieceCount,
            total + 32 * available.length,
          );
        } on CachePolicyException {
          /* Existing readable files remain available; new cache writes still require budget approval. */
        }
      }
    }
    if (all) {
      final digest = await sha256.bind(_openRead(m)).first;
      if (digest.toString() != m.digest) {
        return SwarmCacheStatus(total, false, available);
      }
    }
    return SwarmCacheStatus(total, all, available);
  }

  Stream<List<int>> _openRead(
    SwarmManifest m, {
    int start = 0,
    int? end,
  }) async* {
    final last = end ?? m.size;
    if (start < 0 || last < start || last > m.size) {
      throw RangeError.range(last, start, m.size);
    }
    if (start == last) return;
    final first = start ~/ swarmPieceSize,
        finalIndex = (last - 1) ~/ swarmPieceSize;
    for (var i = first; i <= finalIndex; i++) {
      final piece = await readPiece(m, i);
      final lo = i == first ? start - i * swarmPieceSize : 0;
      final hi = i == finalIndex
          ? last - i * swarmPieceSize
          : piece.bytes.length;
      yield piece.bytes.sublist(lo, hi);
    }
  }

  Future<ChatAttachment> open(SwarmManifest m) async {
    if (!(await status(m)).complete) {
      throw StateError('Swarm file is incomplete or damaged');
    }
    return ChatAttachment.fromSource(
      name: m.name,
      mimeType: m.mimeType,
      source: _SwarmSource(this, m),
      caption: m.caption,
    );
  }
}

class _SwarmSource implements AttachmentSource {
  _SwarmSource(this.cache, this.manifest);
  final SparseSwarmCache cache;
  final SwarmManifest manifest;
  @override
  int get length => manifest.size;
  @override
  String get key => 'swarm:${cache.ownerId}:${manifest.identityHash}';
  @override
  Stream<List<int>> openRead({int start = 0, int? end}) =>
      cache._openRead(manifest, start: start, end: end);
}

class SwarmProgress {
  const SwarmProgress({
    required this.verifiedBytes,
    required this.totalBytes,
    required this.sourceCount,
    required this.complete,
    required this.waitingForDirect,
  });
  final int verifiedBytes, totalBytes, sourceCount;
  final bool complete, waitingForDirect;
}

class _Assembly {
  _Assembly(this.peer, this.index, this.started, this.partCount);
  final String peer;
  final int index, partCount;
  final DateTime started;
  final parts = <int, Uint8List>{};
  List<String>? proof;
}

/// Packets travel only inside the authenticated group content channel.
class SwarmTransfer extends ChangeNotifier {
  SwarmTransfer(
    this.ownerId, {
    required this.cache,
    required this.authorize,
    required this.peers,
    required this.isDirect,
    required this.send,
    required this.onComplete,
  });
  final String ownerId;
  final SparseSwarmCache cache;
  final FutureOr<bool> Function(String, SwarmManifest) authorize;
  final List<String> Function(SwarmManifest) peers;
  final bool Function(String) isDirect;
  final Future<void> Function(String, String) send;
  final void Function(SwarmManifest) onComplete;
  final _manifests = <String, SwarmManifest>{};
  final _availability = <String, Map<String, Set<int>>>{};
  final _assemblies = <String, Map<int, _Assembly>>{};
  final _penalties = <String, int>{};
  final _progress = <String, SwarmProgress>{};
  final _completed = <String>{};
  bool _closed = false;

  /// The caller must validate the enclosing group event signature before registration.
  void register(SwarmManifest manifest) {
    if (_closed) throw StateError('Swarm transfer is closed');
    final existing = _manifests[manifest.fileId];
    if (existing != null && existing.identityHash != manifest.identityHash) {
      throw const FormatException('Conflicting swarm file id');
    }
    _manifests[manifest.fileId] = manifest;
    _progress[manifest.fileId] = SwarmProgress(
      verifiedBytes: 0,
      totalBytes: manifest.size,
      sourceCount: 0,
      complete: false,
      waitingForDirect: false,
    );
    notifyListeners();
  }

  SwarmProgress? progressFor(String fileId) => _progress[fileId];
  Future<void> _emit(String peer, Map<String, Object?> packet) async {
    final frame = 'chta-swarm-v1:${jsonEncode(packet)}';
    if (utf8.encode(frame).length > swarmMaxFrameBytes) {
      throw const FormatException('Swarm frame too large');
    }
    await send(peer, frame);
  }

  Map<String, Object?> _base(SwarmManifest m, String kind) => {
    'kind': kind,
    'fileId': m.fileId,
    'manifest': m.identityHash,
  };
  Set<int> _decodeAvailability(String bits, int count) {
    final bytes = base64Url.decode(base64Url.normalize(bits));
    if (bytes.length != (count + 7) ~/ 8) {
      throw const FormatException('Invalid swarm availability');
    }
    final out = <int>{};
    for (var i = 0; i < count; i++) {
      if ((bytes[i ~/ 8] & (1 << (i % 8))) != 0) out.add(i);
    }
    if (count % 8 != 0 && bytes.isNotEmpty && bytes.last >> (count % 8) != 0) {
      throw const FormatException('Invalid swarm availability');
    }
    return out;
  }

  String _encodeAvailability(Set<int> available, int count) {
    final bytes = Uint8List((count + 7) ~/ 8);
    for (final i in available) {
      if (i >= 0 && i < count) bytes[i ~/ 8] |= 1 << (i % 8);
    }
    return base64UrlEncode(bytes);
  }

  Future<void> receive(String peer, String source) async {
    if (_closed) return;
    if (utf8.encode(source).length > swarmMaxFrameBytes ||
        !source.startsWith('chta-swarm-v1:')) {
      throw const FormatException('Invalid swarm frame');
    }
    final packet = jsonDecode(source.substring(14));
    if (packet is! Map<String, dynamic> ||
        packet['fileId'] is! String ||
        packet['manifest'] is! String ||
        packet['kind'] is! String) {
      throw const FormatException('Invalid swarm packet');
    }
    final m = _manifests[packet['fileId']];
    if (m == null || m.identityHash != packet['manifest']) {
      throw const FormatException('Unregistered swarm manifest');
    }
    if (!await authorize(peer, m)) {
      throw const FormatException('Unauthorized swarm peer');
    }
    final kind = packet['kind'];
    if (kind == 'have') {
      if (packet.keys.toSet().difference({
            'kind',
            'fileId',
            'manifest',
            'bits',
          }).isNotEmpty ||
          packet['bits'] is! String) {
        throw const FormatException('Invalid availability frame');
      }
      _availability.putIfAbsent(m.fileId, () => {})[peer] = _decodeAvailability(
        packet['bits'],
        m.pieceCount,
      );
      notifyListeners();
      return;
    }
    final index = packet['index'];
    if (index is! int || index < 0 || index >= m.pieceCount) {
      throw const FormatException('Invalid swarm piece index');
    }
    if (kind == 'request') {
      if (packet.keys.toSet().difference({
        'kind',
        'fileId',
        'manifest',
        'index',
      }).isNotEmpty) {
        throw const FormatException('Invalid request frame');
      }
      // Authorization is checked again after disk awaits, immediately before each send.
      final piece = await cache.readPiece(m, index);
      final parts = (piece.bytes.length + swarmPartSize - 1) ~/ swarmPartSize;
      if (parts < 1 || parts > 32) {
        throw const FormatException('Invalid swarm part count');
      }
      for (var p = 0; p < parts; p++) {
        if (_closed || !await authorize(peer, m)) return;
        final start = p * swarmPartSize;
        await _emit(peer, {
          ..._base(m, 'part'),
          'index': index,
          'part': p,
          'count': parts,
          'bytes': base64UrlEncode(
            piece.bytes.sublist(
              start,
              min(start + swarmPartSize, piece.bytes.length),
            ),
          ),
          if (p == 0) 'proof': piece.proof,
        });
      }
      return;
    }
    if (kind != 'part') {
      throw const FormatException('Invalid swarm packet kind');
    }
    final part = packet['part'],
        count = packet['count'],
        encoded = packet['bytes'];
    if (part is! int ||
        count is! int ||
        encoded is! String ||
        part < 0 ||
        count < 1 ||
        count > 32 ||
        part >= count ||
        encoded.length > 11000 ||
        packet.keys.toSet().difference({
          'kind',
          'fileId',
          'manifest',
          'index',
          'part',
          'count',
          'bytes',
          'proof',
        }).isNotEmpty) {
      throw const FormatException('Invalid swarm part');
    }
    final expectedCount =
        (m.pieceLength(index) + swarmPartSize - 1) ~/ swarmPartSize;
    if (count != expectedCount) {
      throw const FormatException('Wrong swarm part count');
    }
    final bytes = base64Url.decode(base64Url.normalize(encoded));
    final expectedLength = min(
      swarmPartSize,
      m.pieceLength(index) - part * swarmPartSize,
    );
    if (bytes.length != expectedLength) {
      throw const FormatException('Wrong swarm part length');
    }
    final pending = _assemblies[m.fileId]?[index];
    if (pending == null || pending.peer != peer || pending.partCount != count) {
      return;
    }
    if (part == 0) {
      final proof = packet['proof'];
      if (proof is! List ||
          proof.length != _depth(m.pieceCount) ||
          proof.any((x) => x is! String || !_digestPattern.hasMatch(x))) {
        throw const FormatException('Invalid swarm proof');
      }
      pending.proof = proof.cast<String>();
    } else if (packet.containsKey('proof')) {
      throw const FormatException('Unexpected swarm proof');
    }
    if (pending.parts.containsKey(part)) return;
    pending.parts[part] = bytes;
    if (pending.parts.length != count || pending.proof == null) return;
    _assemblies[m.fileId]!.remove(index);
    final assembled = BytesBuilder(copy: false);
    for (var i = 0; i < count; i++) {
      assembled.add(pending.parts[i]!);
    }
    if (!await authorize(peer, m)) return;
    try {
      await cache.putPiece(m, index, assembled.takeBytes(), pending.proof!);
    } on FormatException {
      _penalties[peer] = (_penalties[peer] ?? 0) + 1;
      return;
    }
    final status = await cache.status(m);
    _setProgress(m, status);
  }

  void _setProgress(SwarmManifest m, SwarmCacheStatus status) {
    final sources = (_availability[m.fileId] ?? {}).keys
        .where((p) => peers(m).contains(p))
        .length;
    final waiting =
        m.size > swarmMaxRelayBytes &&
        !status.complete &&
        !(_availability[m.fileId] ?? {}).keys.any(
          (p) => isDirect(p) && peers(m).contains(p),
        );
    _progress[m.fileId] = SwarmProgress(
      verifiedBytes: status.verifiedBytes,
      totalBytes: m.size,
      sourceCount: sources,
      complete: status.complete,
      waitingForDirect: waiting,
    );
    if (status.complete && _completed.add(m.fileId)) onComplete(m);
    notifyListeners();
  }

  Future<void> tick() async {
    if (_closed) return;
    for (final m in _manifests.values) {
      final status = await cache.status(m);
      _setProgress(m, status);
      final online = peers(m).where((p) => p != ownerId).take(64).toList();
      for (final peer in online) {
        if (!await authorize(peer, m)) continue;
        await _emit(peer, {
          ..._base(m, 'have'),
          'bits': _encodeAvailability(status.available, m.pieceCount),
        });
      }
      if (status.complete) continue;
      final pending = _assemblies.putIfAbsent(m.fileId, () => {});
      final now = DateTime.now();
      pending.removeWhere(
        (_, a) => now.difference(a.started) > const Duration(seconds: 15),
      );
      final candidates = <({int count, int index})>[];
      for (var i = 0; i < m.pieceCount; i++) {
        if (status.available.contains(i) || pending.containsKey(i)) continue;
        final count = online
            .where(
              (p) =>
                  (_availability[m.fileId]?[p] ?? {}).contains(i) &&
                  (m.size <= swarmMaxRelayBytes || isDirect(p)) &&
                  (_penalties[p] ?? 0) < 3,
            )
            .length;
        if (count > 0) candidates.add((count: count, index: i));
      }
      candidates.sort((a, b) {
        final x = a.count.compareTo(b.count);
        return x != 0 ? x : a.index.compareTo(b.index);
      });
      for (final item in candidates) {
        if (pending.length >= 8) break;
        final sourcePeers = online
            .where(
              (p) =>
                  (_availability[m.fileId]?[p] ?? {}).contains(item.index) &&
                  (m.size <= swarmMaxRelayBytes || isDirect(p)) &&
                  (_penalties[p] ?? 0) < 3 &&
                  pending.values.where((a) => a.peer == p).length < 2,
            )
            .toList();
        if (sourcePeers.isEmpty) continue;
        final active = pending.values.map((a) => a.peer).toSet();
        final peer = sourcePeers.firstWhere(
          (p) => active.contains(p) || active.length < 4,
          orElse: () => '',
        );
        if (peer.isEmpty || !await authorize(peer, m)) continue;
        pending[item.index] = _Assembly(
          peer,
          item.index,
          now,
          (m.pieceLength(item.index) + swarmPartSize - 1) ~/ swarmPartSize,
        );
        await _emit(peer, {..._base(m, 'request'), 'index': item.index});
      }
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _assemblies.clear();
    _availability.clear();
    super.dispose();
  }
}
