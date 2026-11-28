import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:image/image.dart' as image;

import 'chat_attachment.dart';
import 'media_thumbnail.dart';

const maxFileOfferCoverBytes = 5 * 1024;
const maxFileOfferCoverEncodedLength = ((maxFileOfferCoverBytes + 2) ~/ 3) * 4;
const _maxCoverEdge = 144;
const _maxInputPixels = 40 * 1000 * 1000;

/// Produce an optional JPEG preview from local media without loading large files.
Future<String?> buildFileOfferCover(ChatAttachment attachment) async {
  if (attachment.size == 0 || attachment.size > ChatAttachment.relayMaxBytes) {
    return null;
  }
  try {
    switch (attachment.kind) {
      case 'image':
        final bytes = await _mediaBytes(attachment);
        return bytes == null ? null : await encodePreviewJpeg(bytes);
      case 'video':
        final bytes = await _mediaBytes(attachment);
        if (bytes == null || !_isVideoContainer(bytes)) return null;
        // Group caches expose even small completed files as streams. Give the
        // local-only decoder an owned copy only within the existing size cap.
        final media = attachment.isStreamed
            ? ChatAttachment.fromOwnedBytes(
                name: attachment.name,
                mimeType: attachment.mimeType,
                bytes: bytes,
              )
            : attachment;
        final thumbnail = await createMediaThumbnail(
          media,
          localOnly: true,
        );
        return thumbnail == null ? null : await encodePreviewJpeg(thumbnail);
      default:
        return null;
    }
  } catch (_) {
    // Missing sources and unsupported media still work as file offers.
    return null;
  }
}

/// Bound both compressed bytes and decoded dimensions on the receiving device.
Uint8List? decodeFileOfferCover(String? cover) {
  if (cover == null || cover.length > maxFileOfferCoverEncodedLength) {
    return null;
  }
  try {
    final bytes = base64Decode(cover);
    if (bytes.isEmpty || bytes.length > maxFileOfferCoverBytes) return null;
    final info = image.JpegDecoder().startDecode(bytes);
    if (info == null ||
        info.width <= 0 ||
        info.height <= 0 ||
        info.width > _maxCoverEdge ||
        info.height > _maxCoverEdge) {
      return null;
    }
    return bytes;
  } catch (_) {
    return null;
  }
}

Future<Uint8List?> _mediaBytes(ChatAttachment attachment) async {
  if (!attachment.isStreamed) return attachment.bytes;
  final size = attachment.size;
  final bytes = BytesBuilder();
  await for (final chunk in attachment.openRead(end: size)) {
    if (chunk.length > size - bytes.length) return null;
    bytes.add(chunk);
  }
  return bytes.length == size ? bytes.takeBytes() : null;
}

bool _isVideoContainer(Uint8List bytes) {
  if (bytes.length < 12) return false;
  final header = ByteData.sublistView(bytes);
  // Accept binary containers only. Playlists can refer to external media.
  return header.getUint32(4) == 0x66747970 || // ISO BMFF (MP4 and MOV)
      header.getUint32(0) == 0x1a45dfa3 || // EBML (WebM and Matroska)
      header.getUint32(0) == 0x4f676753 || // Ogg
      (header.getUint32(0) == 0x52494646 &&
          header.getUint32(8) == 0x41564920); // AVI
}

Future<String?> encodePreviewJpeg(
  Uint8List bytes, {
  int maxBytes = maxFileOfferCoverBytes,
  int maxPixels = _maxInputPixels,
}) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? frame;
  try {
    final int width, height;
    if (kIsWeb) {
      // On web, ImageDescriptor cannot report encoded image dimensions.
      final info = image.findDecoderForData(bytes)?.startDecode(bytes);
      if (info == null) return null;
      width = info.width;
      height = info.height;
    } else {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      width = descriptor.width;
      height = descriptor.height;
    }
    if (width <= 0 || height <= 0 || width * height > maxPixels) {
      return null;
    }
    final scale = math.min(1.0, _maxCoverEdge / math.max(width, height));
    final targetWidth = math.max(1, (width * scale).round());
    final targetHeight = math.max(1, (height * scale).round());
    codec = descriptor == null
        ? await ui.instantiateImageCodec(
            bytes,
            targetWidth: targetWidth,
            targetHeight: targetHeight,
          )
        : await descriptor.instantiateCodec(
            targetWidth: targetWidth,
            targetHeight: targetHeight,
          );
    frame = (await codec.getNextFrame()).image;
    final rgba = await frame.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (rgba == null) return null;
    final raster = image.Image.fromBytes(
      width: frame.width,
      height: frame.height,
      bytes: rgba.buffer,
      bytesOffset: rgba.offsetInBytes,
      numChannels: 4,
    );
    for (final edge in [_maxCoverEdge, 96, 64]) {
      final thumbnail = _resize(raster, edge);
      for (final quality in [70, 48, 30]) {
        final cover = image.encodeJpg(thumbnail, quality: quality);
        if (cover.length <= maxBytes) return base64Encode(cover);
      }
    }
    return null;
  } finally {
    frame?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}

image.Image _resize(image.Image raster, int edge) {
  if (math.max(raster.width, raster.height) <= edge) return raster;
  final scale = edge / math.max(raster.width, raster.height);
  return image.copyResize(
    raster,
    width: math.max(1, (raster.width * scale).round()),
    height: math.max(1, (raster.height * scale).round()),
    interpolation: image.Interpolation.average,
  );
}
