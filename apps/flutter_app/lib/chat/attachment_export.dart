import 'dart:typed_data';

import 'attachment_export_stub.dart'
    if (dart.library.io) 'attachment_export_native.dart'
    if (dart.library.js_interop) 'attachment_export_web.dart'
    as platform;
import 'chat_attachment.dart';

/// Keep exports inside the chosen folder on Windows, including NTFS streams.
String safeAttachmentExportName(String name) {
  var result = name
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
      .replaceFirst(RegExp(r'[. ]+$'), '');
  if (result.isEmpty) result = 'attachment';
  if (RegExp(
    r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
    caseSensitive: false,
  ).hasMatch(result)) {
    result = '_$result';
  }
  return result;
}

Future<void> exportStreamedAttachment(ChatAttachment attachment) =>
    platform.exportStreamedAttachment(attachment);

/// Compatibility only: legacy peers accept bounded, byte-backed attachments.
Future<ChatAttachment> materializeLegacyAttachment(
  ChatAttachment file, {
  required int maxBytes,
}) async {
  if (file.size > maxBytes || file.size > ChatAttachment.maxBytes) {
    throw const FormatException('Update both apps to send this file size');
  }
  if (!file.isStreamed) return file;
  final bytes = BytesBuilder(copy: false);
  await writeAttachmentToSink(file, (part) async => bytes.add(part));
  return ChatAttachment.fromOwnedBytes(
    name: file.name,
    mimeType: file.mimeType,
    bytes: bytes.takeBytes(),
    caption: file.caption,
    groupId: file.groupId,
    groupIndex: file.groupIndex,
    groupCount: file.groupCount,
  );
}

/// Copies exact bytes with backpressure to an independently opened destination.
Future<void> writeAttachmentToSink(
  ChatAttachment attachment,
  Future<void> Function(Uint8List) write,
) async {
  var written = 0;
  await for (final part in attachment.openRead()) {
    if (part.length > attachment.size - written) {
      throw const FormatException('Attachment source grew during export');
    }
    var offset = 0;
    while (offset < part.length) {
      final end = (offset + 256 * 1024).clamp(0, part.length);
      await write(Uint8List.fromList(part.sublist(offset, end)));
      offset = end;
    }
    written += part.length;
  }
  if (written != attachment.size) {
    throw const FormatException('Attachment source shrank during export');
  }
}
