import 'dart:convert';

import 'package:cht/chat/chat_attachment.dart';
import 'package:cht/chat/media_item.dart';
import 'package:cht/chat/widgets/media_viewer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'video uses full viewport with overlay controls and optional fill',
    (tester) async {
      final fits = <BoxFit>[];
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 320,
            height: 640,
            child: VideoPlaybackViewport(
              videoBuilder: (fit) {
                fits.add(fit);
                return const ColoredBox(
                  key: Key('video-frame'),
                  color: Colors.black,
                );
              },
              controls: const SizedBox(
                key: Key('video-controls'),
                height: 90,
                child: Text('controls'),
              ),
            ),
          ),
        ),
      );
      expect(
        tester.getSize(find.byKey(const Key('video-frame'))),
        tester.getSize(find.byType(VideoPlaybackViewport)),
      );
      expect(fits.last, BoxFit.contain);
      final frame = tester.getRect(find.byKey(const Key('video-frame')));
      expect(
        frame.contains(
          tester.getCenter(find.byKey(const Key('video-controls'))),
        ),
        true,
      );
      await tester.tap(find.byTooltip('Fill screen'));
      await tester.pump();
      expect(fits.last, BoxFit.cover);
      await tester.tap(find.byTooltip('Fit video'));
      await tester.pump();
      expect(fits.last, BoxFit.contain);
      expect(find.byType(AspectRatio), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  for (final size in [const Size(320, 640), const Size(640, 320)]) {
    testWidgets('media viewport fills the complete screen at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jN1kAAAAASUVORK5CYII=',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: MediaViewer(
            items: [
              MediaItem(
                id: 'own-fixture',
                name: 'fixture.png',
                kind: 'image',
                incoming: true,
                loadFile: () async => ChatAttachment(
                  name: 'fixture.png',
                  mimeType: 'image/png',
                  bytes: bytes,
                ),
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byType(PageView)), Offset.zero & size);
      expect(find.byTooltip('Save copy'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
