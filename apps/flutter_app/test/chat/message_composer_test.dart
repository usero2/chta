import 'dart:async';

import 'package:cht/chat/attachment_files.dart';
import 'package:cht/chat/chat_attachment.dart';
import 'package:cht/chat/widgets/message_composer.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('tapping Android Send keeps the software keyboard open', (
    tester,
  ) async {
    final result = Completer<bool>();
    final sent = <String>[];
    final input = find.byKey(const Key('message-input'));
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
    await tester.enterText(input, 'First');
    expect(tester.testTextInput.isVisible, isTrue);

    await tester.tap(find.byKey(const Key('send-message')));
    await tester.pump();
    expect(sent, ['First']);
    expect(tester.testTextInput.isVisible, isTrue);
    final editor = tester.widget<EditableText>(find.byType(EditableText));
    expect(editor.focusNode.hasFocus, isTrue);
    tester.testTextInput.enterText('Accidental input while sending');
    await tester.pump();
    expect(editor.controller.text, 'First');

    result.complete(true);
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue);
    expect(editor.controller.text, isEmpty);
    tester.testTextInput.enterText('Next message');
    await tester.pump();
    expect(editor.controller.text, 'Next message');
  }, variant: const TargetPlatformVariant({TargetPlatform.android}));

  testWidgets(
    'desktop Enter sends, leaves Shift+Enter to the input method, and keeps focus',
    (tester) async {
      final sends = <String>[];
      final result = Completer<bool>();
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      final input = find.byKey(const Key('message-input'));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageComposer(
              controller: controller,
              onSend: (text) {
                sends.add(text);
                return result.future;
              },
            ),
          ),
        ),
      );

      await tester.enterText(input, 'first');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      final handled = await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(handled, isFalse);
      expect(sends, isEmpty);
      tester.testTextInput.enterText('first\nsecond');
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(sends, ['first\nsecond']);
      expect(find.byKey(const Key('send-progress')), findsOneWidget);

      result.complete(true);
      await tester.pump();
      expect(controller.text, isEmpty);
      final editor = tester.widget<EditableText>(find.byType(EditableText));
      expect(editor.focusNode.hasFocus, isTrue);
      tester.testTextInput.enterText('next draft');
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
      expect(sends, ['first\nsecond']);
      expect(controller.text, 'next draft');

      // The Windows test key map represents both Enter keys as VK_RETURN.
      await tester.sendKeyEvent(
        defaultTargetPlatform == TargetPlatform.windows
            ? LogicalKeyboardKey.enter
            : LogicalKeyboardKey.numpadEnter,
        physicalKey: PhysicalKeyboardKey.numpadEnter,
      );
      await tester.pump();
      expect(sends, ['first\nsecond', 'next draft']);
      expect(controller.text, isEmpty);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
    }),
  );

  testWidgets('Enter lets an input method finish composing before submitting', (
    tester,
  ) async {
    final sends = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageComposer(
            onSend: (text) async {
              sends.add(text);
              return true;
            },
          ),
        ),
      ),
    );
    await tester.showKeyboard(find.byKey(const Key('message-input')));
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'draft',
        selection: TextSelection.collapsed(offset: 5),
        composing: TextRange(start: 0, end: 5),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(sends, isEmpty);

    tester.testTextInput.enterText('draft');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(sends, ['draft']);
  }, variant: const TargetPlatformVariant({TargetPlatform.windows}));

  testWidgets(
    'Android Attach opens the files picker and stages the selection',
    (tester) async {
      final kinds = <AttachmentPickKind>[];
      final sent = <ChatAttachment>[];
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
              onSendBatch: (_, files) async {
                sent.addAll(files);
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
      expect(kinds, [AttachmentPickKind.file]);
      expect(find.text('notes.txt'), findsOneWidget);
      expect(sent, isEmpty);

      await tester.tap(find.byKey(const Key('send-message')));
      await tester.pumpAndSettle();
      expect(sent, [file]);
      expect(find.text('notes.txt'), findsNothing);
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );

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
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
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
  }, variant: const TargetPlatformVariant({TargetPlatform.windows}));

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
            .widget<IconButton>(find.byKey(const Key('send-message')))
            .onPressed,
        isNull,
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
            .widget<IconButton>(find.byKey(const Key('send-message')))
            .onPressed,
        isNotNull,
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
