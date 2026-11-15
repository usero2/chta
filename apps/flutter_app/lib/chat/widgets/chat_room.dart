import 'package:flutter/material.dart';

import '../chat_models.dart';
import '../chat_attachment.dart';
import '../media_item.dart';
import '../media_thumbnail.dart';
import 'media_album.dart';
import 'message_bubble.dart';
import 'attachment_content.dart';
import 'message_composer.dart';

class ChatRoom extends StatelessWidget {
  const ChatRoom({
    required this.conversation,
    required this.onSend,
    this.onSendAttachment,
    this.onSendBatch,
    this.onBack,
    this.onDelete,
    super.key,
  });

  final ConversationView conversation;
  final Future<bool> Function(String) onSend;
  final Future<bool> Function(ChatAttachment)? onSendAttachment;
  final Future<bool> Function(String, List<ChatAttachment>)? onSendBatch;
  final VoidCallback? onBack;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    MediaItem item(MessageView message) {
      final file = message.attachment!;
      return MediaItem(
        id: message.id.toString(),
        name: file.name,
        kind: file.kind,
        incoming: message.incoming,
        caption: file.caption,
        groupId: file.groupId,
        groupIndex: file.groupIndex,
        groupCount: file.groupCount,
        loadFile: () async => file,
        loadThumbnail: () => createMediaThumbnail(file),
      );
    }

    final groups = groupMedia<MessageView>(
      conversation.messages,
      (message) => message.attachment == null ? null : item(message).groupKey,
    );
    return ColoredBox(
      color: const Color(0xFF1A1A1A),
      child: Column(
        children: [
          SizedBox(
            height: 68,
            child: Row(
              children: [
                if (onBack != null)
                  IconButton(
                    key: const Key('back-to-conversations'),
                    onPressed: onBack,
                    tooltip: 'Back to chats',
                    icon: const Icon(Icons.arrow_back),
                  ),
                const SizedBox(width: 12),
                CircleAvatar(
                  backgroundColor: const Color(0xFF3A3A3C),
                  child: Text(conversation.title.characters.first),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    conversation.title,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (onDelete != null)
                  PopupMenuButton<String>(
                    tooltip: 'Chat actions',
                    icon: const Icon(Icons.more_vert),
                    onSelected: (_) => onDelete!(),
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                        value: 'delete',
                        child: Text('Delete chat'),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
              itemCount: groups.length,
              itemBuilder: (context, index) {
                final group = groups[index];
                final message = group.first;
                final album =
                    message.attachment != null &&
                    item(message).groupKey != null;
                return MessageBubble(
                  bubbleKey: const Key('message-bubble'),
                  text: message.text,
                  incoming: message.incoming,
                  sentAtMilliseconds: message.sentAtMilliseconds,
                  receivedAtMilliseconds: null,
                  showReceivedTime: false,
                  content: album
                      ? MediaAlbum(items: group.map(item).toList())
                      : message.attachment == null
                      ? null
                      : AttachmentContent(
                          attachment: message.attachment!,
                          incoming: message.incoming,
                        ),
                );
              },
            ),
          ),
          MessageComposer(
            key: ValueKey(conversation.id),
            onSend: onSend,
            onSendAttachment: onSendAttachment,
            onSendBatch: onSendBatch,
          ),
        ],
      ),
    );
  }
}
