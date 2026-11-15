import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../attachment_files.dart';
import '../chat_attachment.dart';
import '../media_item.dart';
import '../media_thumbnail.dart';
import 'media_album.dart';
import 'media_viewer.dart';
export 'media_viewer.dart' show AttachmentMediaControls;
import '../peer_history.dart';
import 'message_bubble.dart';

class CachedAttachmentContent extends StatefulWidget {
  const CachedAttachmentContent({
    super.key,
    required this.history,
    required this.message,
  });
  final PeerHistory history;
  final PeerMessage message;
  @override
  State<CachedAttachmentContent> createState() =>
      _CachedAttachmentContentState();
}

class _CachedAttachmentContentState extends State<CachedAttachmentContent> {
  Future<ChatAttachment>? _file;
  late bool _waiting;
  bool get _pending =>
      widget.message.incoming &&
      widget.message.attachmentRef?.isChunked == true &&
      widget.message.status != DeliveryStatus.delivered;
  @override
  void initState() {
    super.initState();
    _waiting = _pending;
    if (!_waiting) _file = widget.history.resolveAttachment(widget.message);
  }

  @override
  void didUpdateWidget(covariant CachedAttachmentContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_waiting != _pending ||
        oldWidget.message != widget.message ||
        oldWidget.history != widget.history) {
      _waiting = _pending;
      _file = _waiting
          ? null
          : widget.history.resolveAttachment(widget.message);
    }
  }

  @override
  Widget build(BuildContext context) => _waiting
      ? Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.insert_drive_file_outlined),
            const SizedBox(width: 8),
            Flexible(child: Text(widget.message.attachmentRef!.name)),
          ],
        )
      : FutureBuilder<ChatAttachment>(
          future: _file,
          builder: (context, snapshot) {
            if (snapshot.hasData) {
              return AttachmentContent(
                attachment: snapshot.data!,
                incoming: widget.message.incoming,
                loadThumbnail: () => widget.history.thumbnailFor(
                  widget.message,
                  generate: createMediaThumbnail,
                ),
              );
            }
            if (snapshot.hasError) {
              return TextButton.icon(
                onPressed: () => setState(
                  () =>
                      _file = widget.history.resolveAttachment(widget.message),
                ),
                icon: const Icon(Icons.refresh),
                label: const Text('Retry cached file'),
              );
            }
            return const SizedBox(width: 180, child: LinearProgressIndicator());
          },
        );
}

class AttachmentContent extends StatelessWidget {
  const AttachmentContent({
    super.key,
    required this.attachment,
    required this.incoming,
    this.loadThumbnail,
  });
  final ChatAttachment attachment;
  final bool incoming;
  final Future<Uint8List?> Function()? loadThumbnail;
  @override
  Widget build(BuildContext context) {
    if (attachment.kind == 'video' && !attachment.isStreamed) {
      return MediaAlbum(
        key: ObjectKey(attachment.bytes),
        items: [
          MediaItem(
            id: attachment.name,
            name: attachment.name,
            kind: attachment.kind,
            incoming: incoming,
            caption: attachment.caption,
            loadFile: () async => attachment,
            loadThumbnail:
                loadThumbnail ?? () => createMediaThumbnail(attachment),
          ),
        ],
      );
    }
    final color = incoming ? const Color(0xFFECECEC) : const Color(0xFF0B0B0B);
    final isMarkdown = attachment.name.toLowerCase().endsWith('.md');
    final canOpen =
        !attachment.isStreamed && (attachment.kind != 'file' || isMarkdown);
    Future<void> save() async {
      try {
        await saveChatAttachment(attachment);
      } catch (error) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not save attachment: $error')),
          );
        }
      }
    }

    void open() {
      if (attachment.kind == 'image') {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            fullscreenDialog: true,
            builder: (_) => MediaViewer(
              items: [
                MediaItem(
                  id: attachment.name,
                  name: attachment.name,
                  kind: attachment.kind,
                  incoming: incoming,
                  loadFile: () async => attachment,
                ),
              ],
            ),
          ),
        );
      } else if (attachment.kind == 'audio' || attachment.kind == 'video') {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            fullscreenDialog: true,
            builder: (_) => MediaViewer(
              items: [
                MediaItem(
                  id: attachment.name,
                  name: attachment.name,
                  kind: attachment.kind,
                  incoming: incoming,
                  loadFile: () async => attachment,
                ),
              ],
            ),
          ),
        );
      } else if (isMarkdown) {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            fullscreenDialog: true,
            builder: (_) => Scaffold(
              appBar: AppBar(title: Text(attachment.name)),
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: ChatMarkdown(
                  text: utf8.decode(attachment.bytes, allowMalformed: true),
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ),
          ),
        );
      }
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (attachment.kind == 'image' && !attachment.isStreamed)
          InkWell(
            onTap: open,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.memory(
                attachment.bytes,
                width: 220,
                height: 110,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) =>
                    Icon(Icons.broken_image, color: color),
              ),
            ),
          ),
        InkWell(
          onTap: canOpen ? open : null,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                attachment.kind == 'audio'
                    ? Icons.audio_file
                    : attachment.kind == 'video'
                    ? Icons.play_circle
                    : Icons.insert_drive_file,
                size: 20,
                color: color,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      attachment.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: color),
                    ),
                    Text(
                      _size(attachment.size),
                      style: TextStyle(color: color, fontSize: 11),
                    ),
                  ],
                ),
              ),
              const Tooltip(
                message: 'Cached',
                child: Icon(Icons.offline_pin_outlined, size: 14),
              ),
              IconButton(
                onPressed: save,
                tooltip: 'Save copy',
                icon: Icon(Icons.download, color: color, size: 20),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              ),
            ],
          ),
        ),
        if (attachment.caption?.isNotEmpty == true)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: ChatMarkdown(text: attachment.caption!, color: color),
          ),
      ],
    );
  }
}

String _size(int bytes) => bytes < 1024
    ? '$bytes B'
    : bytes < 1048576
    ? '${(bytes / 1024).toStringAsFixed(1)} KB'
    : '${(bytes / 1048576).toStringAsFixed(1)} MB';
