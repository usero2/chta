import 'chat_attachment.dart';
import 'attachment_media_source_stub.dart'
    if (dart.library.io) 'attachment_media_source_native.dart'
    if (dart.library.js_interop) 'attachment_media_source_web.dart'
    as platform;

abstract class AttachmentMediaSource {
  String get uri;
  Future<void> dispose();
}

Future<AttachmentMediaSource> createAttachmentMediaSource(
  ChatAttachment attachment,
) => platform.createAttachmentMediaSource(attachment);
