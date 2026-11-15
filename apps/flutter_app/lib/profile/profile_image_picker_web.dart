import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

Future<Uint8List?> pickPlatformProfileImage() {
  final result = Completer<Uint8List?>();
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..accept = 'image/png,image/jpeg,image/webp';
  input.onchange = ((web.Event _) {
    final file = input.files?.item(0);
    if (file == null) {
      result.complete(null);
      return;
    }
    final reader = web.FileReader();
    reader.onload = ((web.Event _) {
      final buffer = reader.result! as JSArrayBuffer;
      result.complete(Uint8List.view(buffer.toDart));
    }).toJS;
    reader.onerror = ((web.Event _) {
      result.completeError(StateError('Unable to read the selected image.'));
    }).toJS;
    reader.readAsArrayBuffer(file);
  }).toJS;
  input.click();
  return result.future;
}
