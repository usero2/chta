import 'dart:convert';
import 'dart:typed_data';

import 'package:cht/chat/attachment_transfer.dart';
import 'package:cht/chat/attachment_ref.dart';
import 'package:cht/chat/chat_attachment.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final base = ChatAttachment(
    name: 'photo.png',
    mimeType: 'image/png',
    bytes: Uint8List(9000),
  );
  test(
    'caption and album metadata round trip and share immutable bytes',
    () async {
      final media = base.withPresentation(
        caption: 'ภาพ **หนึ่ง**',
        groupId: 'batch_image',
        groupIndex: 0,
        groupCount: 2,
      );
      expect(media.bytes.buffer, base.bytes.buffer);
      expect(() => media.bytes[0] = 2, throwsUnsupportedError);
      final copy = ChatAttachment.fromJson(media.toJson());
      expect(copy.caption, media.caption);
      expect(copy.groupCount, 2);
      final ref = AttachmentRef(
        name: media.name,
        mimeType: media.mimeType,
        size: media.bytes.length,
        digest: 'a' * 64,
        caption: media.caption,
        groupId: media.groupId,
        groupIndex: media.groupIndex,
        groupCount: media.groupCount,
      );
      expect(AttachmentRef.fromJson(ref.toJson()).caption, media.caption);
      ChatAttachment? received;
      late AttachmentTransfer sender;
      final receiver = AttachmentTransfer(
        sendPacket: (_, _, _) async {},
        onReceived: (_, file, _, _) {
          received = file;
        },
      );
      sender = AttachmentTransfer(
        sendPacket: (id, text, time) async {
          await receiver.receive(id, text, time, 2);
          sender.acknowledge(id);
        },
        onReceived: (_, _, _, _) {},
      );
      await sender.send('batch', media, 1);
      expect(received!.caption, media.caption);
      expect(received!.groupIndex, 0);
      expect(received!.bytes, media.bytes);
    },
  );
  test(
    'rejects malformed presentation and overlong packets before sending',
    () async {
      for (final fields in [
        {'groupId': 'x', 'groupIndex': 0, 'groupCount': 6},
        {'groupId': 'x', 'groupIndex': 2, 'groupCount': 2},
        {'groupId': '../x', 'groupIndex': 0, 'groupCount': 2},
        {'groupIndex': 0},
        {'caption': 'ก' * 171},
        {'caption': 12},
      ]) {
        expect(
          () => ChatAttachment.fromJson({...base.toJson(), ...fields}),
          throwsFormatException,
        );
      }
      var sent = 0;
      final sender = AttachmentTransfer(
        sendPacket: (_, _, _) async {
          sent++;
        },
        onReceived: (_, _, _, _) {},
      );
      final large = ChatAttachment(
        name: '"' * 255,
        mimeType: 'application/octet-stream',
        bytes: Uint8List(9000),
        caption: '"' * 512,
      );
      await expectLater(sender.send('large', large, 1), throwsFormatException);
      expect(sent, 0);
    },
  );
  test(
    'conflicting group metadata rejected during a partial transfer',
    () async {
      final packets = <(String, String)>[];
      late AttachmentTransfer sender;
      sender = AttachmentTransfer(
        sendPacket: (id, text, _) async {
          packets.add((id, text));
          sender.acknowledge(id);
        },
        onReceived: (_, _, _, _) {},
      );
      await sender.send(
        'metadata',
        base.withPresentation(groupId: 'one', groupIndex: 0, groupCount: 2),
        1,
      );
      final receiver = AttachmentTransfer(
        sendPacket: (_, _, _) async {},
        onReceived: (_, _, _, _) {},
      );
      await receiver.receive(packets.first.$1, packets.first.$2, 1, 2);
      final second = jsonDecode(
        packets.last.$2.substring(AttachmentTransfer.marker.length),
      ) as Map<String, dynamic>;
      second['groupId'] = 'two';
      await expectLater(
        receiver.receive(
          packets.last.$1,
          AttachmentTransfer.marker + jsonEncode(second),
          1,
          2,
        ),
        throwsFormatException,
      );
    },
  );
}
