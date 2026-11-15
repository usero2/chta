import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:mime/mime.dart';

import 'chat_attachment.dart';
import 'attachment_source.dart';
import 'attachment_export.dart';

enum AttachmentPickKind { media, image, audio, video, file }

Future<List<ChatAttachment>> pickChatAttachments(
  AttachmentPickKind kind, {
  int maxBytes = ChatAttachment.maxStreamedBytes,
}) async {
  final files = await FilePicker.pickFiles(
    type: switch (kind) {
      AttachmentPickKind.media => FileType.media,
      AttachmentPickKind.image => FileType.image,
      AttachmentPickKind.audio => FileType.audio,
      AttachmentPickKind.video => FileType.video,
      AttachmentPickKind.file => FileType.any,
    },
  );
  if (files.length > 5) throw const FormatException('Choose up to 5 files.');
  final result = <ChatAttachment>[];
  var total = 0;
  for (final file in files) {
    final size = await file.length();
    if (size == null) {
      throw const FormatException(
        'Could not determine the selected file size.',
      );
    }
    if (size > maxBytes || size > ChatAttachment.maxStreamedBytes) {
      throw FormatException(
        'Maximum file size is ${maxBytes ~/ (1024 * 1024)} MB.',
      );
    }
    if (size > ChatAttachment.relayMaxBytes) {
      final header = <int>[];
      await for (final chunk in file.readAsByteStream()) {
        header.addAll(chunk.take(32));
        break;
      }
      result.add(
        ChatAttachment.fromSource(
          name: file.name,
          mimeType:
              lookupMimeType(file.name, headerBytes: header) ??
              'application/octet-stream',
          source: PickedAttachmentSource(
            length: size,
            key: file.uri.toString(),
            read: file.readAsByteStream,
          ),
        ),
      );
      continue;
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in file.readAsByteStream()) {
      if (builder.length + chunk.length > maxBytes) {
        throw FormatException(
          'Maximum file size is ${maxBytes ~/ (1024 * 1024)} MB.',
        );
      }
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
    if (bytes.length != size) {
      throw const FormatException('Selected file changed while reading.');
    }
    total += bytes.length;
    if (total > ChatAttachment.maxBytes) {
      throw const FormatException('Maximum total size is 100 MB.');
    }
    result.add(
      ChatAttachment(
        name: file.name,
        mimeType:
            lookupMimeType(file.name, headerBytes: bytes.take(32).toList()) ??
            'application/octet-stream',
        bytes: bytes,
      ),
    );
  }
  return result;
}

Future<void> saveChatAttachment(ChatAttachment attachment) async {
  if (attachment.isStreamed) {
    await exportStreamedAttachment(attachment);
    return;
  }
  await FilePicker.saveFile(
    fileName: attachment.name,
    bytes: attachment.bytes,
    mimeType: attachment.mimeType,
  );
}

/// A picker grant used only until the encrypted cache has imported the file.
/// Each range is processed with stream backpressure, without a file-sized copy.
class PickedAttachmentSource implements AttachmentSource {
  PickedAttachmentSource({
    required this.length,
    required this.key,
    required this.read,
  });
  @override
  final int length;
  @override
  final String key;
  final Stream<Uint8List> Function() read;

  @override
  Stream<List<int>> openRead({int start = 0, int? end}) async* {
    final last = end ?? length;
    if (start < 0 || last < start || last > length) {
      throw RangeError('Attachment range outside selected file');
    }
    if (start == last) return;
    var offset = 0;
    await for (final part in read()) {
      final next = offset + part.length;
      if (next > length) {
        throw const FormatException('Selected file grew while reading');
      }
      if (next > start && offset < last) {
        yield Uint8List.sublistView(
          part,
          (start - offset).clamp(0, part.length),
          (last - offset).clamp(0, part.length),
        );
      }
      offset = next;
      if (offset >= last) break;
    }
    if (offset < last) {
      throw const FormatException('Selected file shrank while reading');
    }
  }
}
