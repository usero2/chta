import 'package:cht/chat/message_timestamp.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'message timestamps include padded local date time and milliseconds',
    () {
      final time = DateTime(2026, 1, 2, 3, 4, 5, 6);
      expect(
        formatMessageTimestamp(time.millisecondsSinceEpoch),
        '2026-01-02 03:04:05.006',
      );
      expect(formatMessageTimestamp(null), '—');
      expect(formatMessageTimestamp(9000000000000000), '—');
    },
  );
}
