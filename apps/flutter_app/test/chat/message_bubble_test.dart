import 'package:cht/chat/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('text over 20 lines starts collapsed and can be expanded', (
    tester,
  ) async {
    final firstTwenty = List.generate(20, (i) => 'Line ${i + 1}').join('\n');
    final full = '$firstTwenty\r\nLast line';
    Widget page(String text) => MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: MessageBubble(
            text: text,
            incoming: true,
            sentAtMilliseconds: null,
            receivedAtMilliseconds: null,
          ),
        ),
      ),
    );
    String body() =>
        tester.widget<ChatMarkdown>(find.byType(ChatMarkdown)).text;
    final readMore = find.widgetWithText(TextButton, 'Read more');
    await tester.pumpWidget(page('$firstTwenty\n'));
    expect(readMore, findsNothing);
    await tester.pumpWidget(page(full));
    expect(body(), firstTwenty);
    expect(
      tester.getTopLeft(readMore).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(find.byType(ChatMarkdown)).dy),
    );
    await tester.tap(readMore);
    await tester.pumpAndSettle();
    expect(body(), full);
    await tester.tap(find.widgetWithText(TextButton, 'Show less'));
    await tester.pumpAndSettle();
    expect(body(), firstTwenty);
  });

  testWidgets(
    'visual media has no colored padding while text keeps its bubble',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                MessageBubble(
                  text: '',
                  incoming: false,
                  sentAtMilliseconds: 1,
                  receivedAtMilliseconds: 2,
                  media: true,
                  bubbleKey: Key('media-bubble'),
                  content: SizedBox(width: 160, height: 120),
                ),
                MessageBubble(
                  text: 'Text stays framed',
                  incoming: false,
                  sentAtMilliseconds: 1,
                  receivedAtMilliseconds: 2,
                  bubbleKey: Key('text-bubble'),
                ),
              ],
            ),
          ),
        ),
      );
      final media = tester.widget<Container>(
        find.byKey(const Key('media-bubble')),
      );
      expect(media.padding, EdgeInsets.zero);
      expect(media.decoration, isNull);
      final text = tester.widget<Container>(
        find.byKey(const Key('text-bubble')),
      );
      expect((text.decoration as BoxDecoration).color, const Color(0xFF9AE585));
      expect(tester.takeException(), isNull);
    },
  );
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
