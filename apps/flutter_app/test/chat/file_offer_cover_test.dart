import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cht/chat/attachment_source.dart';
import 'package:cht/chat/chat_attachment.dart';
import 'package:cht/chat/file_offer_cover.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'noisy image produces a small JPEG cover with the same aspect ratio',
    () async {
      final pixels = image.Image(width: 300, height: 150);
      final noise = Random(42);
      for (final pixel in pixels) {
        pixel.setRgb(
          noise.nextInt(256),
          noise.nextInt(256),
          noise.nextInt(256),
        );
      }
      final cover = await buildFileOfferCover(
        ChatAttachment(
          name: 'photo.png',
          mimeType: 'image/png',
          bytes: image.encodePng(pixels),
        ),
      );

      expect(cover, isNotNull);
      final bytes = base64Decode(cover!);
      expect(bytes.length, lessThanOrEqualTo(5 * 1024));
      final jpeg = image.decodeJpg(bytes)!;
      expect(jpeg.width, lessThan(300));
      expect(jpeg.width, jpeg.height * 2);
      expect(decodeFileOfferCover(cover), bytes);
    },
  );

  test(
    'a small source-backed image can be previewed using its stream',
    () async {
      final bytes = image.encodePng(image.Image(width: 60, height: 40));
      final cover = await buildFileOfferCover(
        ChatAttachment.fromSource(
          name: 'photo.png',
          mimeType: 'image/png',
          source: _PreviewSource(bytes.length, bytes),
        ),
      );
      expect(cover, isNotNull);
    },
  );

  test(
    'an oversized source-backed image is skipped without opening it',
    () async {
      final source = _PreviewSource(
        ChatAttachment.maxStreamedBytes,
        Uint8List(0),
      );
      final cover = await buildFileOfferCover(
        ChatAttachment.fromSource(
          name: 'large.png',
          mimeType: 'image/png',
          source: source,
        ),
      );
      expect(cover, isNull);
      expect(source.opened, isFalse);
    },
  );

  test(
    'a video MIME type cannot turn a remote playlist into a preview',
    () async {
      final playlist = Uint8List.fromList(utf8.encode(
        '#EXTM3U\n#EXTINF:1,\nhttps://example.test/video.ts\n',
      ));
      final cover = await buildFileOfferCover(
        ChatAttachment(
          name: 'movie.mp4',
          mimeType: 'video/mp4',
          bytes: playlist,
        ),
      );
      expect(cover, isNull);
      final cached = _PreviewSource(playlist.length, playlist);
      expect(await buildFileOfferCover(ChatAttachment.fromSource(
        name: 'cached.mp4',
        mimeType: 'video/mp4',
        source: cached,
      )), isNull);
      expect(cached.opened, isTrue);
    },
  );

  test('cover receiver rejects malformed or unsafe image data', () {
    final notJpeg = image.encodePng(image.Image(width: 32, height: 16));
    final tooWideJpeg = image.encodeJpg(image.Image(width: 1000, height: 1));
    expect(decodeFileOfferCover('file:///photo.jpg'), isNull);
    expect(decodeFileOfferCover(base64Encode(notJpeg)), isNull);
    expect(decodeFileOfferCover(base64Encode(tooWideJpeg)), isNull);
    expect(decodeFileOfferCover(base64Encode(Uint8List(5 * 1024 + 1))), isNull);
  });
}

class _PreviewSource implements AttachmentSource {
  _PreviewSource(this.length, this.bytes);

  @override
  final int length;
  final Uint8List bytes;
  bool opened = false;

  @override
  String get key => 'test-preview';

  @override
  Stream<List<int>> openRead({int start = 0, int? end}) async* {
    opened = true;
    yield Uint8List.sublistView(bytes, start, end);
  }
}
