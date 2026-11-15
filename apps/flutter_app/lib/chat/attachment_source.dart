/// Reopenable, range-readable attachment content. [end] is exclusive.
abstract interface class AttachmentSource {
  int get length;
  String get key;
  Stream<List<int>> openRead({int start = 0, int? end});
}
