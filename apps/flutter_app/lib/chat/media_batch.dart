import 'chat_attachment.dart';

class PreparedMediaBatch {
  PreparedMediaBatch(List<ChatAttachment> files)
    : files = List.unmodifiable(files);
  final List<ChatAttachment> files;
}

PreparedMediaBatch prepareMediaBatch(
  String text,
  List<ChatAttachment> files,
  String batchId,
) {
  if (files.isEmpty ||
      files.length > 5 ||
      files.where((f) => !f.isStreamed).fold<int>(0, (sum, f) => sum + f.size) >
          ChatAttachment.maxBytes ||
      !RegExp(r'^[A-Za-z0-9_-]{1,56}$').hasMatch(batchId)) {
    throw const FormatException('Choose up to 5 files, 100 MB total.');
  }
  final ordered = [
    ...files.where((f) => f.kind == 'image'),
    ...files.where((f) => f.kind == 'video'),
    ...files.where((f) => f.kind != 'image' && f.kind != 'video'),
  ];
  final indices = <String, int>{};
  return PreparedMediaBatch([
    for (var i = 0; i < ordered.length; i++)
      ordered[i].withPresentation(
        caption: i == 0 && text.trim().isNotEmpty ? text : null,
        groupId: ['image', 'video'].contains(ordered[i].kind)
            ? '${batchId}_${ordered[i].kind}'
            : null,
        groupIndex: ['image', 'video'].contains(ordered[i].kind)
            ? (indices.update(ordered[i].kind, (n) => n + 1, ifAbsent: () => 0))
            : null,
        groupCount: ['image', 'video'].contains(ordered[i].kind)
            ? ordered.where((f) => f.kind == ordered[i].kind).length
            : null,
      ),
  ]);
}
