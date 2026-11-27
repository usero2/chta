import 'dart:io';
import 'dart:ui' as ui;

import 'package:cht/chat/chat_attachment.dart';
import 'package:cht/chat/file_offer_cover.dart';
import 'package:cht/chat/media_thumbnail.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

// Opt in with synthetic fixture and packaged libmpv paths; never reads user data.
const fixturePath = String.fromEnvironment('THUMBNAIL_VIDEO_FIXTURE');
const libmpvPath = String.fromEnvironment('THUMBNAIL_LIBMPV');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('paused native video produces a bounded PNG cover and cleans temporary media', () async {
    final scratch = await Directory.systemTemp.createTemp(
      'cht-thumbnail-test-',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async =>
              call.method == 'getTemporaryDirectory' ? scratch.path : null,
        );
    try {
      MediaKit.ensureInitialized(libmpv: libmpvPath);
      final video = ChatAttachment(
        name: 'synthetic.mp4',
        mimeType: 'video/mp4',
        bytes: await File(fixturePath).readAsBytes(),
      );
      final bytes = await createMediaThumbnail(video);
      expect(
        bytes,
        isNotNull,
        reason: 'a paused decoder must select a video track',
      );
      expect(bytes!.length, lessThanOrEqualTo(256 * 1024));
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      expect(frame.image.width, inInclusiveRange(1, 480));
      expect(frame.image.height, inInclusiveRange(1, 480));
      frame.image.dispose();
      codec.dispose();
      expect(await scratch.list().toList(), isEmpty);

      final offerCover = decodeFileOfferCover(await buildFileOfferCover(video));
      expect(offerCover, isNotNull);
      expect(offerCover!.length, lessThanOrEqualTo(5 * 1024));
      expect(await scratch.list().toList(), isEmpty);
    } finally {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            null,
          );
      await scratch.delete(recursive: true);
    }
  }, skip: fixturePath.isEmpty || libmpvPath.isEmpty);
}
