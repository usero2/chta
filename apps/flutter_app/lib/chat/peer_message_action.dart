import 'dart:convert';

import 'link_preview.dart';

enum PeerMessageActionKind { reply, edit, delete }

/// An authenticated text event, so the same action survives every route,
/// offline delivery, gap repair and device synchronization.
class PeerMessageAction {
  const PeerMessageAction(this.kind, this.target, this.text);

  static const idPrefix = 'chtmsg1_';
  static const capability = 'message-actions-v1';
  final PeerMessageActionKind kind;
  final String target;
  final String? text;

  bool get createsMessage => kind == PeerMessageActionKind.reply;

  String encode() => jsonEncode({
    'kind': kind.name,
    'target': target,
    if (text != null) 'text': text,
  });

  static PeerMessageAction? decode(String id, String source) {
    if (!id.startsWith(idPrefix)) return null;
    try {
      final data = jsonDecode(source);
      if (data is! Map<String, dynamic>) return null;
      final kind = PeerMessageActionKind.values.byName(data['kind'] as String);
      final target = data['target'] as String;
      final text = data['text'] as String?;
      if (target.isEmpty || target == id || target.length > 128) return null;
      if (kind == PeerMessageActionKind.delete
          ? text != null
          : text == null || text.trim().isEmpty) {
        return null;
      }
      return PeerMessageAction(kind, target, text);
    } catch (_) {
      return null;
    }
  }
}

typedef MessagePresentation = ({
  String text,
  LinkPreview? preview,
  bool edited,
  bool deleted,
  bool pending,
});
typedef MessageActionEntry = ({
  String id,
  String key,
  String author,
  String text,
  bool visible,
  bool hasAttachment,
  bool pending,
  int sentAt,
  PeerMessageAction? action,
});

Map<String, MessagePresentation> projectMessageActions(
  Iterable<MessageActionEntry> entries,
) {
  final originals = <String, MessageActionEntry>{};
  final mutations = <MessageActionEntry>[];
  for (final entry in entries) {
    if (entry.visible) {
      originals[entry.key] = entry;
    } else if (entry.action != null) {
      mutations.add(entry);
    }
  }
  final changes = <String, MessageActionEntry>{};
  for (final entry in mutations) {
    final action = entry.action!;
    final target = originals[action.target];
    if (target == null || target.author != entry.author) continue;
    if (action.kind == PeerMessageActionKind.edit && target.hasAttachment) {
      continue;
    }
    final previous = changes[target.key];
    if (previous?.action?.kind == PeerMessageActionKind.delete) continue;
    if (action.kind == PeerMessageActionKind.delete ||
        previous == null ||
        entry.sentAt > previous.sentAt ||
        entry.sentAt == previous.sentAt &&
            entry.id.compareTo(previous.id) > 0) {
      changes[target.key] = entry;
    }
  }
  return {
    for (final original in originals.values)
      original.key: _present(original, changes[original.key]),
  };
}

MessagePresentation _present(
  MessageActionEntry original,
  MessageActionEntry? change,
) {
  final action = change?.action;
  if (action?.kind == PeerMessageActionKind.delete) {
    return (
      text: 'Message deleted',
      preview: null,
      edited: false,
      deleted: true,
      pending: change!.pending,
    );
  }
  final isEdit = action?.kind == PeerMessageActionKind.edit;
  final link = readLinkPreview(isEdit ? action!.text! : original.text);
  return (
    text: link.text,
    preview: link.preview,
    edited: isEdit,
    deleted: false,
    pending: change?.pending ?? false,
  );
}
