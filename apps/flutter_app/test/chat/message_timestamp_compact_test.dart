import 'package:cht/chat/message_timestamp.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('compact timestamps omit today and duplicate dates', () {
    final now = DateTime(2026, 1, 3, 12);
    final today = DateTime(2026, 1, 3, 3, 4, 5, 6).millisecondsSinceEpoch;
    final old = DateTime(2026, 1, 2, 3, 4, 5, 6).millisecondsSinceEpoch;
    expect(formatCompactMessageTimestamp(today, now: now), '03:04:05.006');
    expect(
      formatCompactMessageTimestamp(old, now: now),
      '2026-01-02 03:04:05.006',
    );
    expect(
      formatCompactMessageTimestamp(old, now: now, sameDateAs: old),
      '03:04:05.006',
    );
    expect(formatCompactMessageTimestamp(null, now: now), '—');
  });
}
