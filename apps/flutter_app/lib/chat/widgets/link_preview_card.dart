import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../file_offer_cover.dart';
import '../link_preview.dart';

class LinkPreviewCard extends StatefulWidget {
  const LinkPreviewCard({required this.preview, super.key});

  final LinkPreview preview;

  @override
  State<LinkPreviewCard> createState() => _LinkPreviewCardState();
}

class _LinkPreviewCardState extends State<LinkPreviewCard> {
  late MemoryImage? _cover = _image(widget.preview.cover);

  MemoryImage? _image(String? value) {
    final bytes = decodeFileOfferCover(value);
    return bytes == null ? null : MemoryImage(bytes);
  }

  @override
  void didUpdateWidget(covariant LinkPreviewCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.preview.cover != widget.preview.cover) {
      _cover = _image(widget.preview.cover);
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = widget.preview;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 290),
        child: Material(
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(10),
          clipBehavior: Clip.antiAlias,
          child: Semantics(
            link: true,
            child: InkWell(
              onTap: () async {
                try {
                  if (await launchUrl(preview.url)) return;
                } catch (_) {}
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Could not open link.')),
                  );
                }
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_cover case final cover?)
                    AspectRatio(
                      aspectRatio: 1.9,
                      child: Image(
                        image: cover,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        excludeFromSemantics: true,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.all(10),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          preview.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                        if (preview.description.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(
                            preview.description,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                        const SizedBox(height: 5),
                        Text(
                          preview.url.host,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
