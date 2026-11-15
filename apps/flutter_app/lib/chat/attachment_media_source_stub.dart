import 'attachment_media_source.dart';
import 'chat_attachment.dart';

Future<AttachmentMediaSource> createAttachmentMediaSource(
  ChatAttachment attachment,
) => Future.error(UnsupportedError('Media preview unavailable'));
