import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../attachment_export.dart';
import '../attachment_files.dart';
import '../chat_attachment.dart';
import '../media_item.dart';
import '../media_thumbnail.dart';
import 'media_album.dart';
import 'media_viewer.dart';
export 'media_viewer.dart' show AttachmentMediaControls;
import '../peer_history.dart';
import 'message_bubble.dart';
import 'media_caption.dart';

class CachedAttachmentContent extends StatefulWidget {
  const CachedAttachmentContent({
    super.key,
    required this.history,
    required this.message,
    this.transfer,
  });
  final PeerHistory history;
  final PeerMessage message;
  final Widget? transfer;
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

  Widget _withTransfer(Widget content) {
    final transfer = widget.transfer;
    return transfer == null
        ? content
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              content,
              SizedBox(width: 260, child: transfer),
            ],
          );
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
      ? _withTransfer(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.insert_drive_file_outlined),
              const SizedBox(width: 8),
              Flexible(child: Text(widget.message.attachmentRef!.name)),
            ],
          ),
        )
      : FutureBuilder<ChatAttachment>(
          future: _file,
          builder: (context, snapshot) {
            if (snapshot.hasData) {
              return AttachmentContent(
                attachment: snapshot.data!,
                incoming: widget.message.incoming,
                transfer: widget.transfer,
                loadThumbnail: () => widget.history.thumbnailFor(
                  widget.message,
                  generate: createMediaThumbnail,
                ),
              );
            }
            if (snapshot.hasError) {
              return _withTransfer(
                TextButton.icon(
                  onPressed: () => setState(
                    () => _file = widget.history.resolveAttachment(
                      widget.message,
                    ),
                  ),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry cached file'),
                ),
              );
            }
            return _withTransfer(
              const SizedBox(width: 180, child: LinearProgressIndicator()),
            );
          },
        );
}

class AttachmentContent extends StatelessWidget {
  const AttachmentContent({
    super.key,
    required this.attachment,
    required this.incoming,
    this.loadThumbnail,
    this.transfer,
  });
  final ChatAttachment attachment;
  final bool incoming;
  final Future<Uint8List?> Function()? loadThumbnail;
  final Widget? transfer;

  Future<String> _readMarkdown() async {
    if (!attachment.isStreamed) {
      return utf8.decode(attachment.bytes, allowMalformed: true);
    }
    final bytes = BytesBuilder(copy: false);
    await writeAttachmentToSink(attachment, (part) async => bytes.add(part));
    return utf8.decode(bytes.takeBytes(), allowMalformed: true);
  }

  @override
  Widget build(BuildContext context) {
    final visualMedia =
        attachment.kind == 'image' || attachment.kind == 'video';
    if (visualMedia && !attachment.isStreamed) {
      return MediaAlbum(
        key: ObjectKey(
          attachment.isStreamed ? attachment.source : attachment.bytes,
        ),
        footerFor: transfer == null ? null : (_) => transfer!,
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
    final color = visualMedia
        ? Theme.of(context).colorScheme.onSurface
        : incoming
        ? const Color(0xFFECECEC)
        : const Color(0xFF0B0B0B);
    final canReadMarkdown =
        attachment.name.toLowerCase().endsWith('.md') &&
        (!attachment.isStreamed ||
            attachment.size <= ChatAttachment.maxLongMessageBytes);
    final canOpen =
        canReadMarkdown ||
        (!attachment.isStreamed && attachment.kind != 'file');
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
      if (attachment.kind == 'audio') {
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
      } else if (canReadMarkdown) {
        final markdown = _readMarkdown();
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            fullscreenDialog: true,
            builder: (readerContext) => Scaffold(
              appBar: AppBar(title: Text(attachment.name)),
              body: FutureBuilder<String>(
                future: markdown,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return const Center(child: Text('Could not read file.'));
                  }
                  if (!snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  return SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: ChatMarkdown(
                      text: snapshot.data!,
                      color: Theme.of(readerContext).colorScheme.onSurface,
                    ),
                  );
                },
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
                    : canReadMarkdown
                    ? Icons.article_outlined
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
              if (transfer == null)
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
        if (transfer case final footer?) SizedBox(width: 260, child: footer),
        if (attachment.caption?.trim().isNotEmpty == true && visualMedia)
          MediaCaption(text: attachment.caption!, incoming: incoming)
        else if (!visualMedia && attachment.caption?.isNotEmpty == true)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: ChatMarkdown(text: attachment.caption!, color: color),
          ),
        if (canReadMarkdown) ...[
          _MarkdownPreview(attachment: attachment, color: color),
          Divider(height: 1, color: color.withValues(alpha: .22)),
          TextButton(
            onPressed: open,
            style: TextButton.styleFrom(
              foregroundColor: color,
              visualDensity: VisualDensity.compact,
            ),
            child: const Text('Read more'),
          ),
        ],
      ],
    );
  }
}

class _MarkdownPreview extends StatefulWidget {
  const _MarkdownPreview({required this.attachment, required this.color});

  final ChatAttachment attachment;
  final Color color;

  @override
  State<_MarkdownPreview> createState() => _MarkdownPreviewState();
}

class _MarkdownPreviewState extends State<_MarkdownPreview> {
  late Future<String> _preview = widget.attachment.readTextExcerpt(300);

  @override
  void didUpdateWidget(covariant _MarkdownPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.attachment != widget.attachment) {
      _preview = widget.attachment.readTextExcerpt(300);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<String>(
    future: _preview,
    builder: (context, snapshot) {
      final preview = snapshot.data;
      if (snapshot.connectionState != ConnectionState.done ||
          preview == null ||
          preview.isEmpty) {
        return const SizedBox.shrink();
      }
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(preview, style: TextStyle(color: widget.color)),
      );
    },
  );
}

String _size(int bytes) => bytes < 1024
    ? '$bytes B'
    : bytes < 1048576
    ? '${(bytes / 1024).toStringAsFixed(1)} KB'
    : '${(bytes / 1048576).toStringAsFixed(1)} MB';
