import 'dart:typed_data';

import '../account/account_models.dart';

import 'package:flutter/material.dart';

import '../chat/chat_attachment.dart';
import '../chat/file_offer_cover.dart';
import '../chat/peer_message_action.dart';
import '../chat/message_timestamp.dart';
import '../chat/media_item.dart';
import '../chat/media_thumbnail.dart';
import '../chat/widgets/attachment_content.dart';
import '../chat/widgets/file_offer_card.dart';
import '../chat/widgets/media_album.dart';
import '../chat/widgets/message_action_menu.dart';
import '../chat/widgets/message_bubble.dart';
import '../chat/widgets/message_day_divider.dart';
import '../chat/widgets/message_reply_quote.dart';
import '../chat/widgets/message_composer.dart';
import '../chat/widgets/message_sender_avatar.dart';
import '../chat/widgets/reply_message_list.dart';
import 'group_models.dart';
import 'swarm/swarm.dart';

class GroupRoom extends StatefulWidget {
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
    this.fileChoiceFor,
    this.onFileChoice,
    this.contacts = const {},
    super.key,
  });

  final GroupView group;
  final Map<String, ContactView> contacts;
  final String ownId;
  final List<GroupMessage> messages;
  final bool enabled;
  final int onlineCount;
  final Future<bool> Function(String) onSend;
  final Future<bool> Function(String, List<ChatAttachment>) onSendBatch;
  final Future<ChatAttachment> Function(SwarmManifest) openFile;
  final SwarmProgress? Function(String) progressFor;
  final GroupFileChoice Function(SwarmManifest)? fileChoiceFor;
  final Future<bool> Function(SwarmManifest, GroupFileChoice)? onFileChoice;
  final VoidCallback onDetails;
  final VoidCallback onDelete;
  final VoidCallback? onBack;
  final String? disabledReason, error;
  final String? Function(GroupMessage)? deliveryLabel;
  final Future<bool> Function(PeerMessageActionKind, GroupMessage, String?)?
  onMessageAction;

  @override
  State<GroupRoom> createState() => _GroupRoomState();
}

class _GroupRoomState extends State<GroupRoom> {
  ComposerEdit? _edit;

