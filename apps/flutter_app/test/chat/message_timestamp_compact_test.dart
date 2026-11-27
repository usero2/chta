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
      'Dec 31, 2025',
      'Yesterday',
      null,
      'Today',
      null,
      null,
      null,
      null,
    ]);
  });
}
