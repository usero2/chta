DateTime? messageDateTime(int? milliseconds) {
  if (milliseconds == null || milliseconds.abs() > 8640000000000000) {
    return null;
  }
  final date = DateTime.fromMillisecondsSinceEpoch(milliseconds);
  return date.year < 1 || date.year > 9999 ? null : date;
}

String _pad(int value, [int width = 2]) => value.toString().padLeft(width, '0');
String _clockTime(DateTime date) => '${_pad(date.hour)}:${_pad(date.minute)}';

String formatMessageTimestamp(int? milliseconds) {
  final date = messageDateTime(milliseconds);
  if (date == null) return '—';
  return '${_pad(date.year, 4)}-${_pad(date.month)}-${_pad(date.day)} '
      '${_clockTime(date)}:${_pad(date.second)}.${_pad(date.millisecond, 3)}';
}

String? formatCompactMessageTimestamp(int? milliseconds) {
  final date = messageDateTime(milliseconds);
  return date == null ? null : _clockTime(date);
}

DateTime? visibleMessageTime(int? sent, int? received) =>
    messageDateTime(sent) ?? messageDateTime(received);

typedef MessageTimelineMarker = ({String? dayLabel, bool showTime});

List<MessageTimelineMarker> messageTimeline<T>(
  List<T> messages, {
  required DateTime? Function(T) timeOf,
  required Object Function(T) authorOf,
  DateTime? now,
}) {
  final times = messages.map(timeOf).toList();
  final today = now ?? DateTime.now();
  final yesterday = DateTime(today.year, today.month, today.day - 1);
  DateTime? previous;
  final markers = <MessageTimelineMarker>[];
  for (var index = 0; index < messages.length; index++) {
    final time = times[index];
    final next = index + 1 < times.length ? times[index + 1] : null;
    final startsDay =
        time != null && (previous == null || !_sameDay(previous, time));
    final continuesMinute =
        time != null &&
        next != null &&
        _sameDay(time, next) &&
        time.hour == next.hour &&
        time.minute == next.minute &&
        time.timeZoneOffset == next.timeZoneOffset &&
        authorOf(messages[index]) == authorOf(messages[index + 1]);
    markers.add((
      dayLabel: startsDay ? _dayLabel(time, today, yesterday) : null,
      showTime: time != null && !continuesMinute,
    ));
    if (time != null) previous = time;
  }
  return markers;
}

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

String _dayLabel(DateTime date, DateTime today, DateTime yesterday) {
  if (_sameDay(date, today)) return 'Today';
  if (_sameDay(date, yesterday)) return 'Yesterday';
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${months[date.month - 1]} ${date.day}, ${date.year}';
}
