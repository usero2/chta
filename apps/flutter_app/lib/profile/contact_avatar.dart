import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as image;

const maxContactAvatarBytes = 1024;

String createContactAvatar(Uint8List? source) {
  if (source == null) return '';
  final decoded = image.decodeImage(source);
  if (decoded == null) return '';
  for (final size in [48, 32, 24]) {
    final thumbnail = image.copyResize(decoded, width: size, height: size);
    for (final quality in [60, 35, 15]) {
      final bytes = image.encodeJpg(thumbnail, quality: quality);
      if (bytes.length <= maxContactAvatarBytes) return base64Encode(bytes);
    }
  }
  return '';
}
