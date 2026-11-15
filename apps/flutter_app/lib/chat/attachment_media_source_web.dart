import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'attachment_media_source.dart';
import 'chat_attachment.dart';

Future<AttachmentMediaSource> createAttachmentMediaSource(
  ChatAttachment attachment,
) async {
  if (attachment.isStreamed) {
    throw UnsupportedError('Streamed media preview is unavailable');
  }
  final blob = web.Blob(
    [attachment.bytes.toJS].toJS,
    web.BlobPropertyBag(type: attachment.mimeType),
  );
  return _WebSource(web.URL.createObjectURL(blob));
}

class _WebSource implements AttachmentMediaSource {
  _WebSource(this.uri);
  @override
  final String uri;
  @override
  Future<void> dispose() async => web.URL.revokeObjectURL(uri);
}
