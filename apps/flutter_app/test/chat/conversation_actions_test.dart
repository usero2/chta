import 'package:cht/chat/chat_models.dart';
import 'package:cht/chat/widgets/conversation_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'initial rooms offer deletion without a fabricated contact detail',
    (tester) async {
      String? deleted;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConversationList(
              conversations: [
                ConversationView(
                  id: 'general',
                  title: 'General',
                  preview: 'hello',
                  updatedAtMilliseconds: 0,
                  messages: const [],
                ),
              ],
              selectedId: 'general',
              onSelected: (_) {},
              onActionSelected: (id, action) {
                if (action == ConversationAction.delete) deleted = id;
              },
            ),
          ),
        ),
      );
      expect(
        find.byKey(const Key('conversation-menu-general')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('conversation-menu-general')));
      await tester.pumpAndSettle();
      expect(find.text('Contact details'), findsNothing);
      await tester.tap(find.text('Delete chat'));
      await tester.pumpAndSettle();
      expect(deleted, 'general');
    },
  );
  testWidgets('phone room menu opens on tap or hold without opening the chat', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const id = 'did:cht:friend';
    var opened = false;
    final actions = <ConversationAction>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConversationList(
            conversations: [
              ConversationView(
                id: id,
                title: 'Ton',
                preview: 'Offline',
                updatedAtMilliseconds: 0,
                messages: const [],
              ),
            ],
            selectedId: '',
            onSelected: (_) => opened = true,
            onActionSelected: (id, action) => actions.add(action),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('conversation-menu-$id')));
    await tester.pumpAndSettle();
    expect(find.text('Contact details'), findsOneWidget);
    await tester.tap(find.text('Contact details'));
    await tester.pumpAndSettle();
    expect(actions, [ConversationAction.details]);
    await tester.longPress(find.byKey(const Key('conversation-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete chat'));
    await tester.pumpAndSettle();
    expect(actions, [ConversationAction.details, ConversationAction.delete]);
    expect(opened, isFalse);
    expect(tester.takeException(), isNull);
  });
}
