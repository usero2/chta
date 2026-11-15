import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'attachment_export.dart';
import 'chat_attachment.dart';

@JS('showSaveFilePicker')
external JSPromise<web.FileSystemFileHandle> _showSaveFilePicker(
  JSObject options,
);

Future<void> exportStreamedAttachment(ChatAttachment attachment) async {
  web.FileSystemFileHandle handle;
  try {
    handle = await _showSaveFilePicker(
      {'suggestedName': attachment.name}.jsify()! as JSObject,
    ).toDart;
  } catch (error) {
    throw UnsupportedError(
      'This browser cannot open a streaming save destination: $error',
    );
  }
  final writable = await handle.createWritable().toDart;
  try {
    await writeAttachmentToSink(attachment, (Uint8List bytes) async {
      await writable.write(bytes.toJS).toDart;
    });
    await writable.close().toDart;
  } catch (_) {
    await writable.abort().toDart;
    rethrow;
  }
}
