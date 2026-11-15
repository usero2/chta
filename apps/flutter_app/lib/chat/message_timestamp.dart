String formatMessageTimestamp(int? milliseconds) {
  if (milliseconds == null || milliseconds.abs() > 8640000000000000) return '—';
  final date = DateTime.fromMillisecondsSinceEpoch(milliseconds);
  if (date.year < 1 || date.year > 9999) return '—';
  String pad(int value, int width) => value.toString().padLeft(width, '0');
  return '${pad(date.year, 4)}-${pad(date.month, 2)}-${pad(date.day, 2)} '
      '${pad(date.hour, 2)}:${pad(date.minute, 2)}:${pad(date.second, 2)}.${pad(date.millisecond, 3)}';
}

/// Formats a local message time for display next to a bubble.
String formatCompactMessageTimestamp(
  int? milliseconds, {
  DateTime? now,
  int? sameDateAs,
}) {
  final full = formatMessageTimestamp(milliseconds);
  if (full == '—') return full;
  final date = DateTime.fromMillisecondsSinceEpoch(milliseconds!);
  bool sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
  final otherFull = formatMessageTimestamp(sameDateAs);
  final duplicateDate =
      otherFull != '—' &&
      sameDay(date, DateTime.fromMillisecondsSinceEpoch(sameDateAs!));
  return sameDay(date, now ?? DateTime.now()) || duplicateDate
      ? full.substring(11)
      : full;
}
