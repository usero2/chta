import 'dart:typed_data';

import 'package:cht/chat/attachment_export.dart';
import 'package:cht/chat/attachment_source.dart';
import 'package:cht/chat/chat_attachment.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('export filename removes Windows streams and reserved device names', () {
    expect(safeAttachmentExportName('photo.jpg:secret'), 'photo.jpg_secret');
    expect(safeAttachmentExportName('CON.txt'), '_CON.txt');
    expect(safeAttachmentExportName('report. '), 'report');
    expect(safeAttachmentExportName('../outside'), '.._outside');
  });
  test(
    'stream export writes bounded chunks and verifies exact length',
    () async {
      final writes = <int>[];
      final file = ChatAttachment.fromSource(
        name: 'large.bin',
        mimeType: 'application/octet-stream',
        source: _Source(2 * 1024 * 1024 + 3),
      );
      await writeAttachmentToSink(file, (chunk) async {
        writes.add(chunk.length);
      });
      expect(writes.every((size) => size <= 256 * 1024), isTrue);
      expect(writes.reduce((a, b) => a + b), file.size);
    },
  );

  test('stream export rejects a truncated source', () async {
    final file = ChatAttachment.fromSource(
      name: 'broken.bin',
      mimeType: 'application/octet-stream',
      source: _Source(10, actual: 9),
    );
    await expectLater(
      writeAttachmentToSink(file, (_) async {}),
      throwsFormatException,
    );
  });
  test('legacy peers can receive a bounded streamed five MiB file', () async {
    final file = ChatAttachment.fromSource(
      name: 'old-peer.bin',
      mimeType: 'application/octet-stream',
      source: _Source(5 * 1024 * 1024),
    );
    final materialized = await materializeLegacyAttachment(
      file,
      maxBytes: 25 * 1024 * 1024,
    );
    expect(materialized.isStreamed, isFalse);
    expect(materialized.bytes.length, 5 * 1024 * 1024);
    await expectLater(
      materializeLegacyAttachment(file, maxBytes: 1024),
      throwsFormatException,
    );
  });
}

class _Source implements AttachmentSource {
  _Source(this.length, {this.actual});
  @override
  final int length;
  final int? actual;
  @override
  String get key => 'export-test';
  @override
  Stream<List<int>> openRead({int start = 0, int? end}) async* {
    var remaining = actual ?? length;
    while (remaining > 0) {
      final count = remaining.clamp(0, 1024 * 1024);
      yield Uint8List(count);
      remaining -= count;
    }
  }
}
