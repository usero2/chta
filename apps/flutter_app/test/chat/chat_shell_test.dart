import 'dart:async';

import 'package:cht/app.dart';
import 'package:cht/chat/chat_controller.dart';
import 'package:cht/chat/chat_shell.dart';
import 'package:cht/chat/chat_models.dart';
import 'package:cht/chat/widgets/conversation_list.dart';
import 'package:cht/core/core_bridge.dart';
import 'package:cht/routing/app_router.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('standalone desktop sidebar uses the normal logo text style', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 320,
            child: ConversationList(
              conversations: const [],
              selectedId: '',
              onSelected: (_) {},
            ),
          ),
        ),
      ),
    );
    final logo = find.descendant(
      of: find.text('chta'),
      matching: find.byType(RichText),
    );
    expect(
      tester.widget<RichText>(logo).text.style?.decoration,
      anyOf(isNull, TextDecoration.none),
    );
  });

  testWidgets(
    'an empty persisted room list stays usable on phone and desktop',
    (tester) async {
      for (final width in [320.0, 1200.0]) {
        tester.view.physicalSize = Size(width, 720);
        tester.view.devicePixelRatio = 1;
        final bridge = _EmptyCoreBridge();
        await tester.pumpWidget(
          MaterialApp(
            home: ChatShell(
              controller: ChatController(coreBridge: bridge),
              coreBridge: bridge,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Unable to load chats'), findsNothing);
        expect(find.byType(ChatShell), findsOneWidget);
        expect(find.byKey(const Key('chat-room')), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    },
  );
  testWidgets('chat shell forwards the create-group action', (tester) async {
    var requested = false;
    final bridge = _FakeCoreBridge();
    await tester.pumpWidget(
      MaterialApp(
        home: ChatShell(
          controller: ChatController(
            coreBridge: bridge,
            nowMilliseconds: () => 1700000400000,
          ),
          coreBridge: bridge,
          onCreateGroup: () => requested = true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('create-group-button')), findsOneWidget);
    await tester.tap(find.byKey(const Key('create-group-button')));
    expect(requested, isTrue);
  });

  testWidgets('shows loading until the Rust snapshot arrives', (tester) async {
    final bridge = _FakeCoreBridge()..loadCompleter = Completer<ChatSnapshot>();
    await tester.pumpWidget(_app(bridge));

    expect(find.text('Loading chats…'), findsOneWidget);

    bridge.loadCompleter!.complete(_snapshot());
    await tester.pump();
    expect(find.byKey(const Key('chat-room')), findsOneWidget);
  });

  testWidgets('desktop shell shows Rust-provided rooms and both panes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_app(_FakeCoreBridge()));
    await tester.pump();
    await tester.pump();

    expect(find.text('chta'), findsOneWidget);
    expect(find.text('General'), findsWidgets);
    expect(find.text('Web-first foundation'), findsWidgets);
    expect(find.byKey(const Key('conversation-list')), findsOneWidget);
    expect(find.byKey(const Key('chat-room')), findsOneWidget);
    expect(find.text('Core cht-core@0.1.0'), findsNothing);
  });

  testWidgets('snapshot failure is shown without fabricated rooms', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(_FakeCoreBridge()..loadError = StateError('IndexedDB unavailable')),
    );
    await tester.pump();

    expect(find.text('Unable to load chats'), findsOneWidget);
    expect(find.byKey(const Key('chat-room')), findsNothing);
  });

  testWidgets('composer waits for Rust and clears after accepted send', (
    tester,
  ) async {
    final bridge = _FakeCoreBridge();
    await tester.pumpWidget(_app(bridge));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('message-input')), 'hello');

    bridge.sendCompleter = Completer<ChatSnapshot>();
    await tester.tap(find.byKey(const Key('send-message')));
    await tester.pump();

    expect(find.byKey(const Key('send-progress')), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('message-input')))
          .controller!
          .text,
      'hello',
    );

    bridge.sendCompleter!.complete(_snapshot(message: 'hello'));
    await tester.pump();
    expect(
      find.descendant(
        of: find.byKey(const Key('chat-room')),
        matching: find.text('hello'),
      ),
      findsOneWidget,
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('message-input')))
          .controller!
          .text,
      isEmpty,
    );
  });

  testWidgets('narrow layout opens a room and returns to the chat list', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_app(_FakeCoreBridge()));
    await tester.pump();
    expect(find.byKey(const Key('conversation-list')), findsOneWidget);
    expect(find.byKey(const Key('chat-room')), findsNothing);

    await tester.tap(find.byKey(const Key('conversation-general')));
    await tester.pump();
    expect(find.byKey(const Key('chat-room')), findsOneWidget);

    await tester.tap(find.byKey(const Key('back-to-conversations')));
    await tester.pump();
    expect(find.byKey(const Key('conversation-list')), findsOneWidget);
  });
}

Widget _app(_FakeCoreBridge bridge) => ChtApp(
  controller: ChatController(
    coreBridge: bridge,
    nowMilliseconds: () => 1700000400000,
  ),
  coreBridge: bridge,
  router: AppRouter(initialPath: '/chats'),
);

ChatSnapshot _snapshot({String? message}) {
  final messages = <MessageView>[
    const MessageView(
      id: 1,
      text: 'Web-first foundation',
      sentAtMilliseconds: 1700000000000,
      incoming: true,
    ),
    if (message != null)
      MessageView(
        id: 3,
        text: message,
        sentAtMilliseconds: 1700000400000,
        incoming: false,
      ),
  ];
  return ChatSnapshot(
    schemaVersion: 1,
    conversations: [
      ConversationView(
        id: 'general',
        title: 'General',
        preview: message ?? 'Web-first foundation',
        updatedAtMilliseconds: message == null ? 1700000000000 : 1700000400000,
        messages: messages,
      ),
      ConversationView(
        id: 'design',
        title: 'Design',
        preview: 'Adapt the chat experience',
        updatedAtMilliseconds: 1699999900000,
        messages: const [
          MessageView(
            id: 2,
            text: 'Adapt the chat experience',
            sentAtMilliseconds: 1699999900000,
            incoming: true,
          ),
        ],
      ),
    ],
  );
}

class _FakeCoreBridge implements CoreBridge {
  Completer<ChatSnapshot>? loadCompleter;
  Completer<ChatSnapshot>? sendCompleter;
  Object? loadError;

  @override
  Future<ChatSnapshot> loadSnapshot() async {
    if (loadError case final error?) throw error;
    return loadCompleter?.future ?? _snapshot();
  }

  @override
  Future<ChatSnapshot> sendText(
    String conversationId,
    String text,
    int sentAtMilliseconds,
  ) => sendCompleter?.future ?? Future.value(_snapshot(message: text.trim()));

  @override
  Future<String> version() async => 'cht-core@0.1.0';
}

class _EmptyCoreBridge extends _FakeCoreBridge {
  @override
  Future<ChatSnapshot> loadSnapshot() async =>
      ChatSnapshot(schemaVersion: 1, conversations: const []);
}
