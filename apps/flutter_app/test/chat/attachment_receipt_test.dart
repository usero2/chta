import 'dart:async';
import 'dart:typed_data';

import 'package:cht/chat/chat_attachment.dart';
import 'package:cht/chat/attachment_transfer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'final packet waits for durable receive and retries a failed write',
    () async {
      late AttachmentTransfer sender;
      late String packetId, packet;
      sender = AttachmentTransfer(
        sendPacket: (id, text, _) async {
          packetId = id;
          packet = text;
          sender.acknowledge(id);
        },
        onReceived: (_, _, _, _) {},
      );
      await sender.send(
        'durable',
        ChatAttachment(
          name: 'a.bin',
          mimeType: 'application/octet-stream',
          bytes: Uint8List(3),
        ),
        1,
      );
      var writes = 0;
      final gate = Completer<void>();
      final receiver = AttachmentTransfer(
        sendPacket: (_, _, _) async {},
        onReceived: (_, _, _, _) async {
          writes++;
          await gate.future;
          if (writes == 1) throw StateError('disk full');
        },
      );
      var acknowledged = false;
      final first = receiver.receive(packetId, packet, 1, 2).then((value) {
        acknowledged = true;
        return value;
      });
      final failure = expectLater(first, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      expect(acknowledged, false);
      gate.complete();
      await failure;
      expect(await receiver.receive(packetId, packet, 1, 3), true);
      expect(await receiver.receive(packetId, packet, 1, 4), true);
      expect(writes, 2);
    },
  );
}
