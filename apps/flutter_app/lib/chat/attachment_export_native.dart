import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

import 'attachment_export.dart';
import 'chat_attachment.dart';

const _androidChannel = MethodChannel('app.cht/platform');

Future<void> exportStreamedAttachment(ChatAttachment attachment) async {
  if (Platform.isAndroid) {
    await _exportAndroid(attachment);
    return;
  }
  final directory = await FilePicker.getDirectoryPath();
  if (directory == null) return;
  final file = File(
    '$directory${Platform.pathSeparator}${safeAttachmentExportName(attachment.name)}',
  );
  try {
    await file.create(exclusive: true);
  } on PathExistsException {
    throw StateError(
      'A file named ${attachment.name} already exists in that folder',
    );
  }
  try {
    final sink = file.openWrite();
    try {
      await writeAttachmentToSink(attachment, (bytes) async {
        sink.add(bytes);
        await sink.flush();
      });
    } finally {
      await sink.close();
    }
  } catch (_) {
    if (await file.exists()) await file.delete();
    rethrow;
  }
}

Future<void> _exportAndroid(ChatAttachment attachment) async {
  final selected = await _androidChannel.invokeMethod<bool>(
    'createAttachmentExport',
    {'name': attachment.name, 'mimeType': attachment.mimeType},
  );
  if (selected != true) return;
  try {
    await writeAttachmentToSink(attachment, (bytes) async {
      await _androidChannel.invokeMethod<void>('writeAttachmentExport', {
        'bytes': bytes,
      });
    });
    await _androidChannel.invokeMethod<void>('finishAttachmentExport');
  } catch (_) {
    try {
      await _androidChannel.invokeMethod<void>('cancelAttachmentExport');
    } catch (_) {}
    rethrow;
  }
}