  @override
  void didUpdateWidget(covariant GroupRoom oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.group.groupId != widget.group.groupId) _edit = null;
  }

  @override
  Widget build(BuildContext context) {
    final visible = widget.messages.where((m) => m.isVisible).toList();
    final originals = {for (final message in visible) message.key: message};
    final timeline = messageTimeline(
      visible,
      timeOf: (message) =>
          visibleMessageTime(message.sentAt, message.receivedAt),
      authorOf: (message) => message.senderId,
    );
    final presentations = projectMessageActions(
      widget.messages.map((m) => m.actionEntry),
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
                  if (widget.onBack != null)
                    IconButton(
                      onPressed: widget.onBack,
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
                          widget.group.name,
                          key: const Key('group-room-title'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          !widget.enabled
                              ? widget.disabledReason ??
                                    (widget.group.closed
                                        ? 'Group closed'
                                        : 'Waiting for group owner')
                              : '${widget.group.members.length} members · ${widget.onlineCount} online',
                          key: const Key('group-room-status'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: widget.enabled
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
                      if (action == 'details') widget.onDetails();
                      if (action == 'delete') widget.onDelete();
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
                key: ValueKey(widget.group.groupId),
                storageId: 'group-history-${widget.group.groupId}',
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
                  final time = timeline[index];
                  final startsSenderRun =
                      index == 0 ||
                      time.dayLabel != null ||
                      visible[index - 1].senderId != message.senderId;
                  return _message(
                    context,
                    message,
                    presentations[message.key]!,
                    time,
                    showSender: startsSenderRun,
                    gapBefore: index == 0 || time.dayLabel != null
                        ? 0
                        : startsSenderRun
                        ? 12
                        : 4,
                    quote: target == null
                        ? null
                        : _quote(
                            original,
                            presentations[target]?.text ??
                                'Original message unavailable',
                            deleted: presentations[target]?.deleted == true,
                            outgoing: message.senderId == widget.ownId,
                            onJump: original == null
                                ? null
                                : () => jumpTo(target),
                          ),
                  );
                },
              ),
            ),
            if (widget.error != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 6,
                ),
                child: Text(
                  widget.error!,
                  style: const TextStyle(color: Colors.redAccent),
                ),
              ),
            IgnorePointer(
              ignoring: !widget.enabled,
              child: Opacity(
                opacity: widget.enabled ? 1 : .5,
                child: MessageComposer(
                  key: const Key('group-message-composer'),
                  inputKey: const Key('group-message-input'),
                  sendKey: const Key('group-send-message'),
                  onSend: widget.onSend,
                  onSendBatch: widget.onSendBatch,
                  edit: _edit,
                  onCancelEdit: () => setState(() => _edit = null),
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
    MessageTimelineMarker time, {
    required bool showSender,
    required double gapBefore,
    Widget? quote,
  }) {
    final incoming = message.senderId != widget.ownId;
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
        ? widget.deliveryLabel?.call(message) ??
              '${receipts.length}/$recipientCount delivered'
        : null;
    final sender = _sender(message);
    final body = Column(
      crossAxisAlignment: incoming
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.end,
      children: [
        if (incoming && showSender)
          Text(
            sender.displayName,
            key: Key('group-sender-${message.key}'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelMedium,
          ),
        MessageBubble(
          bottomSpacing: 0,
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
                  onSelected: widget.enabled && widget.onMessageAction != null
                      ? (action) => _selectAction(
                          context,
                          action,
                          message,
                          presentation.text,
                        )
                      : null,
                  unavailableReason: !widget.enabled
                      ? 'Message actions are unavailable in this group.'
                      : widget.onMessageAction == null
                      ? 'All members need to support message actions.'
                      : null,
                ),
          text: content is _GroupFileOffer ? '' : presentation.text,
          linkPreview: presentation.preview,
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
    );
    return Padding(
      padding: EdgeInsets.only(top: gapBefore),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (time.dayLabel case final label?) MessageDayDivider(label),
          if (incoming)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MessageSenderAvatar(sender: sender, show: showSender),
                Expanded(child: body),
              ],
            )
          else
            body,
        ],
      ),
    );
  }

  ContactView _sender(GroupMessage message) =>
      widget.contacts[message.senderId] ??
      ContactView(
        identityId: message.senderId,
        displayName: message.senderName,
        fingerprint: '',
        verified: false,
      );

  Widget _quote(
    GroupMessage? original,
    String text, {
    bool deleted = false,
    bool outgoing = false,
    VoidCallback? onJump,
  }) {
    final file = deleted ? null : original?.manifest;
    final image =
        file != null &&
        file.mimeType.toLowerCase().startsWith('image/') &&
        widget.progressFor(file.fileId)?.complete == true;
    return MessageReplyQuote(
      key: ValueKey(original?.key),
      text: text.trim().isNotEmpty ? text : file?.name ?? 'Message',
      author: original == null
          ? null
          : original.senderId == widget.ownId
          ? 'You'
          : _sender(original).displayName,
      onJump: onJump,
      outgoing: outgoing,
      loadImage: image ? () => widget.openFile(file) : null,
    );
  }

  Future<void> _selectAction(
    BuildContext context,
    PeerMessageActionKind action,
    GroupMessage message,
    String text,
  ) async {
    if (action == PeerMessageActionKind.edit) {
      setState(() {
        _edit = (
          id: message.key,
          original: text,
          save: (value) async =>
              await widget.onMessageAction?.call(action, message, value) ??
              false,
        );
      });
      return;
    }
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
        await widget.onMessageAction?.call(action, message, null);
      }
      return;
    }
    var input = '';
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reply'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _quote(message, text),
            const SizedBox(height: 8),
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
            child: const Text('Send'),
          ),
        ],
      ),
    );
    if (value != null && value.isNotEmpty && context.mounted) {
      await widget.onMessageAction?.call(action, message, value);
    }
  }

  Widget _fileContent(GroupMessage message, SwarmManifest manifest) {
    final choice = widget.fileChoiceFor?.call(manifest);
    final needsChoice = message.senderId != widget.ownId &&
        (choice == GroupFileChoice.pending ||
            choice == GroupFileChoice.rejected);
    final progress = widget.progressFor(manifest.fileId);
    if (needsChoice || progress?.complete != true) {
      final choose = widget.onFileChoice;
      return _GroupFileOffer(
        key: ValueKey(manifest.fileId),
        manifest: manifest,
        cover: message.fileCover,
        status: !needsChoice
            ? null
            : choice == GroupFileChoice.rejected
            ? 'Rejected'
            : !widget.enabled || choose == null
            ? 'File unavailable'
            : null,
        progress: needsChoice
            ? null
            : progress ??
                  SwarmProgress(
                    verifiedBytes: 0,
                    totalBytes: manifest.size,
                    sourceCount: 0,
                    complete: false,
                    waitingForDirect: false,
                  ),
        onChoice: choose == null ? null : (choice) => choose(manifest, choice),
      );
    }
    return _CompletedGroupFile(
      key: ValueKey(manifest.fileId),
      manifest: manifest,
      cover: message.fileCover,
      incoming: message.senderId != widget.ownId,
      openFile: widget.openFile,
    );
  }
}

