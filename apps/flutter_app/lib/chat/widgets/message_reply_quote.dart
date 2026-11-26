import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../chat_attachment.dart';

class MessageReplyQuote extends StatefulWidget {
  const MessageReplyQuote({
    super.key,
    required this.text,
    this.author,
    this.onJump,
    this.onClear,
    this.loadImage,
    this.imageVersion,
  });

  final String text;
  final String? author;
  final VoidCallback? onJump, onClear;
  final Future<ChatAttachment> Function()? loadImage;
  final Object? imageVersion;

  @override
  State<MessageReplyQuote> createState() => _MessageReplyQuoteState();
}

class _MessageReplyQuoteState extends State<MessageReplyQuote> {
  late Future<Uint8List?>? _preview = _loadPreview();

  @override
  void didUpdateWidget(covariant MessageReplyQuote oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageVersion != widget.imageVersion ||
        (oldWidget.loadImage == null) != (widget.loadImage == null)) {
      _preview = _loadPreview();
    }
  }

  Future<Uint8List?>? _loadPreview() {
    final load = widget.loadImage;
    if (load == null) return null;
    return () async {
      try {
        final file = await load();
        if (file.kind != 'image') return null;
        if (!file.isStreamed) return file.bytes;
        const maxPreviewSource = 8 * 1024 * 1024;
        if (file.size > maxPreviewSource) return null;
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in file.openRead()) {
          bytes.add(chunk);
          if (bytes.length > maxPreviewSource) return null;
        }
        return bytes.takeBytes();
      } catch (_) {
        return null;
      }
    }();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final quote = Padding(
      padding: const EdgeInsets.fromLTRB(9, 5, 7, 5),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.author case final author?)
                  Text(
                    author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: colors.onSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                Text(
                  widget.text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (widget.loadImage != null) ...[
            const SizedBox(width: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(5),
              child: SizedBox.square(
                dimension: 40,
                child: FutureBuilder<Uint8List?>(
                  future: _preview,
                  builder: (context, snapshot) {
                    const placeholder = Icon(Icons.image_outlined, size: 19);
                    final bytes = snapshot.data;
                    if (bytes == null || bytes.isEmpty) return placeholder;
                    return Image.memory(
                      bytes,
                      semanticLabel: 'Quoted photo',
                      fit: BoxFit.cover,
                      cacheWidth: 120,
                      cacheHeight: 120,
                      errorBuilder: (_, _, _) => placeholder,
                    );
                  },
                ),
              ),
            ),
          ],
          if (widget.onClear != null)
            IconButton(
              onPressed: widget.onClear,
              tooltip: 'Cancel reply',
              icon: const Icon(Icons.close, size: 16),
            ),
        ],
      ),
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: Material(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: BorderDirectional(
              start: BorderSide(color: colors.primary, width: 3),
            ),
          ),
          child: widget.onJump == null
              ? quote
              : Tooltip(
                  message: 'Go to original message',
                  triggerMode: TooltipTriggerMode.manual,
                  child: InkWell(onTap: widget.onJump, child: quote),
                ),
        ),
      ),
    );
  }
}
