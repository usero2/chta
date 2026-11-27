import 'package:cht/chat/widgets/reply_message_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'highlighting a visible reply target keeps message content built',
    (tester) async {
      final builds = <int, int>{};
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReplyMessageList(
              storageId: 'reply-highlight',
              rows: const [
                ['original'],
                ['reply'],
              ],
              padding: EdgeInsets.zero,
              itemBuilder: (context, index, jumpTo) {
                builds.update(index, (count) => count + 1, ifAbsent: () => 1);
                return index == 0
                    ? const Text('Original text')
                    : TextButton(
                        onPressed: () => jumpTo('original'),
                        child: const Text('Quoted message'),
                      );
              },
            ),
          ),
        ),
      );
      final before = Map.of(builds);
      await tester.tap(find.text('Quoted message'));
      await tester.pumpAndSettle();
      expect(builds, before);
      final selected = find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.selected == true,
      );
      expect(
        find.descendant(of: selected, matching: find.text('Original text')),
        findsOneWidget,
      );
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.pumpAndSettle();
      expect(selected, findsNothing);
      expect(builds, before);
    },
  );
}
