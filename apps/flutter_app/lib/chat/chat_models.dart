import 'dart:convert';

import 'chat_attachment.dart';

const localAttachmentPrefix = '\u001eCHT_LOCAL_FILE_V1:';
ChatAttachment? localAttachment(String text) {
  if (!text.startsWith(localAttachmentPrefix)) return null;
  try {
    return ChatAttachment.fromJson(
      jsonDecode(text.substring(localAttachmentPrefix.length))
          as Map<String, dynamic>,
    );
  } catch (_) {
    return null;
  }
}

class MessageView {
  const MessageView({
    required this.id,
    required this.text,
    required this.sentAtMilliseconds,
    required this.incoming,
    this.attachment,
  });

  factory MessageView.fromJson(Map<String, Object?> json) {
    final text = _string(json, 'text');
    final attachment = localAttachment(text);
    return MessageView(
      id: _int(json, 'id'),
      text: attachment?.previewLabel ?? text,
      attachment: attachment,
      sentAtMilliseconds: _int(json, 'sentAtMilliseconds'),
      incoming: _bool(json, 'incoming'),
    );
  }

  final int id;
  final String text;
  final int sentAtMilliseconds;
  final bool incoming;
  final ChatAttachment? attachment;
}

class ConversationView {
  ConversationView({
    required this.id,
    required this.title,
    required this.preview,
    required this.updatedAtMilliseconds,
    required List<MessageView> messages,
    this.avatarBase64 = '',
  }) : messages = List.unmodifiable(messages);

  factory ConversationView.fromJson(Map<String, Object?> json) =>
      ConversationView(
        id: _string(json, 'id'),
        title: _string(json, 'title'),
        preview: _localPreview(_string(json, 'preview')),
        updatedAtMilliseconds: _int(json, 'updatedAtMilliseconds'),
        messages: _list(
          json,
          'messages',
        ).map((item) => MessageView.fromJson(_map(item, 'message'))).toList(),
      );

  final String id;
  final String title;
  final String preview;
  final int updatedAtMilliseconds;
  final List<MessageView> messages;
  final String avatarBase64;
}

String _localPreview(String text) {
  if (!text.startsWith(localAttachmentPrefix)) return text;
  try {
    final value = jsonDecode(
      text.substring(localAttachmentPrefix.length),
    ) as Map<String, dynamic>;
    final name = value['name'] as String;
    final mime = value['mimeType'] as String;
    ChatAttachment.validateMetadata(name, mime, 0);
    final type = mime.toLowerCase().split('/').first;
    return '[${['image', 'audio', 'video'].contains(type) ? type : 'file'}] $name';
  } catch (_) {
    return text;
  }
}

class ChatSnapshot {
  ChatSnapshot({
    required this.schemaVersion,
    required List<ConversationView> conversations,
  }) : conversations = List.unmodifiable(conversations) {
    if (schemaVersion != 1) {
      throw FormatException('Unsupported chat snapshot schema: $schemaVersion');
    }
  }

  factory ChatSnapshot.fromJson(Map<String, Object?> json) => ChatSnapshot(
    schemaVersion: _int(json, 'schemaVersion'),
    conversations: _list(json, 'conversations')
        .map((item) => ConversationView.fromJson(_map(item, 'conversation')))
        .toList(),
  );

  final int schemaVersion;
  final List<ConversationView> conversations;
}

String _string(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String) return value;
  throw FormatException('$key must be a string');
}

int _int(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is int) return value;
  throw FormatException('$key must be an integer');
}

bool _bool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is bool) return value;
  throw FormatException('$key must be a boolean');
}

List<Object?> _list(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is List<Object?>) return value;
  throw FormatException('$key must be a list');
}

Map<String, Object?> _map(Object? value, String label) {
  if (value is Map<String, Object?>) return value;
  throw FormatException('$label must be an object');
}
