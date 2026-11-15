import 'dart:async';
import 'dart:typed_data';

import 'package:cht/chat/attachment_files.dart';
import 'package:cht/chat/chat_attachment.dart';
import 'package:cht/chat/widgets/message_composer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'gallery batch stages tiles, keeps failed draft and clears only once queued',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final kinds = <AttachmentPickKind>[];
      var textSends = 0, batches = 0;
      var result = Completer<bool>();
      final controller = TextEditingController(text: 'caption');
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageComposer(
              controller: controller,
              onSend: (_) async {
                textSends++;
                return true;
              },
              onSendBatch: (text, files) {
                batches++;
                expect(text, 'caption');
                expect(files.length, 2);
                return result.future;
              },
              pickAttachments: (kind) async {
                kinds.add(kind);
                return [
                  ChatAttachment(
                    name: 'a.png',
                    mimeType: 'image/png',
                    bytes: Uint8List(1),
                  ),
                  ChatAttachment(
                    name: 'b.mp4',
                    mimeType: 'video/mp4',
                    bytes: Uint8List(1),
                  ),
                ];
              },
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('attach-message')));
      await tester.pumpAndSettle();
      expect(find.text('Camera'), findsNothing);
      await tester.tap(find.text('Gallery'));
      await tester.pumpAndSettle();
      expect(kinds, [AttachmentPickKind.media]);
      expect(find.byKey(const Key('pending-attachment-0')), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const Key('pending-attachment-0'))).width,
        76,
      );
      expect(find.byIcon(Icons.play_circle_fill), findsOneWidget);
      await tester.tap(find.byKey(const Key('send-message')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('send-message')));
      result.complete(false);
      await tester.pump();
      expect(batches, 1);
      expect(textSends, 0);
      expect(controller.text, 'caption');
      expect(find.byKey(const Key('pending-attachment-0')), findsOneWidget);
      result = Completer<bool>();
      await tester.tap(find.byKey(const Key('send-message')));
      await tester.pump();
      result.complete(true);
      await tester.pump();
      expect(controller.text, isEmpty);
      expect(find.byKey(const Key('pending-attachment-0')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('picker stages files and removing a chip prevents sending it', (
    tester,
  ) async {
    final kinds = <AttachmentPickKind>[];
    final sent = <String>[];
    final file = ChatAttachment(
      name: 'notes.txt',
      mimeType: 'text/plain',
      bytes: Uint8List.fromList([1, 2]),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageComposer(
            onSend: (_) async => true,
            onSendAttachment: (attachment) async {
              sent.add(attachment.name);
              return true;
            },
            pickAttachments: (kind) async {
              kinds.add(kind);
              return [file];
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('attach-message')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Files'));
    await tester.pumpAndSettle();
    expect(kinds, [AttachmentPickKind.file]);
    expect(find.text('notes.txt'), findsOneWidget);
    await tester.tap(find.byTooltip('Delete'));
    await tester.pump();
    expect(find.text('notes.txt'), findsNothing);
    await tester.tap(find.byKey(const Key('send-message')));
    await tester.pump();
    expect(sent, isEmpty);
  });

  testWidgets('formatting wraps selection and preview renders markdown', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'hello world');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageComposer(
            controller: controller,
            onSend: (_) async => true,
          ),
        ),
      ),
    );
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 5);
    await tester.tap(find.byKey(const Key('markdown-tools')));
    await tester.pump();
    await tester.tap(find.byTooltip('Bold'));
    await tester.pump();
    expect(controller.text, '**hello** world');
    await tester.ensureVisible(find.byTooltip('Preview'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Preview'));
    await tester.pump();
    expect(find.byKey(const Key('markdown-preview')), findsOneWidget);
    expect(find.textContaining('hello world'), findsOneWidget);
  });

  testWidgets(
    'failed asynchronous send keeps the draft and reenables sending',
    (tester) async {
      final result = Completer<bool>();
      final sent = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageComposer(
              onSend: (text) {
                sent.add(text);
                return result.future;
              },
            ),
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const Key('message-input')),
        'keep this draft',
      );
      await tester.tap(find.byKey(const Key('send-message')));
      await tester.pump();
      expect(find.byKey(const Key('send-progress')), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('message-input')))
            .enabled,
        isFalse,
      );
      result.complete(false);
      await tester.pump();
      expect(sent, ['keep this draft']);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('message-input')))
            .controller!
            .text,
        'keep this draft',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('message-input')))
            .enabled,
        isTrue,
      );
    },
  );
  testWidgets('composer controls and formatting remain usable at phone width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageComposer(
            onSend: (_) async => true,
            onSendAttachment: (_) async => true,
            pickAttachments: (_) async => [],
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('markdown-tools')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('message-input')), 'A message');
    expect(find.byKey(const Key('attach-message')), findsOneWidget);
    expect(find.byKey(const Key('send-message')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('pending send completion does not touch a disposed composer', (
    tester,
  ) async {
    final result = Completer<bool>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: MessageComposer(onSend: (_) => result.future)),
      ),
    );
    await tester.enterText(find.byKey(const Key('message-input')), 'draft');
    await tester.tap(find.byKey(const Key('send-message')));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    result.complete(true);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
