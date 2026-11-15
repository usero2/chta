import 'dart:typed_data';

import 'package:cht/chat/attachment_ref.dart';
import 'package:cht/chat/attachment_source.dart';
import 'package:cht/chat/chat_attachment.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'source over 100 MiB retains bounded range access without byte loading',
    () async {
      final source = _SyntheticSource(101 * 1024 * 1024);
      final file = ChatAttachment.fromSource(
        name: 'large.bin',
        mimeType: 'application/octet-stream',
        source: source,
      );
      expect(file.size, source.length);
      expect(file.isStreamed, isTrue);
      expect(file.source, same(source));
      expect(() => file.bytes, throwsStateError);
      expect(
        await file.openRead(start: source.length - 3).expand((v) => v).toList(),
        [7, 7, 7],
      );
      expect(source.reads, [(source.length - 3, source.length)]);
      expect(file.withPresentation(caption: 'large').source, same(source));
      expect(() => file.toJson(), throwsStateError);
    },
  );

  test('chunked refs round trip only with complete bounded metadata', () {
    final ref = AttachmentRef(
      name: 'large.bin',
      mimeType: 'application/octet-stream',
      size: 101 * 1024 * 1024,
      digest: 'a' * 64,
      chunkedId: 'abcdefghijklmnop',
      chunkSize: 262144,
    );
    expect(ref.isChunked, isTrue);
    expect(AttachmentRef.fromJson(ref.toJson()).chunkedId, ref.chunkedId);
    expect(
      () => AttachmentRef(
        name: ref.name,
        mimeType: ref.mimeType,
        size: ref.size,
        digest: ref.digest,
      ),
      throwsFormatException,
    );
    expect(
      () => AttachmentRef.fromJson({...ref.toJson(), 'chunkSize': null}),
      throwsFormatException,
    );
    expect(
      () => AttachmentRef.fromJson({...ref.toJson(), 'chunkSize': 'bad'}),
      throwsFormatException,
    );
  });

  test('legacy bytes and JSON retain 100 MiB limit', () {
    final file = ChatAttachment(
      name: 'small.txt',
      mimeType: 'text/plain',
      bytes: Uint8List.fromList([1, 2]),
    );
    expect(file.size, 2);
    expect(file.isStreamed, isFalse);
    expect(ChatAttachment.fromJson(file.toJson()).bytes, [1, 2]);
    expect(
      () => ChatAttachment(
        name: 'large.bin',
        mimeType: 'application/octet-stream',
        bytes: Uint8List(101 * 1024 * 1024),
      ),
      throwsFormatException,
    );
  });
}

class _SyntheticSource implements AttachmentSource {
  _SyntheticSource(this.length);
  @override
  final int length;
  @override
  String get key => 'synthetic';
  final reads = <(int, int)>[];
  @override
  Stream<List<int>> openRead({int start = 0, int? end}) {
    final last = end ?? length;
    reads.add((start, last));
    return Stream.value(List<int>.filled(last - start, 7));
  }
}
