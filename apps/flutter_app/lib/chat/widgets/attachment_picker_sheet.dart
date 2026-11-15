import 'package:flutter/material.dart';

import '../attachment_files.dart';

Future<AttachmentPickKind?> showAttachmentPickerSheet(BuildContext context) =>
    showModalBottomSheet<AttachmentPickKind>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
          child: Row(
            children: [
              for (final choice in [
                (
                  AttachmentPickKind.media,
                  Icons.photo_library_outlined,
                  'Gallery',
                ),
                (AttachmentPickKind.audio, Icons.audio_file_outlined, 'Audio'),
                (
                  AttachmentPickKind.file,
                  Icons.insert_drive_file_outlined,
                  'Files',
                ),
              ])
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.pop(context, choice.$1),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(choice.$2, size: 32),
                          const SizedBox(height: 10),
                          Text(choice.$3),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
