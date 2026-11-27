import 'dart:convert';
import 'dart:typed_data';

import 'package:cht/chat/chat_attachment.dart';
import 'package:cht/chat/media_item.dart';
import 'package:cht/chat/peer_history.dart';
import 'package:cht/chat/widgets/file_transfer_actions.dart';
import 'package:cht/chat/widgets/reply_message_list.dart';
import 'package:cht/chat/widgets/media_album.dart';
import 'package:cht/chat/widgets/media_viewer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jN1kAAAAASUVORK5CYII=',
);
MediaItem item(
  String id,
  int index, {
  String? groupId = 'one',
  bool incoming = true,
}) => MediaItem(
  id: id,
  name: '$id.png',
  kind: 'image',
  incoming: incoming,
  groupId: groupId,
  groupIndex: index,
  groupCount: 3,
  caption: index == 0 ? 'caption' : null,
  loadFile: () async =>
      ChatAttachment(name: '$id.png', mimeType: 'image/png', bytes: png),
);
void main() {
  testWidgets(
    'caption has its own background below the media and no empty footer is added',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 240,
              child: MediaAlbum(items: [item('captioned', 0, incoming: false)]),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final caption = find.byKey(const Key('media-caption'));
      expect(caption, findsOneWidget);
      expect(
        tester.getTopLeft(caption).dy,
        greaterThanOrEqualTo(
          tester
              .getBottomLeft(find.byKey(const Key('album-item-captioned')))
              .dy,
        ),
      );
      expect(
        (tester.widget<Container>(caption).decoration as BoxDecoration).color,
        const Color(0xFF9AE585),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 240,
              child: MediaAlbum(items: [item('plain', 1, incoming: false)]),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('media-caption')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('a single video uses the available tile width', (tester) async {
    final video = MediaItem(
      id: 'single-video',
      name: 'clip.mp4',
      kind: 'video',
      incoming: false,
      loadFile: () async => ChatAttachment(
        name: 'clip.mp4',
        mimeType: 'video/mp4',
        bytes: Uint8List(3),
      ),
      loadThumbnail: () async => null,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 280, child: MediaAlbum(items: [video])),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(const Key('album-item-single-video'))).width,
      greaterThan(250),
    );
    expect(find.byIcon(Icons.play_circle_fill), findsOneWidget);
    expect(find.byTooltip('Save copy'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('video album keeps transfer controls with each file', (
    tester,
  ) async {
    final paused = <String>[];
    final cancelled = <String>[];
    final videos = [
      for (final id in ['clip-a', 'clip-b'])
        MediaItem(
          id: id,
          name: '$id.mp4',
          kind: 'video',
          incoming: false,
          groupIndex: id == 'clip-a' ? 0 : 1,
          loadFile: () async => ChatAttachment(
            name: '$id.mp4',
            mimeType: 'video/mp4',
            bytes: Uint8List(3),
          ),
        ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 232,
            child: MediaAlbum(
              items: videos,
              footerFor: (video) => FileTransferActions(
                message: PeerMessage(
                  id: video.id,
                  text: video.name,
                  incoming: false,
                  status: video.id == 'clip-a'
                      ? DeliveryStatus.delivered
                      : DeliveryStatus.pending,
                  attachment: ChatAttachment(
                    name: video.name,
                    mimeType: 'video/mp4',
                    bytes: Uint8List(3),
                  ),
                ),
                onPause: () async => paused.add(video.id),
                onCancel: () async => cancelled.add(video.id),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final completed = find.byKey(const ReplyMessageAnchorKey('clip-a'));
    final pending = find.byKey(const ReplyMessageAnchorKey('clip-b'));
    final pause = find.byTooltip('Pause transfer');
    final cancel = find.byTooltip('Cancel transfer');
    expect(
      find.descendant(of: completed, matching: find.text('Delivered')),
      findsOneWidget,
    );
    expect(find.descendant(of: completed, matching: cancel), findsNothing);
    expect(
      find.descendant(of: pending, matching: find.text('Queued')),
      findsOneWidget,
    );
    await tester.tap(find.descendant(of: pending, matching: pause));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: pending, matching: cancel));
    expect(paused, ['clip-b']);
    expect(cancelled, ['clip-b']);
    expect(tester.takeException(), isNull);
  });

  test('groups only explicit IDs, media kind and sender direction', () {
    final a = item('a', 0),
        b = item('b', 1),
        c = item('c', 0, incoming: false),
        d = item('d', 0, groupId: null);
    expect(
      groupMedia([
        a,
        c,
        b,
        d,
      ], (item) => item.groupKey).map((g) => g.map((i) => i.id).toList()),
      [
        ['a', 'b'],
        ['c'],
        ['d'],
      ],
    );
  });
  testWidgets(
    'partial album opens cached image, paginates and zooms at narrow width',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final items = [item('a', 0), item('b', 2)];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(width: 210, child: MediaAlbum(items: items)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('caption'), findsOneWidget);
      await tester.tap(find.byKey(const Key('album-item-a')));
      await tester.pumpAndSettle();
      expect(find.byType(MediaViewer), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsWidgets);
      expect(find.byTooltip('Save copy'), findsOneWidget);
      expect(find.text('1 / 2'), findsOneWidget);
      await tester.drag(find.byType(PageView), const Offset(-300, 0));
      await tester.pumpAndSettle();
      expect(find.text('2 / 2'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'unsupported video remains a cached play tile with filename and save',
    (tester) async {
      final video = MediaItem(
        id: 'v',
        name: 'clip.mp4',
        kind: 'video',
        incoming: true,
        loadFile: () async => ChatAttachment(
          name: 'clip.mp4',
          mimeType: 'video/mp4',
          bytes: Uint8List(3),
        ),
        loadThumbnail: () async => null,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(width: 140, child: MediaAlbum(items: [video])),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('clip.mp4'), findsOneWidget);
      expect(find.byIcon(Icons.play_circle_fill), findsOneWidget);
      expect(find.byTooltip('Save copy'), findsOneWidget);
      expect(find.byTooltip('Cached'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
