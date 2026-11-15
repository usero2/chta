import 'chat_attachment.dart';

Future<void> exportStreamedAttachment(ChatAttachment attachment) async =>
    throw UnsupportedError(
      'Streaming file export is unavailable on this platform',
    );
