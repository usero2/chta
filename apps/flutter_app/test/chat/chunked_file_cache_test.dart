import 'dart:typed_data';

import 'package:cht/chat/chunked_attachment_bridge.dart';
import 'package:cht/chat/chunked_file_cache.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('bridge factory only exposes supplied capabilities and state JSON is strict', () {
    final bridge = _MemoryBridge();
    expect(createChunkedAttachmentBridge(bridge: bridge), same(bridge));
    expect(createChunkedAttachmentBridge(bridge: Object()), isNull);

    final state = ChunkedAttachmentState(
      id: 'attachment_12345678',
      size: 3,
      chunkSize: 2,
      contiguousChunks: 2,
      completed: true,
      digest: sha256.convert([1, 2, 3]).toString(),
    );
    expect(
      ChunkedAttachmentState.fromJson(state.toJson()).toJson(),
      state.toJson(),
    );
    expect(
      ChunkedAttachmentState.fromJson({...state.toJson(), 'version': 2})
          .toJson(),
      state.toJson(),
    );
    expect(
      () => ChunkedAttachmentState.fromJson({
        ...state.toJson(),
        'path': 'cache.bin',
      }),
      throwsFormatException,
    );
    expect(
      () => ChunkedAttachmentState.fromJson({...state.toJson(), 'size': '3'}),
      throwsFormatException,
    );
  });

  test('imports bounded chunks and returns the verified digest', () async {
    final source = Uint8List.fromList(List<int>.generate(31, (i) => i));
    final bridge = _MemoryBridge();
    final cache = ChunkedFileCache(bridge);

    final state = await cache.importStream(
      'owner',
      'attachment_12345678',
      source.length,
      Stream<List<int>>.fromIterable([
        source.sublist(0, 7),
        source.sublist(7, 22),
        source.sublist(22),
      ]),
      chunkSize: 8,
    );

    expect(bridge.writes.map((bytes) => bytes.length), [8, 8, 8, 7]);
    expect(state.completed, isTrue);
    expect(state.contiguousChunks, 4);
    expect(state.digest, sha256.convert(source).toString());
  });

  test('rejects underflow and overflow without finishing the cache', () async {
    final bridge = _MemoryBridge();
    final cache = ChunkedFileCache(bridge);
    await expectLater(
      cache.importStream(
        'owner',
        'attachment_12345678',
        5,
        Stream<List<int>>.value([1, 2, 3]),
        chunkSize: 4,
      ),
      throwsFormatException,
    );
    expect(bridge.finishCalls, 0);

    await expectLater(
      cache.importStream(
        'owner',
        'attachment_abcdefgh',
        2,
        Stream<List<int>>.value([1, 2, 3]),
        chunkSize: 4,
      ),
      throwsFormatException,
    );
    expect(bridge.finishCalls, 0);
  });

  test('openRead streams completed cache ranges with end exclusive', () async {
    final source = Uint8List.fromList(List<int>.generate(19, (i) => i));
    final bridge = _MemoryBridge();
    final cache = ChunkedFileCache(bridge);
    await cache.importStream(
      'owner',
      'attachment_12345678',
      source.length,
      Stream<List<int>>.value(source),
      chunkSize: 6,
    );

    expect(
      await cache
          .openRead('owner', 'attachment_12345678', start: 4, end: 16)
          .expand((b) => b)
          .toList(),
      source.sublist(4, 16),
    );
    expect(
      await cache
          .openRead('owner', 'attachment_12345678', start: 9)
          .expand((b) => b)
          .toList(),
      source.sublist(9),
    );
  });

  test('rejects invalid IDs, chunk sizes, and ranges', () async {
    final bridge = _MemoryBridge();
    final cache = ChunkedFileCache(bridge);
    await expectLater(
      cache.importStream('owner', 'bad/id_1234567', 1, Stream.value([1])),
      throwsArgumentError,
    );
    await expectLater(
      cache.importStream(
        'owner',
        'attachment_12345678',
        1,
        Stream.value([1]),
        chunkSize: 1048577,
      ),
      throwsArgumentError,
    );
    await cache.importStream(
      'owner',
      'attachment_12345678',
      1,
      Stream.value([1]),
    );
    await expectLater(
      cache.openRead('owner', 'attachment_12345678', start: 2),
      emitsError(isA<RangeError>()),
    );
  });
}

class _MemoryBridge implements ChunkedAttachmentBridge {
  final Map<String, List<Uint8List>> _chunks = {};
  final Map<String, ChunkedAttachmentState> _states = {};
  final List<Uint8List> writes = [];
  int finishCalls = 0;

  String _key(String owner, String id) => '$owner:$id';

  @override
  Future<ChunkedAttachmentState> beginChunkedAttachment(
    String ownerId,
    String id,
    int size,
    int chunkSize, {
    String? digest,
  }) async {
    final key = _key(ownerId, id);
    _chunks[key] = [];
    return _states[key] = ChunkedAttachmentState(
      id: id,
      size: size,
      chunkSize: chunkSize,
      contiguousChunks: 0,
      completed: false,
      digest: digest,
    );
  }

  @override
  Future<ChunkedAttachmentState> chunkedAttachmentStatus(
    String ownerId,
    String id,
  ) async => _states[_key(ownerId, id)]!;

  @override
  Future<void> writeChunkedAttachment(
    String ownerId,
    String id,
    int index,
    Uint8List bytes,
  ) async {
    final copy = Uint8List.fromList(bytes);
    writes.add(copy);
    _chunks[_key(ownerId, id)]!.add(copy);
  }

  @override
  Future<Uint8List> readChunkedAttachment(
    String ownerId,
    String id,
    int index,
  ) async => _chunks[_key(ownerId, id)]![index];

  @override
  Future<ChunkedAttachmentState> finishChunkedAttachment(
    String ownerId,
    String id, {
    String? expectedDigest,
  }) async {
    finishCalls++;
    final key = _key(ownerId, id);
    final old = _states[key]!;
    return _states[key] = ChunkedAttachmentState(
      id: id,
      size: old.size,
      chunkSize: old.chunkSize,
      contiguousChunks: _chunks[key]!.length,
      completed: true,
      digest: expectedDigest,
    );
  }

  @override
  Future<void> deleteChunkedAttachment(String ownerId, String id) async {
    final key = _key(ownerId, id);
    _chunks.remove(key);
    _states.remove(key);
  }
}
