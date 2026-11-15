import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../media_item.dart';
import '../attachment_files.dart';
import 'media_viewer.dart';
import 'message_bubble.dart';

class MediaAlbum extends StatelessWidget {
  const MediaAlbum({super.key, required this.items, this.onOpen});
  final List<MediaItem> items;
  final ValueChanged<int>? onOpen;
  @override
  Widget build(BuildContext context) {
    final ordered = List<MediaItem>.of(items)
      ..sort((a, b) => (a.groupIndex ?? 0).compareTo(b.groupIndex ?? 0));
    final caption = ordered
        .where((item) => item.caption?.isNotEmpty == true)
        .firstOrNull
        ?.caption;
    final color = ordered.first.incoming
        ? const Color(0xFFECECEC)
        : const Color(0xFF0B0B0B);
    void open(int index) {
      if (onOpen != null) {
        onOpen!(index);
        return;
      }
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => MediaViewer(items: ordered, initialIndex: index),
        ),
      );
    }

    return SizedBox(
      width: 340,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (ordered.first.kind == 'video')
            SizedBox(
              height: 142,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: ordered.length,
                separatorBuilder: (_, _) => const SizedBox(width: 6),
                itemBuilder: (context, index) => SizedBox(
                  width: 104,
                  child: _AlbumTile(
                    key: ValueKey(ordered[index].id),
                    item: ordered[index],
                    onOpen: () => open(index),
                    color: color,
                  ),
                ),
              ),
            )
          else
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: ordered.length > 1 ? 2 : 1,
                crossAxisSpacing: 5,
                mainAxisSpacing: 5,
              ),
              itemCount: ordered.length,
              itemBuilder: (context, index) => _AlbumTile(
                key: ValueKey(ordered[index].id),
                item: ordered[index],
                onOpen: () => open(index),
                color: color,
              ),
            ),
          if (caption != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: ChatMarkdown(text: caption, color: color),
            ),
        ],
      ),
    );
  }
}

class _AlbumTile extends StatefulWidget {
  const _AlbumTile({
    super.key,
    required this.item,
    required this.onOpen,
    required this.color,
  });
  final MediaItem item;
  final VoidCallback onOpen;
  final Color color;
  @override
  State<_AlbumTile> createState() => _AlbumTileState();
}

class _AlbumTileState extends State<_AlbumTile> {
  late final Future<Uint8List?> _preview = widget.item.kind == 'image'
      ? widget.item.loadFile().then(
          (file) => file.isStreamed ? null : file.bytes,
        )
      : widget.item.loadThumbnail?.call() ?? Future.value();
  Future<void> _save() async {
    try {
      await saveChatAttachment(await widget.item.loadFile());
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not save file: $error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Expanded(
        child: InkWell(
          key: Key('album-item-${widget.item.id}'),
          onTap: widget.onOpen,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(
                  color: const Color(0xFF333335),
                  child: FutureBuilder<Uint8List?>(
                    future: _preview,
                    builder: (context, snapshot) {
                      if (snapshot.hasData) {
                        return Image.memory(
                          snapshot.data!,
                          semanticLabel: widget.item.name,
                          fit: BoxFit.cover,
                          cacheWidth: 480,
                          errorBuilder: (_, _, _) =>
                              const Icon(Icons.broken_image_outlined),
                        );
                      }
                      return Icon(
                        widget.item.kind == 'video'
                            ? Icons.movie_outlined
                            : Icons.image_outlined,
                        color: Colors.white70,
                      );
                    },
                  ),
                ),
                if (widget.item.kind == 'video')
                  const Center(
                    child: Icon(
                      Icons.play_circle_fill,
                      size: 38,
                      color: Colors.white,
                    ),
                  ),
                Positioned(
                  left: 4,
                  bottom: 4,
                  child: Tooltip(
                    message: 'Cached',
                    child: Icon(
                      Icons.offline_pin_outlined,
                      size: 15,
                      color: Colors.white,
                    ),
                  ),
                ),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: IconButton(
                    onPressed: widget.item.onRetry ?? _save,
                    tooltip: widget.item.onRetry != null
                        ? 'Retry'
                        : 'Save copy',
                    icon: Icon(
                      widget.item.onRetry != null
                          ? Icons.refresh
                          : Icons.save_alt,
                      size: 19,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      if (widget.item.kind == 'video')
        Text(
          widget.item.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 11, color: widget.color),
        ),
    ],
  );
}
