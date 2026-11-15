import 'dart:typed_data';

import 'chat_attachment.dart';

class MediaItem {
  const MediaItem({
    required this.id,
    required this.name,
    required this.kind,
    required this.incoming,
    required this.loadFile,
    this.caption,
    this.groupId,
    this.groupIndex,
    this.groupCount,
    this.loadThumbnail,
    this.onRetry,
  });
  final String id, name, kind;
  final bool incoming;
  final String? caption, groupId;
  final int? groupIndex, groupCount;
  final Future<ChatAttachment> Function() loadFile;
  final Future<Uint8List?> Function()? loadThumbnail;
  final void Function()? onRetry;
  String? get groupKey =>
      groupId != null && (kind == 'image' || kind == 'video')
      ? '$incoming:$kind:$groupId'
      : null;
}

List<List<T>> groupMedia<T>(List<T> messages, String? Function(T) groupKey) {
  final groups = <List<T>>[];
  final known = <String, List<T>>{};
  for (final message in messages) {
    final key = groupKey(message);
    if (key == null) {
      groups.add([message]);
      continue;
    }
    final group = known[key];
    if (group == null) {
      final created = [message];
      known[key] = created;
      groups.add(created);
    } else {
      group.add(message);
    }
  }
  return groups;
}
