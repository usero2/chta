import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'attachment_media_source.dart';
import 'chat_attachment.dart';

Future<AttachmentMediaSource> createAttachmentMediaSource(
  ChatAttachment attachment,
) async {
  if (attachment.isStreamed) {
    throw UnsupportedError('Streamed media preview is unavailable');
  }
  final root = await getTemporaryDirectory();
  final directory = await root.createTemp('cht-preview-');
  final extension = attachment.name.split('.').last;
  final suffix = RegExp(r'^[a-zA-Z0-9]{1,10}$').hasMatch(extension)
      ? extension
      : 'bin';
  final file = File(
    '${directory.path}${Platform.pathSeparator}preview.$suffix',
  );
  try {
    await file.writeAsBytes(attachment.bytes, flush: true);
    return _NativeSource(file, directory);
  } catch (_) {
    if (await file.exists()) await file.delete();
    if (await directory.exists()) await directory.delete();
    rethrow;
  }
}

class _NativeSource implements AttachmentMediaSource {
  _NativeSource(this.file, this.directory);
  final File file;
  final Directory directory;
  @override
  String get uri => file.uri.toString();
  @override
  Future<void> dispose() async {
    if (await file.exists()) await file.delete();
    if (await directory.exists()) await directory.delete();
  }
}
