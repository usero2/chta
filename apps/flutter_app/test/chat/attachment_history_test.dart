import 'dart:convert';
import 'dart:typed_data';

import 'package:cht/chat/chat_attachment.dart';
import 'package:cht/chat/chat_controller.dart';
import 'package:cht/chat/chat_models.dart';
import 'package:cht/chat/peer_history.dart';
import 'package:cht/chat/peer_history_store.dart';
import 'package:cht/core/core_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'attachment history survives reopen with receipts and owner isolation',
    () async {
      final store = _MemoryStore();
      final bytes = Uint8List.fromList([0, 255, 17, 128]);
      final attachment = ChatAttachment(
        name: 'image.png',
        mimeType: 'image/png',
        bytes: bytes,
      );
      final history = PeerHistory(store: store);
      await history.load('owner-a');
      history.add(
        'peer',
        PeerMessage(
          id: 'text',
          text: 'existing text',
          incoming: true,
          status: DeliveryStatus.delivered,
          sentAtMilliseconds: 9,
          receivedAtMilliseconds: 10,
        ),
      );
      history.add(
        'peer',
        PeerMessage(
          id: 'transfer-id',
          text: attachment.previewLabel,
          attachment: attachment,
          incoming: false,
          status: DeliveryStatus.pending,
          sentAtMilliseconds: 20,
        ),
      );
      history.setStatus(
        'peer',
        'transfer-id',
        DeliveryStatus.delivered,
        receivedAtMilliseconds: 30,
      );
      history.add(
        'peer',
        PeerMessage(
          id: 'transfer-id',
          text: 'duplicate',
          attachment: attachment,
          incoming: true,
          status: DeliveryStatus.delivered,
        ),
      );
      await history.flush();
      history.dispose();

      final reopened = PeerHistory(store: store);
      await reopened.load('owner-a');
      final messages = reopened.messagesFor('peer');
      expect(messages.length, 2);
      expect(messages.first.text, 'existing text');
      expect(messages.first.attachment, isNull);
      final restored = messages.last;
      expect(restored.attachment!.bytes, bytes);
      expect(restored.attachment!.name, 'image.png');
      expect(restored.attachment!.mimeType, 'image/png');
      expect(restored.sentAtMilliseconds, 20);
      expect(restored.receivedAtMilliseconds, 30);
      expect(restored.status, DeliveryStatus.delivered);
      reopened.add(
        'peer',
        PeerMessage(
          id: 'transfer-id',
          text: 'retry',
          incoming: true,
          status: DeliveryStatus.delivered,
        ),
      );
      expect(reopened.messagesFor('peer').length, 2);
      await reopened.load('owner-b');
      expect(reopened.messagesFor('peer'), isEmpty);
      reopened.dispose();
    },
  );

  test(
    'local attachment round trips through bridge with readable preview',
    () async {
      final bridge = _Bridge();
      final controller = ChatController(
        coreBridge: bridge,
        nowMilliseconds: () => 123,
      );
      await controller.initialize();
      final attachment = ChatAttachment(
        name: 'clip.bin',
        mimeType: 'application/octet-stream',
        bytes: Uint8List.fromList([0, 1, 2, 253, 254, 255]),
      );
      expect(await controller.sendAttachment(attachment), isTrue);
      expect(bridge.sentConversation, 'local');
      expect(bridge.sentAt, 123);
      expect(bridge.savedText, startsWith(localAttachmentPrefix));
      final encodedBytes = base64Encode(attachment.bytes);
      final snapshot = await bridge.loadSnapshot();
      final conversation = snapshot.conversations.single;
      expect(conversation.preview, attachment.previewLabel);
      expect(conversation.preview, isNot(contains(encodedBytes)));
      expect(conversation.messages.single.text, attachment.previewLabel);
      expect(conversation.messages.single.text, isNot(contains(encodedBytes)));
      expect(conversation.messages.single.attachment!.bytes, attachment.bytes);
      expect(
        controller.selectedConversation.messages.single.attachment!.bytes,
        attachment.bytes,
      );
      controller.dispose();
    },
  );
}

class _MemoryStore implements PeerHistoryStore {
  final values = <String, String>{};
  @override
  Future<String?> load(String ownerId) async => values[ownerId];
  @override
  Future<void> save(String ownerId, String source) async {
    values[ownerId] = source;
  }
}

class _Bridge implements CoreBridge {
  String? savedText;
  String? sentConversation;
  int? sentAt;
  @override
  Future<String> version() async => 'test';
  @override
  Future<ChatSnapshot> loadSnapshot() async => _snapshot();
  @override
  Future<ChatSnapshot> sendText(
    String conversationId,
    String text,
    int sentAtMilliseconds,
  ) async {
    sentConversation = conversationId;
    savedText = text;
    sentAt = sentAtMilliseconds;
    return _snapshot();
  }

  ChatSnapshot _snapshot() => ChatSnapshot.fromJson({
    'schemaVersion': 1,
    'conversations': [
      {
        'id': 'local',
        'title': 'Local',
        'preview': savedText ?? 'hello',
        'updatedAtMilliseconds': sentAt ?? 0,
        'messages': savedText == null
            ? <Object?>[]
            : [
                {
                  'id': 1,
                  'text': savedText,
                  'sentAtMilliseconds': sentAt,
                  'incoming': false,
                },
              ],
      },
    ],
  });
}
