import 'dart:typed_data';

import 'package:cht/chat/attachment_files.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('picked source reads a bounded range across chunks', () async {
    var opens = 0;
    final source = PickedAttachmentSource(
      length: 8,
      key: 'picked',
      read: () {
        opens++;
        return Stream.fromIterable([
          Uint8List.fromList([0, 1, 2, 3]),
          Uint8List.fromList([4, 5, 6, 7]),
        ]);
      },
    );
    expect(await source.openRead(start: 2, end: 6).expand((v) => v).toList(), [
      2,
      3,
      4,
      5,
    ]);
    expect(opens, 1);
  });

  test('picked source rejects shrinking content', () async {
    final source = PickedAttachmentSource(
      length: 5,
      key: 'picked',
      read: () => Stream.value(Uint8List.fromList([1, 2, 3])),
    );
    await expectLater(source.openRead().toList(), throwsFormatException);
  });
}
