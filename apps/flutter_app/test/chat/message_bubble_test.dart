import 'package:cht/chat/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('message metadata stays alongside bubble on a narrow screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final old = DateTime(2024, 1, 2, 3, 4, 5, 6).millisecondsSinceEpoch;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            text: 'A long message that wraps naturally on a narrow device.',
            incoming: true,
            sentAtMilliseconds: old,
            receivedAtMilliseconds: old,
            bubbleKey: const Key('bubble'),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('2024-01-02 03:04:05.006'), findsOneWidget);
    expect(find.text('03:04:05.006'), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const Key('bubble'))).dx,
      lessThan(tester.getTopLeft(find.text('03:04:05.006')).dx),
    );
    expect(find.byIcon(Icons.north_rounded), findsOneWidget);
    expect(find.byIcon(Icons.south_rounded), findsOneWidget);
  });

  testWidgets('markdown renders formatting and image alt text', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            text:
                '**bold**\n\n- item\n\n![safe alt](https://example.com/x.png)',
            incoming: false,
            sentAtMilliseconds: null,
            receivedAtMilliseconds: null,
          ),
        ),
      ),
    );
    expect(find.textContaining('bold'), findsOneWidget);
    expect(find.textContaining('item'), findsOneWidget);
    expect(find.text('safe alt'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('long code and tables fit a narrow message', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            text: '```\nabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz\n```\n\n| First | Second |\n| --- | --- |\n| longlonglonglong | anotherlonglonglong |',
            incoming: false,
            sentAtMilliseconds: 1,
            receivedAtMilliseconds: 2,
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
