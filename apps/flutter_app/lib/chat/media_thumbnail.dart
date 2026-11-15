import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:media_kit/media_kit.dart';

import 'attachment_media_source.dart';
import 'chat_attachment.dart';

Future<void> _thumbnailQueue = Future.value();

/// Decode only app-owned cached media; serialize players to bound memory use.
Future<Uint8List?> createMediaThumbnail(ChatAttachment file) {
  final result = _thumbnailQueue.then((_) => _create(file));
  _thumbnailQueue = result.then((_) {}, onError: (Object _) {});
  return result;
}

Future<Uint8List?> _create(ChatAttachment file) async {
  if (file.isStreamed) return null;
  if (file.kind != 'video') return null;
  AttachmentMediaSource? source;
  Player? player;
  ui.Codec? codec;
  ui.Image? image;
  ui.ImmutableBuffer? buffer;
  try {
    source = await createAttachmentMediaSource(file);
    MediaKit.ensureInitialized();
    player = Player(configuration: const PlayerConfiguration(vo: 'null'));
    // Native players disable video decoding until a VideoController attaches.
    // This offscreen player has no controller; select the track explicitly.
    if (!kIsWeb) await player.setVideoTrack(VideoTrack.auto());
    await player
        .open(Media(source.uri), play: false)
        .timeout(const Duration(seconds: 5));
    if ((player.state.width ?? 0) == 0) {
      await player.stream.width
          .firstWhere((width) => (width ?? 0) > 0)
          .timeout(const Duration(seconds: 5));
    }
    if (player.state.buffering) {
      await player.stream.buffering
          .firstWhere((buffering) => !buffering)
          .timeout(const Duration(seconds: 5));
    }
    final shot = await player
        .screenshot(format: 'image/png')
        .timeout(const Duration(seconds: 5));
    if (shot == null) return null;
    buffer = await ui.ImmutableBuffer.fromUint8List(shot);
    final ownedBuffer = buffer;
    buffer = null;
    codec = await ui.instantiateImageCodecWithSize(
      ownedBuffer,
      getTargetSize: (width, height) {
        final scale = 480 / (width > height ? width : height);
        return ui.TargetImageSize(
          width: scale < 1 ? (width * scale).round().clamp(1, 480) : width,
          height: scale < 1 ? (height * scale).round().clamp(1, 480) : height,
        );
      },
    );
    image = (await codec.getNextFrame()).image;
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final bytes = data?.buffer.asUint8List();
    return bytes != null && bytes.length <= 256 * 1024 ? bytes : null;
  } catch (_) {
    return null;
  } finally {
    image?.dispose();
    codec?.dispose();
    buffer?.dispose();
    try {
      await player?.dispose();
    } finally {
      await source?.dispose();
    }
  }
}
