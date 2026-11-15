import 'dart:typed_data';

import 'package:cht/chat/chat_attachment.dart';
import 'package:cht/chat/media_batch.dart';
import 'package:flutter_test/flutter_test.dart';

ChatAttachment media(String name, String mime) =>
    ChatAttachment(name: name, mimeType: mime, bytes: Uint8List(1));
void main() {
  test(
    'mixed selection has one caption, separate ordered image/video groups',
    () {
      final files = [
        media('a.mp3', 'audio/mpeg'),
        media('v.mp4', 'video/mp4'),
        media('a.png', 'image/png'),
        media('b.png', 'image/png'),
        media('b.mp4', 'video/mp4'),
      ];
      final batch = prepareMediaBatch('**caption**', files, 'batch');
      expect(batch.files.map((f) => f.name), [
        'a.png',
        'b.png',
        'v.mp4',
        'b.mp4',
        'a.mp3',
      ]);
      expect(batch.files.where((f) => f.caption != null).length, 1);
      expect(batch.files.first.caption, '**caption**');
      expect(batch.files.take(2).map((f) => f.groupIndex), [0, 1]);
      expect(batch.files.first.groupId, isNot(batch.files[2].groupId));
      expect(batch.files.last.groupId, isNull);
      expect(
        prepareMediaBatch('x', [files.first], 'audio').files.single.caption,
        'x',
      );
      expect(
        () => prepareMediaBatch('', List.filled(6, files.first), 'big'),
        throwsFormatException,
      );
    },
  );
}
