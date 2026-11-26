import 'package:cht/chat/message_timestamp.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('compact timestamps show only hours and minutes', () {
    final old = DateTime(2026, 1, 2, 3, 4, 5, 6).millisecondsSinceEpoch;
    expect(formatCompactMessageTimestamp(old), '03:04');
    expect(formatCompactMessageTimestamp(null), isNull);
    expect(formatCompactMessageTimestamp(9000000000000000), isNull);
  });

  test('timeline uses local dates and ends each contiguous author minute with one time', () {
    final now = DateTime(2026, 1, 3, 8);
    final markers = messageTimeline(
      [
        ('alice', DateTime(2025, 12, 31, 23, 59)),
        ('alice', DateTime(2026, 1, 2, 23, 59, 5)),
        ('alice', DateTime(2026, 1, 2, 23, 59, 6)),
        ('alice', DateTime(2026, 1, 3, 0, 0, 5)),
        ('bob', DateTime(2026, 1, 3, 0, 0, 10)),
        ('alice', DateTime(2026, 1, 3, 0, 0, 40)),
        ('alice', null),
        ('alice', DateTime(2026, 1, 3, 0, 1, 5)),
      ],
      authorOf: (row) => row.$1,
      timeOf: (row) => row.$2,
      now: now,
    );
    expect(markers.map((m) => m.showTime), [
      true,
      false,
      true,
      true,
      true,
      true,
      false,
      true,
    ]);
    // ascii source input is retained across Windows PowerShell here-strings.
    expect(markers.map((m) => m.dayLabel), [
      '31 \u0e18.\u0e04. 2025',
      '\u0e40\u0e21\u0e37\u0e48\u0e2d\u0e27\u0e32\u0e19',
      null,
      '\u0e27\u0e31\u0e19\u0e19\u0e35\u0e49',
      null,
      null,
      null,
      null,
    ]);
  });
}
