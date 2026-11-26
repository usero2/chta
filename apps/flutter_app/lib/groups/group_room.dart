import 'package:flutter/material.dart';

import '../chat/chat_attachment.dart';
import '../chat/peer_message_action.dart';
import '../chat/message_timestamp.dart';
import '../chat/media_item.dart';
import '../chat/media_thumbnail.dart';
import '../chat/widgets/attachment_content.dart';
import '../chat/widgets/media_album.dart';
import '../chat/widgets/message_action_menu.dart';
import '../chat/widgets/message_bubble.dart';
import '../chat/widgets/message_day_divider.dart';
import '../chat/widgets/message_reply_quote.dart';
import '../chat/widgets/message_composer.dart';
import '../chat/widgets/reply_message_list.dart';
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
    this.onMessageAction,
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
  final Future<bool> Function(PeerMessageActionKind, GroupMessage, String?)?
  onMessageAction;

  @override
  Widget build(BuildContext context) {
    final visible = messages.where((m) => m.isVisible).toList();
    final originals = {for (final message in visible) message.key: message};
    final timeline = messageTimeline(
      visible,
      timeOf: (message) =>
          visibleMessageTime(message.sentAt, message.receivedAt),
      authorOf: (message) => message.senderId,
    );
    final presentations = projectMessageActions(
      messages.map((m) => m.actionEntry),
    );
    return ColoredBox(
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
                      PopupMenuItem(
                        value: 'delete',
                        child: Text('Delete group'),
                      ),
                    ],
                  ),
                  const SizedBox(width: 4),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ReplyMessageList(
                key: ValueKey(group.groupId),
                storageId: 'group-history-${group.groupId}',
                rows: [
                  for (final message in visible) [message.key],
                ],
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 20,
                ),
                itemBuilder: (context, index, jumpTo) {
                  final message = visible[index];
                  final target = message.action?.target;
                  final original = originals[target];
                  return _message(
                    context,
                    message,
                    presentations[message.key]!,
                    timeline[index],
                    target == null
                        ? null
                        : _quote(
                            original,
                            presentations[target]?.text ??
                                'Original message unavailable',
                            deleted: presentations[target]?.deleted == true,
                            onJump: original == null
                                ? null
                                : () => jumpTo(target),
                          ),
                  );
                },
              ),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 6,
                ),
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
  }

  Widget _message(
    BuildContext context,
    GroupMessage message,
    MessagePresentation presentation,
    MessageTimelineMarker time,
    Widget? quote,
  ) {
    final incoming = message.senderId != ownId;
    final deleted = presentation.deleted;
    final manifest = deleted ? null : message.manifest;
    final content = manifest == null ? null : _fileContent(message, manifest);
    final receipts = message.recipients
        .map((id) => message.receipts[id])
        .nonNulls;
    final recipientCount = message.recipients.length;
    final delivered =
        !incoming &&
        !deleted &&
        recipientCount > 0 &&
        receipts.length == recipientCount;
    final sentToGroup = !incoming && !deleted && recipientCount > 0;
    final receiveTime = incoming
        ? message.receivedAt
        : delivered
        ? receipts.reduce((latest, next) => latest > next ? latest : next)
        : null;
    final deliveryDetail = sentToGroup
        ? deliveryLabel?.call(message) ??
              '${receipts.length}/$recipientCount delivered'
        : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: incoming
            ? CrossAxisAlignment.start
            : CrossAxisAlignment.end,
        children: [
          if (time.dayLabel case final label?) MessageDayDivider(label),
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
            quote: deleted ? null : quote,
            media:
                manifest?.mimeType.toLowerCase().startsWith('image/') == true ||
                manifest?.mimeType.toLowerCase().startsWith('video/') == true,
            bubbleKey: Key('group-message-${message.key}'),
            actions: deleted
                ? null
                : MessageActionMenu(
                    buttonKey: ValueKey('group-message-actions-${message.key}'),
                    canEdit: !incoming && manifest == null,
                    canDelete: !incoming,
                    copyText: manifest == null ? presentation.text : null,
                    onSelected: enabled && onMessageAction != null
                        ? (action) => _selectAction(
                            context,
                            action,
                            message,
                            presentation.text,
                          )
                        : null,
                    unavailableReason: !enabled
                        ? 'Message actions are unavailable in this group.'
                        : onMessageAction == null
                        ? 'All members need to support message actions.'
                        : null,
                  ),
            text: presentation.text,
            incoming: incoming,
            sentAtMilliseconds: message.sentAt,
            receivedAtMilliseconds: receiveTime,
            showTime: time.showTime,
            deliveryIndicator: delivered
                ? MessageDeliveryIndicator.delivered
                : sentToGroup
                ? MessageDeliveryIndicator.pending
                : null,
            deliveryDetail: deliveryDetail,
            content: content,
          ),
          if (presentation.pending || presentation.edited)
            Text(
              presentation.pending
                  ? (deleted ? 'Delete pending' : 'Edit pending')
                  : 'Edited',
              style: Theme.of(context).textTheme.labelSmall,
            ),
        ],
      ),
    );
  }

  Widget _quote(
    GroupMessage? original,
    String text, {
    bool deleted = false,
    VoidCallback? onJump,
  }) {
    final file = deleted ? null : original?.manifest;
    final image =
        file != null &&
        file.mimeType.toLowerCase().startsWith('image/') &&
        progressFor(file.fileId)?.complete == true;
    return MessageReplyQuote(
      key: ValueKey(original?.key),
      text: text.trim().isNotEmpty ? text : file?.name ?? 'Message',
      author: original == null
          ? null
          : original.senderId == ownId
          ? 'You'
          : original.senderName,
      onJump: onJump,
      loadImage: image ? () => openFile(file) : null,
    );
  }

  Future<void> _selectAction(
    BuildContext context,
    PeerMessageActionKind action,
    GroupMessage message,
    String text,
  ) async {
    if (action == PeerMessageActionKind.delete) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Delete message for everyone?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (confirmed == true && context.mounted) {
        await onMessageAction?.call(action, message, null);
      }
      return;
    }
    final reply = action == PeerMessageActionKind.reply;
    var input = reply ? '' : text;
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(reply ? 'Reply' : 'Edit message'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (reply) ...[_quote(message, text), const SizedBox(height: 8)],
            TextFormField(
              autofocus: true,
              initialValue: input,
              minLines: 2,
              maxLines: 8,
              onChanged: (value) => input = value,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, input.trim()),
            child: Text(reply ? 'Send' : 'Save'),
          ),
        ],
      ),
    );
    if (value != null &&
        value.isNotEmpty &&
        (reply || value != text) &&
        context.mounted) {
      await onMessageAction?.call(action, message, value);
    }
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
