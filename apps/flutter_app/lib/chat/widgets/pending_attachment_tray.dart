import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../chat_attachment.dart';
import '../media_thumbnail.dart';

class PendingAttachmentTray extends StatelessWidget {
  const PendingAttachmentTray({
    super.key,
    required this.files,
    required this.onRemove,
    this.generateThumbnail = createMediaThumbnail,
  });
  final List<ChatAttachment> files;
  final ValueChanged<int>? onRemove;
  final Future<Uint8List?> Function(ChatAttachment) generateThumbnail;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 84,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: files.length,
      separatorBuilder: (_, _) => const SizedBox(width: 8),
      itemBuilder: (context, index) {
        final file = files[index];
        return SizedBox(
          key: Key('pending-attachment-$index'),
          width: 76,
          height: 76,
          child: Tooltip(
            message: file.name,
            child: Stack(
              children: [
                Positioned.fill(
                  bottom: 8,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: ColoredBox(
                      color: const Color(0xFF303032),
                      child: file.kind == 'image' && !file.isStreamed
                          ? Image.memory(
                              file.bytes,
                              fit: BoxFit.cover,
                              cacheWidth: 160,
                              errorBuilder: (_, _, _) =>
                                  const Icon(Icons.image_outlined),
                            )
                          : file.kind == 'video' && !file.isStreamed
                          ? _PendingVideoCover(
                              key: ObjectKey(file.bytes),
                              file: file,
                              generate: generateThumbnail,
                            )
                          : Padding(
                              padding: const EdgeInsets.all(5),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    file.kind == 'video'
                                        ? Icons.play_circle_fill
                                        : file.kind == 'audio'
                                        ? Icons.audio_file_outlined
                                        : Icons.insert_drive_file_outlined,
                                  ),
                                  Text(
                                    file.name,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 10),
                                  ),
                                ],
                              ),
                            ),
                    ),
                  ),
                ),
                Positioned(
                  top: 0,
                  right: 0,
                  child: SizedBox.square(
                    dimension: 28,
                    child: IconButton.filled(
                      tooltip: 'Delete',
                      padding: EdgeInsets.zero,
                      iconSize: 16,
                      onPressed: onRemove == null
                          ? null
                          : () => onRemove!(index),
                      icon: const Icon(Icons.close),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

class _PendingVideoCover extends StatefulWidget {
  const _PendingVideoCover({
    super.key,
    required this.file,
    required this.generate,
  });

  final ChatAttachment file;
  final Future<Uint8List?> Function(ChatAttachment) generate;

  @override
  State<_PendingVideoCover> createState() => _PendingVideoCoverState();
}

class _PendingVideoCoverState extends State<_PendingVideoCover> {
  // Keep the decoding job across composer rebuilds.
  late final Future<Uint8List?> _preview = widget.generate(widget.file);

  @override
  Widget build(BuildContext context) => Stack(
    key: const Key('pending-video-cover'),
    fit: StackFit.expand,
    children: [
      FutureBuilder<Uint8List?>(
        future: _preview,
        builder: (context, snapshot) => snapshot.hasData
            ? Image.memory(
                snapshot.data!,
                semanticLabel: widget.file.name,
                fit: BoxFit.cover,
                cacheWidth: 160,
                errorBuilder: (_, _, _) => _fallback(),
              )
            : _fallback(),
      ),
      const Center(child: Icon(Icons.play_circle_fill, color: Colors.white)),
    ],
  );

  Widget _fallback() => Padding(
    padding: const EdgeInsets.fromLTRB(5, 34, 5, 0),
    child: Text(
      widget.file.name,
      maxLines: 2,
      textAlign: TextAlign.center,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 10, color: Colors.white70),
    ),
  );
}
