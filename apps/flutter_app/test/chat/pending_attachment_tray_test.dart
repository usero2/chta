import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cht/chat/chat_attachment.dart';
import 'package:cht/chat/widgets/pending_attachment_tray.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('staged videos expose a cover preview without playback', (
    tester,
  ) async {
    final video = ChatAttachment(
      name: 'staged.mp4',
      mimeType: 'video/mp4',
      bytes: Uint8List(3),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PendingAttachmentTray(
            files: [video],
            onRemove: (_) {},
            generateThumbnail: (_) async => base64Decode(
              'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jN1kAAAAASUVORK5CYII=',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pending-video-cover')), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(find.byIcon(Icons.play_circle_fill), findsOneWidget);
    expect(find.byTooltip('Delete'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'staged cover survives rebuilds and failed decoding keeps delete available',
    (tester) async {
      final video = ChatAttachment(
        name: 'unsupported.mp4',
        mimeType: 'video/mp4',
        bytes: Uint8List(3),
      );
      final decode = Completer<Uint8List?>();
      var requests = 0;
      int? removed;
      Widget tray() => MaterialApp(
        home: Scaffold(
          body: PendingAttachmentTray(
            files: [video],
            onRemove: (index) => removed = index,
            generateThumbnail: (_) {
              requests++;
              return decode.future;
            },
          ),
        ),
      );
      await tester.pumpWidget(tray());
      await tester.pumpWidget(tray());
      decode.completeError(StateError('unsupported codec'));
      await tester.pumpAndSettle();
      expect(requests, 1);
      expect(find.text('unsupported.mp4'), findsOneWidget);
      expect(find.byIcon(Icons.play_circle_fill), findsOneWidget);
      await tester.tap(find.byTooltip('Delete'));
      expect(removed, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
