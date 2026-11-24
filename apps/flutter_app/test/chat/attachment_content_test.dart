import 'dart:convert';
import 'dart:typed_data';

import 'package:cht/chat/chat_attachment.dart';
import 'package:cht/chat/peer_history.dart';
import 'package:cht/chat/widgets/attachment_content.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'legacy image uses an unframed media preview with its caption below',
    (tester) async {
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jN1kAAAAASUVORK5CYII=',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 240,
              child: AttachmentContent(
                incoming: false,
                attachment: ChatAttachment(
                  name: 'fixture.png',
                  mimeType: 'image/png',
                  bytes: png,
                  caption: '**Caption** below',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('media-caption')), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(const Key('media-caption'))).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(find.byType(Image)).dy),
      );
      expect(find.text('fixture.png'), findsNothing);
      expect(find.byTooltip('Save copy'), findsOneWidget);
      expect(find.byTooltip('Cached'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('generic file keeps its filename and original content controls', (
    tester,
  ) async {
    final file = ChatAttachment(
      name: 'fixture.bin',
      mimeType: 'application/octet-stream',
      bytes: Uint8List(3),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 240,
            child: AttachmentContent(incoming: false, attachment: file),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('fixture.bin'), findsOneWidget);
    expect(find.byKey(const Key('media-caption')), findsNothing);
    expect(find.byTooltip('Save copy'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('cached legacy video reuses its history thumbnail', (
    tester,
  ) async {
    final history = PeerHistory();
    addTearDown(history.dispose);
    await history.load('synthetic-owner');
    final message = PeerMessage(
      id: 'legacy-video',
      text: '',
      incoming: true,
      status: DeliveryStatus.delivered,
      attachment: ChatAttachment(
        name: 'cached.mp4',
        mimeType: 'video/mp4',
        bytes: Uint8List(3),
      ),
    );
    await history.addAttachment('synthetic-peer', message);
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jN1kAAAAASUVORK5CYII=',
    );
    await history.thumbnailFor(message, generate: (_) async => png);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 140,
            child: CachedAttachmentContent(history: history, message: message),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    expect(find.byIcon(Icons.play_circle_fill), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'replacing a legacy video with the same name replaces its cover',
    (tester) async {
      final cover = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jN1kAAAAASUVORK5CYII=',
      );
      Widget card(ChatAttachment file, Uint8List? thumbnail) => MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 140,
            child: AttachmentContent(
              attachment: file,
              incoming: true,
              loadThumbnail: () async => thumbnail,
            ),
          ),
        ),
      );
      await tester.pumpWidget(
        card(
          ChatAttachment(
            name: 'clip.mp4',
            mimeType: 'video/mp4',
            bytes: Uint8List.fromList([1]),
          ),
          cover,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      await tester.pumpWidget(
        card(
          ChatAttachment(
            name: 'clip.mp4',
            mimeType: 'video/mp4',
            bytes: Uint8List.fromList([2]),
          ),
          null,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsNothing);
      expect(find.byIcon(Icons.play_circle_fill), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('legacy video without group metadata exposes a cover card', (
    tester,
  ) async {
    final attachment = ChatAttachment(
      name: 'legacy.mp4',
      mimeType: 'video/mp4',
      bytes: Uint8List(3),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 140,
            child: AttachmentContent(
              attachment: attachment,
              incoming: true,
              loadThumbnail: () async => base64Decode(
                'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jN1kAAAAASUVORK5CYII=',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.play_circle_fill), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('legacy.mp4'), findsOneWidget);
    expect(find.byTooltip('Save copy'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('file attachment offers a download within a narrow bubble', (
    tester,
  ) async {
    final attachment = ChatAttachment(
      name: 'notes.txt',
      mimeType: 'text/plain',
      bytes: Uint8List(12),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 140,
              child: AttachmentContent(attachment: attachment, incoming: true),
            ),
          ),
        ),
      ),
    );
    expect(find.text('notes.txt'), findsOneWidget);
    expect(find.byTooltip('Save copy'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('media controls expose playback and seek actions', (
    tester,
  ) async {
    var toggled = false;
    Duration? sought;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AttachmentMediaControls(
            playing: Stream.value(false),
            position: Stream.value(const Duration(seconds: 5)),
            duration: Stream.value(const Duration(seconds: 10)),
            onToggle: () {
              toggled = true;
            },
            onSeek: (value) {
              sought = value;
            },
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('0:05 / 0:10'), findsOneWidget);
    await tester.tap(find.byTooltip('Play'));
    expect(toggled, isTrue);
    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChanged!(8000);
    expect(sought, const Duration(seconds: 8));
  });
}
