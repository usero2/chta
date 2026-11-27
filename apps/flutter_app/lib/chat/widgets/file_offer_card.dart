import 'package:flutter/material.dart';

import '../file_offer_cover.dart';

class FileOfferCard extends StatelessWidget {
  const FileOfferCard({
    super.key,
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
    this.caption,
    this.cover,
    this.status,
    this.error,
    this.busy = false,
    this.onAccept,
    this.onReject,
  });

  final String fileName;
  final String mimeType;
  final int sizeBytes;
  final String? caption;
  final String? cover;
  final String? status;
  final String? error;
  final bool busy;
  final VoidCallback? onAccept;
  final VoidCallback? onReject;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final caption = this.caption;
    final status = this.status;
    final error = this.error;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: Card.filled(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _preview(colors),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          fileName,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                        Text(
                          '$mimeType · ${_formatSize(sizeBytes)}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (caption != null && caption.trim().isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(caption, style: theme.textTheme.bodyMedium),
              ],
              if (error != null) ...[
                const SizedBox(height: 8),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    error,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.error,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 4),
              if (status != null)
                Semantics(
                  liveRegion: true,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(status, style: theme.textTheme.labelLarge),
                  ),
                )
              else
                Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    FilledButton(
                      onPressed: busy ? null : onAccept,
                      child: const Text('Accept'),
                    ),
                    TextButton(
                      onPressed: busy ? null : onReject,
                      child: const Text('Reject'),
                    ),
                    if (busy)
                      const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          semanticsLabel: 'Processing file offer',
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _preview(ColorScheme colors) {
    final type = mimeType.toLowerCase().split('/').first;
    final fileIcon = switch (type) {
      'image' => Icons.image_outlined,
      'video' => Icons.movie_outlined,
      'audio' => Icons.audio_file_outlined,
      _ => Icons.insert_drive_file_outlined,
    };
    final placeholder = ColoredBox(
      color: colors.surfaceContainerHighest,
      child: Icon(fileIcon, color: colors.onSurfaceVariant),
    );
    final bytes = type == 'image' || type == 'video'
        ? decodeFileOfferCover(cover)
        : null;
    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox.square(
          dimension: 52,
          child: bytes == null
              ? placeholder
              : Image.memory(
                  bytes,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => placeholder,
                ),
        ),
      ),
    );
  }
}

String _formatSize(int bytes) {
  var size = bytes.toDouble();
  for (final unit in ['B', 'KiB', 'MiB', 'GiB']) {
    if (size < 1024 || unit == 'GiB') {
      return '${size.toStringAsFixed(size == size.truncate() ? 0 : 1)} $unit';
    }
    size /= 1024;
  }
  return '$bytes B';
}
