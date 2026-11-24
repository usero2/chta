import 'package:flutter/material.dart';

import '../chat/chat_attachment.dart';
import '../chat/media_item.dart';
import '../chat/media_thumbnail.dart';
import '../chat/widgets/attachment_content.dart';
import '../chat/widgets/media_album.dart';
import '../chat/widgets/message_bubble.dart';
import '../chat/widgets/message_composer.dart';
import '../profile/profile_avatar.dart';
import 'group_models.dart';
import 'swarm/swarm.dart';

class GroupRoom extends StatelessWidget {
  const GroupRoom({
    required this.group,
    required this.ownId,
    required this.messages,
    required this.enabled,
    required this.onlineCount,
    required this.onSend,
    required this.onSendBatch,
    required this.openFile,
    required this.progressFor,
    required this.onDetails,
    required this.onDelete,
    this.disabledReason,
    this.error,
    this.onBack,
    this.deliveryLabel,
    super.key,
  });

  final GroupView group;
  final String ownId;
  final List<GroupMessage> messages;
  final bool enabled;
  final int onlineCount;
  final Future<bool> Function(String) onSend;
  final Future<bool> Function(String, List<ChatAttachment>) onSendBatch;
  final Future<ChatAttachment> Function(SwarmManifest) openFile;
  final SwarmProgress? Function(String) progressFor;
  final VoidCallback onDetails;
  final VoidCallback onDelete;
  final VoidCallback? onBack;
  final String? disabledReason, error;
  final String? Function(GroupMessage)? deliveryLabel;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: const Color(0xFF1A1A1A),
    child: SafeArea(
      child: Column(
        children: [
          SizedBox(
            height: 68,
            child: Row(
              children: [
                if (onBack != null)
                  IconButton(
                    onPressed: onBack,
                    tooltip: 'Back to chats',
                    icon: const Icon(Icons.arrow_back),
                  ),
                const SizedBox(width: 8),
                const CircleAvatar(
                  backgroundColor: Color(0xFF3A3A3C),
                  child: Icon(Icons.groups_outlined),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        group.name,
                        key: const Key('group-room-title'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        !enabled
                            ? disabledReason ??
                                  (group.closed
                                      ? 'Group closed'
                                      : 'Waiting for group owner')
                            : '${group.members.length} members · $onlineCount online',
                        key: const Key('group-room-status'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: enabled
                              ? const Color(0xFF8E8E93)
                              : const Color(0xFFE4B75B),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  key: const Key('group-actions-menu'),
                  tooltip: 'Group actions',
                  onSelected: (action) {
                    if (action == 'details') onDetails();
                    if (action == 'delete') onDelete();
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: 'details',
                      child: Text('Group details'),
                    ),
                    PopupMenuItem(value: 'delete', child: Text('Delete group')),
                  ],
                ),
                const SizedBox(width: 4),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              key: const Key('group-message-list'),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 20),
              itemCount: messages.length,
              itemBuilder: (context, index) => _message(messages[index]),
            ),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              child: Text(
                error!,
                style: const TextStyle(color: Colors.redAccent),
              ),
            ),
          IgnorePointer(
            ignoring: !enabled,
            child: Opacity(
              opacity: enabled ? 1 : .5,
              child: MessageComposer(
                key: const Key('group-message-composer'),
                inputKey: const Key('group-message-input'),
                sendKey: const Key('group-send-message'),
                onSend: onSend,
                onSendBatch: onSendBatch,
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _message(GroupMessage message) {
    final incoming = message.senderId != ownId;
    final manifest = message.manifest;
    final content = manifest == null ? null : _fileContent(message, manifest);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: incoming
            ? CrossAxisAlignment.start
            : CrossAxisAlignment.end,
        children: [
          if (incoming)
            Padding(
              padding: const EdgeInsets.only(left: 2, bottom: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ProfileAvatar(name: message.senderName, radius: 14),
                  const SizedBox(width: 7),
                  Text(
                    message.senderName,
                    key: Key('group-sender-${message.key}'),
                    style: const TextStyle(
                      color: Color(0xFFB6B6BA),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          MessageBubble(
            media:
                manifest?.mimeType.toLowerCase().startsWith('image/') == true ||
                manifest?.mimeType.toLowerCase().startsWith('video/') == true,
            bubbleKey: Key('group-message-${message.key}'),
            text: message.text,
            incoming: incoming,
            sentAtMilliseconds: message.sentAt,
            receivedAtMilliseconds: message.receivedAt,
            content: content,
          ),
          if (!incoming)
            Padding(
              padding: const EdgeInsets.only(right: 4, top: 1),
              child: Text(
                deliveryLabel?.call(message) ??
                    (message.receipts.isEmpty
                        ? 'Pending · 0/${message.recipients.length} delivered'
                        : '${message.receipts.length}/${message.recipients.length} delivered'),
                key: Key('group-delivery-${message.key}'),
                style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }

  Widget _fileContent(GroupMessage message, SwarmManifest manifest) {
    final progress = progressFor(manifest.fileId);
    if (progress?.complete != true) {
      final value = progress;
      final ratio = value == null || value.totalBytes == 0
          ? 0.0
          : (value.verifiedBytes / value.totalBytes).clamp(0.0, 1.0);
      return SizedBox(
        width: 240,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.insert_drive_file_outlined, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    manifest.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text('${(ratio * 100).round()}%'),
              ],
            ),
            const SizedBox(height: 6),
            LinearProgressIndicator(value: ratio),
            const SizedBox(height: 4),
            Text(
              value?.waitingForDirect == true
                  ? 'Waiting for Direct'
                  : '${value?.sourceCount ?? 0} sources',
              key: Key('group-file-progress-${manifest.fileId}'),
              style: const TextStyle(fontSize: 11, color: Color(0xFF8E8E93)),
            ),
          ],
        ),
      );
    }
    return _CompletedGroupFile(
      key: ValueKey(manifest.fileId),
      manifest: manifest,
      incoming: message.senderId != ownId,
      openFile: openFile,
    );
  }
}

class _CompletedGroupFile extends StatefulWidget {
  const _CompletedGroupFile({
    super.key,
    required this.manifest,
    required this.incoming,
    required this.openFile,
  });

  final SwarmManifest manifest;
  final bool incoming;
  final Future<ChatAttachment> Function(SwarmManifest) openFile;

  @override
  State<_CompletedGroupFile> createState() => _CompletedGroupFileState();
}

class _CompletedGroupFileState extends State<_CompletedGroupFile> {
  late Future<ChatAttachment> _file;

  @override
  void initState() {
    super.initState();
    _file = widget.openFile(widget.manifest);
  }

  @override
  void didUpdateWidget(covariant _CompletedGroupFile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.manifest.fileId != widget.manifest.fileId ||
        oldWidget.manifest.groupId != widget.manifest.groupId ||
        oldWidget.manifest.epoch != widget.manifest.epoch) {
      _file = widget.openFile(widget.manifest);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<ChatAttachment>(
    future: _file,
    builder: (context, snapshot) {
      if (!snapshot.hasData) {
        if (snapshot.hasError) return const Text('File unavailable');
        return const SizedBox(width: 180, child: LinearProgressIndicator());
      }
      final file = snapshot.data!;
      if (file.kind == 'image' ||
          file.kind == 'video' ||
          file.kind == 'audio') {
        final item = MediaItem(
          id: widget.manifest.fileId,
          name: file.name,
          kind: file.kind,
          incoming: widget.incoming,
          caption: file.caption,
          loadFile: () async => file,
          loadThumbnail: () => createMediaThumbnail(file),
        );
        return LayoutBuilder(
          builder: (context, constraints) => SizedBox(
            width: constraints.maxWidth.clamp(0, 340).toDouble(),
            child: MediaAlbum(items: [item]),
          ),
        );
      }
      return AttachmentContent(
        attachment: file,
        incoming: widget.incoming,
        loadThumbnail: () => createMediaThumbnail(file),
      );
    },
  );
}
