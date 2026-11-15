import 'package:cht/chat/chat_controller.dart';
import 'package:cht/chat/chat_models.dart';
import 'package:cht/core/core_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dart:typed_data';
import 'dart:async';

import 'package:cht/chat/chat_attachment.dart';

void main() {
  test(
    'deleting all initial rooms keeps a valid empty snapshot after reload',
    () async {
      final bridge = _FakeCoreBridge(_snapshot());
      final controller = ChatController(coreBridge: bridge);
      await controller.initialize();
      expect(await controller.deleteConversation('general'), isTrue);
      expect(controller.selectedConversation.id, 'design');
      expect(await controller.deleteConversation('design'), isTrue);
      expect(controller.conversations, isEmpty);
      expect(controller.status, ChatControllerStatus.ready);
      expect(await controller.sendText('no room'), isFalse);
      await controller.reload();
      expect(controller.status, ChatControllerStatus.ready);
      expect(controller.conversations, isEmpty);
    },
  );
  test('a late send snapshot cannot bring back a deleted room', () async {
    final initial = _snapshot(), bridge = _FakeCoreBridge(_snapshot());
    final controller = ChatController(coreBridge: bridge);
    await controller.initialize();
    bridge.sendGate = Completer<ChatSnapshot>();
    final sending = controller.sendText('late');
    await controller.deleteConversation('general');
    bridge.sendGate!.complete(initial);
    await sending;
    expect(controller.conversations.map((c) => c.id), ['design']);
  });
  late _FakeCoreBridge bridge;
  late ChatController controller;

  setUp(() {
    bridge = _FakeCoreBridge(_snapshot());
    controller = ChatController(
      coreBridge: bridge,
      nowMilliseconds: () => 1700000300000,
    );
  });

  test(
    'local batch retry resumes after saved items without duplicating them',
    () async {
      await controller.initialize();
      final files = [
        for (var i = 0; i < 2; i++)
          ChatAttachment(
            name: '$i.txt',
            mimeType: 'text/plain',
            bytes: Uint8List(1),
          ),
      ];
      bridge.failAt = 2;
      expect(await controller.sendBatch('caption', files), false);
      bridge.failAt = null;
      expect(await controller.sendBatch('caption', files), true);
      expect(bridge.savedTexts.length, 2);
      expect(
        bridge.savedTexts.where((text) => text.contains('caption')).length,
        1,
      );
    },
  );

  test(
    'initialize loads the Rust snapshot and selects its first room',
    () async {
      await controller.initialize();

      expect(controller.status, ChatControllerStatus.ready);
      expect(controller.selectedConversation.id, 'general');
      expect(controller.conversations.map((item) => item.id), [
        'general',
        'design',
      ]);
    },
  );

  test('initialization failure is exposed without fabricated state', () async {
    bridge.loadError = StateError('IndexedDB unavailable');

    await controller.initialize();

    expect(controller.status, ChatControllerStatus.failed);
    expect(controller.conversations, isEmpty);
    expect(controller.error, isNotNull);
  });

  test('selecting an unknown conversation reports the requested id', () async {
    await controller.initialize();

    expect(
      () => controller.selectConversation('missing'),
      throwsA(
        isA<UnknownConversationException>().having(
          (error) => error.conversationId,
          'conversationId',
          'missing',
        ),
      ),
    );
  });

  test('sendText delegates unchanged text and timestamp to Rust', () async {
    await controller.initialize();
    bridge.nextSnapshot = _snapshot(
      generalPreview: 'hello from web',
      generalMessages: [
        ..._snapshot().conversations.first.messages,
        const MessageView(
          id: 9,
          text: 'hello from web',
          sentAtMilliseconds: 1700000300000,
          incoming: false,
        ),
      ],
    );

    final accepted = await controller.sendText('  hello from web  ');

    expect(accepted, isTrue);
    expect(bridge.lastCommand?.conversationId, 'general');
    expect(bridge.lastCommand?.text, '  hello from web  ');
    expect(bridge.lastCommand?.sentAtMilliseconds, 1700000300000);
    expect(controller.selectedConversation.messages.last.id, 9);
  });

  test('sendText uses ordering returned by Rust', () async {
    await controller.initialize();
    controller.selectConversation('design');
    bridge.nextSnapshot = _snapshot(designFirst: true);

    await controller.sendText('latest update');

    expect(controller.conversations.first.id, 'design');
  });

  test('rejected command keeps the previous snapshot', () async {
    await controller.initialize();
    final before = controller.selectedConversation.messages;
    bridge.sendError = StateError('message cannot be empty');

    final accepted = await controller.sendText('   ');

    expect(accepted, isFalse);
    expect(controller.selectedConversation.messages, same(before));
    expect(controller.error, isNotNull);
  });
}

ChatSnapshot _snapshot({
  String generalPreview = 'Web-first foundation',
  List<MessageView>? generalMessages,
  bool designFirst = false,
}) {
  final general = ConversationView(
    id: 'general',
    title: 'General',
    preview: generalPreview,
    updatedAtMilliseconds: 1700000000000,
    messages:
        generalMessages ??
        const [
          MessageView(
            id: 1,
            text: 'Web-first foundation',
            sentAtMilliseconds: 1700000000000,
            incoming: true,
          ),
        ],
  );
  final design = ConversationView(
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
  );
  return ChatSnapshot(
    schemaVersion: 1,
    conversations: designFirst ? [design, general] : [general, design],
  );
}

class _Command {
  const _Command(this.conversationId, this.text, this.sentAtMilliseconds);

  final String conversationId;
  final String text;
  final int sentAtMilliseconds;
}

class _FakeCoreBridge implements CoreBridge, ConversationManagementBridge {
  _FakeCoreBridge(this.snapshot);

  ChatSnapshot snapshot;
  Completer<ChatSnapshot>? sendGate;
  @override
  Future<ChatSnapshot> deleteConversation(String id) async {
    snapshot = ChatSnapshot(
      schemaVersion: 1,
      conversations: snapshot.conversations.where((c) => c.id != id).toList(),
    );
    return snapshot;
  }

  ChatSnapshot? nextSnapshot;
  Object? loadError;
  Object? sendError;
  _Command? lastCommand;
  int sends = 0;
  int? failAt;
  final savedTexts = <String>[];

  @override
  Future<ChatSnapshot> loadSnapshot() async {
    if (loadError case final error?) throw error;
    return snapshot;
  }

  @override
  Future<ChatSnapshot> sendText(
    String conversationId,
    String text,
    int sentAtMilliseconds,
  ) async {
    lastCommand = _Command(conversationId, text, sentAtMilliseconds);
    if (++sends == failAt) throw StateError('disk full');
    if (sendError case final error?) throw error;
    savedTexts.add(text);
    return sendGate?.future ?? nextSnapshot ?? snapshot;
  }

  @override
  Future<String> version() async => 'cht-core@0.1.0';
}
