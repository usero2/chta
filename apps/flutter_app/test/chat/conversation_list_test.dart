import 'package:cht/chat/chat_models.dart';
import 'package:cht/chat/widgets/conversation_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Chats shows presence, an unread badge, and filters in place', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bucket = PageStorageBucket();
    final rooms = [
      ConversationView(
        id: 'default',
        title: 'General',
        preview: 'History',
        updatedAtMilliseconds: 0,
        messages: const [],
      ),
      ConversationView(
        id: 'did:cht:alex',
        title: 'Alex',
        preview: 'New photo',
        updatedAtMilliseconds: 1,
        messages: const [],
        online: true,
        unreadCount: 2,
      ),
      ConversationView(
        id: 'group:test',
        title: 'Weekend plans',
        preview: 'Seven o?clock',
        updatedAtMilliseconds: 2,
        messages: const [],
        unreadCount: 105,
      ),
    ];
    Future<void> show() => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PageStorage(
            bucket: bucket,
            child: ConversationList(
              conversations: rooms,
              selectedId: '',
              onSelected: (_) {},
              onActionSelected: (_, _) {},
            ),
          ),
        ),
      ),
    );
    await show();
    await tester.pumpAndSettle();
    final avatar = find.byKey(const Key('conversation-avatar-did:cht:alex'));
    final online = find.byKey(const Key('conversation-online-did:cht:alex'));
    expect(online, findsOneWidget);
    expect(
      tester.getCenter(online).dx,
      greaterThan(tester.getCenter(avatar).dx),
    );
    expect(tester.getCenter(online).dy, lessThan(tester.getCenter(avatar).dy));
    expect(find.text('2'), findsOneWidget);
    expect(find.text('99+'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, '1:1'));
    await tester.pumpAndSettle();
    expect(find.text('Alex'), findsOneWidget);
    expect(find.text('General'), findsNothing);
    expect(find.text('Weekend plans'), findsNothing);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Groups'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await show();
    await tester.pumpAndSettle();
    expect(find.text('Weekend plans'), findsOneWidget);
    expect(find.text('Alex'), findsNothing);
    expect(find.text('General'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