class _GroupFileOffer extends StatefulWidget {
  const _GroupFileOffer({
    super.key,
    required this.manifest,
    required this.cover,
    required this.status,
    required this.progress,
    required this.onChoice,
  });

  final SwarmManifest manifest;
  final String? cover, status;
  final SwarmProgress? progress;
  final Future<bool> Function(GroupFileChoice)? onChoice;

  @override
  State<_GroupFileOffer> createState() => _GroupFileOfferState();
}

class _GroupFileOfferState extends State<_GroupFileOffer> {
  bool _busy = false;
  String? _error;

  Future<void> _choose(GroupFileChoice choice) async {
    final onChoice = widget.onChoice;
    if (_busy || onChoice == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final saved = await onChoice(choice);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = saved ? null : 'Could not save your choice.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final progress = widget.progress;
    final ratio = progress == null || progress.totalBytes == 0
        ? 0.0
        : (progress.verifiedBytes / progress.totalBytes).clamp(0.0, 1.0);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          FileOfferCard(
            fileName: widget.manifest.name,
            mimeType: widget.manifest.mimeType,
            sizeBytes: widget.manifest.size,
            caption: widget.manifest.caption,
            cover: widget.cover,
            status: progress == null
                ? widget.status
                : progress.waitingForDirect
                ? 'Waiting for Direct'
                : '${(ratio * 100).round()}%',
            error: _error,
            busy: _busy,
            onAccept: () => _choose(GroupFileChoice.accepted),
            onReject: () => _choose(GroupFileChoice.rejected),
          ),
          if (progress != null) ...[
            const SizedBox(height: 6),
            LinearProgressIndicator(value: ratio),
            const SizedBox(height: 4),
            Text(
              '${progress.sourceCount} sources',
              key: Key('group-file-progress-${widget.manifest.fileId}'),
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ],
      ),
    );
  }
}

class _CompletedGroupFile extends StatefulWidget {
  const _CompletedGroupFile({
    super.key,
    required this.manifest,
    required this.cover,
    required this.incoming,
    required this.openFile,
  });

  final SwarmManifest manifest;
  final String? cover;
  final bool incoming;
  final Future<ChatAttachment> Function(SwarmManifest) openFile;

  @override
  State<_CompletedGroupFile> createState() => _CompletedGroupFileState();
}

class _CompletedGroupFileState extends State<_CompletedGroupFile> {
  late Future<ChatAttachment> _file;
  Uint8List? _cover;

  @override
  void initState() {
    super.initState();
    _file = widget.openFile(widget.manifest);
    _cover = decodeFileOfferCover(widget.cover);
  }

  @override
  void didUpdateWidget(covariant _CompletedGroupFile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.manifest.fileId != widget.manifest.fileId ||
        oldWidget.manifest.groupId != widget.manifest.groupId ||
        oldWidget.manifest.epoch != widget.manifest.epoch) {
      _file = widget.openFile(widget.manifest);
    }
    if (oldWidget.cover != widget.cover) {
      _cover = decodeFileOfferCover(widget.cover);
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
          loadThumbnail: () async =>
              _cover ?? decodeFileOfferCover(await buildFileOfferCover(file)),
        );
        return LayoutBuilder(
          builder: (context, constraints) => SizedBox(
            width: constraints.maxWidth.clamp(0, 340).toDouble(),
            child: MediaAlbum(
              key: ValueKey((widget.manifest.fileId, widget.cover)),
              items: [item],
            ),
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
