import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:cht/chat/chat_attachment.dart';
import 'package:cht/chat/attachment_transfer.dart';

void main() {
  test('transfers binary chunks and suppresses completed duplicates', () async {
    final bytes = Uint8List.fromList(List.generate(15000, (i) => i % 256));
    final received = <ChatAttachment>[];
    final packets = <(String, String)>[];
    late AttachmentTransfer sender;
    final receiver = AttachmentTransfer(
      sendPacket: (_, _, _) async {},
      onReceived: (_, a, _, _) => received.add(a),
    );
    sender = AttachmentTransfer(
      sendPacket: (id, text, sentAt) async {
        packets.add((id, text));
        expect(await receiver.receive(id, text, sentAt, 2), isTrue);
        sender.acknowledge(id);
      },
      onReceived: (_, _, _, _) {},
    );
    await sender.send(
      'abc',
      ChatAttachment(
        name: 'x.bin',
        mimeType: 'application/octet-stream',
        bytes: bytes,
      ),
      1,
    );
    expect(received.single.bytes, bytes);
    for (final packet in packets) {
      await receiver.receive(packet.$1, packet.$2, 1, 3);
    }
    expect(received.length, 1);
  });

  test('accepts out of order chunks and rejects malformed packets', () async {
    final packets = <(String, String)>[];
    late AttachmentTransfer sender;
    sender = AttachmentTransfer(
      sendPacket: (id, text, time) async {
        packets.add((id, text));
        sender.acknowledge(id, receivedAtMilliseconds: 42);
      },
      onReceived: (_, _, _, _) {},
    );
    expect(
      await sender.send(
        'order',
        ChatAttachment(
          name: 'a.txt',
          mimeType: 'text/plain',
          bytes: Uint8List(15000),
        ),
        1,
      ),
      42,
    );
    var count = 0;
    final receiver = AttachmentTransfer(
      sendPacket: (_, _, _) async {},
      onReceived: (_, attachment, _, _) {
        count++;
        expect(attachment.bytes.length, 15000);
      },
    );
    expect(await receiver.receive('x', 'ordinary text', 1, 2), false);
    await expectLater(
      receiver.receive(
        packets.first.$1,
        '${AttachmentTransfer.marker}{bad',
        1,
        2,
      ),
      throwsFormatException,
    );
    await expectLater(
      receiver.receive(
        packets.first.$1,
        packets.first.$2.replaceFirst('"size":15000', '"size":999999999'),
        1,
        2,
      ),
      throwsFormatException,
    );
    await receiver.receive(packets.last.$1, packets.last.$2, 1, 2);
    await receiver.receive(packets.first.$1, packets.first.$2, 1, 2);
    expect(count, 1);
  });

  test('timeout, failure, and reset release pending sends', () async {
    final attachment = ChatAttachment(
      name: 'a',
      mimeType: 'text/plain',
      bytes: Uint8List(1),
    );
    final timeout = AttachmentTransfer(
      sendPacket: (_, _, _) async {},
      onReceived: (_, _, _, _) {},
      ackTimeout: const Duration(milliseconds: 5),
    );
    await expectLater(
      timeout.send('timeout', attachment, 1),
      throwsA(isA<TimeoutException>()),
    );
    late AttachmentTransfer failed;
    failed = AttachmentTransfer(
      sendPacket: (id, _, _) async {
        failed.fail(id);
      },
      onReceived: (_, _, _, _) {},
    );
    await expectLater(failed.send('failed', attachment, 1), throwsStateError);
    final reset = AttachmentTransfer(
      sendPacket: (_, _, _) async {},
      onReceived: (_, _, _, _) {},
    );
    final result = reset.send('reset', attachment, 1);
    reset.reset();
    await expectLater(result, throwsStateError);
  });

  test('model validates safe names and round trips history', () {
    final a = ChatAttachment(
      name: 'a.png',
      mimeType: 'image/png',
      bytes: Uint8List.fromList([0, 1, 255]),
    );
    final copy = ChatAttachment.fromJson(a.toJson());
    expect(copy.bytes, a.bytes);
    expect(copy.kind, 'image');
    expect(
      () => ChatAttachment(
        name: '../a',
        mimeType: 'text/plain',
        bytes: Uint8List(0),
      ),
      throwsFormatException,
    );
    expect(
      () => ChatAttachment(name: 'a', mimeType: 'bad', bytes: Uint8List(0)),
      throwsFormatException,
    );
  });
  test(
    'rejects checksum mismatch and conflicting completed metadata',
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
        'verify',
        ChatAttachment(
          name: 'a',
          mimeType: 'text/plain',
          bytes: Uint8List.fromList([1, 2, 3]),
        ),
        1,
      );
      var received = 0;
      final receiver = AttachmentTransfer(
        sendPacket: (_, _, _) async {},
        onReceived: (_, _, _, _) {
          received++;
        },
      );
      await expectLater(
        receiver.receive(
          packets.single.$1,
          packets.single.$2.replaceFirst('AQID', 'BAUG'),
          1,
          2,
        ),
        throwsFormatException,
      );
      expect(received, 0);
      await receiver.receive(packets.single.$1, packets.single.$2, 1, 2);
      await expectLater(
        receiver.receive(
          packets.single.$1,
          packets.single.$2.replaceFirst('"name":"a"', '"name":"b"'),
          1,
          2,
        ),
        throwsFormatException,
      );
      expect(received, 1);
    },
  );

  test('failed chunk stops queue and transfer can be retried', () async {
    var sends = 0;
    var shouldFail = true;
    late AttachmentTransfer sender;
    sender = AttachmentTransfer(
      sendPacket: (id, _, _) async {
        sends++;
        if (shouldFail) {
          sender.fail(id);
        } else {
          sender.acknowledge(id);
        }
      },
      onReceived: (_, _, _, _) {},
    );
    final attachment = ChatAttachment(
      name: 'a',
      mimeType: 'text/plain',
      bytes: Uint8List(17000),
    );
    await expectLater(sender.send('retry', attachment, 1), throwsStateError);
    expect(sends, 1);
    shouldFail = false;
    await sender.send('retry', attachment, 1);
    expect(sends, 4);
  });
  test('sends twenty chunks in windows of eight acknowledgments', () async {
    final ids = <String>[];
    final packets = <(String, String)>[];
    final sender = AttachmentTransfer(
      sendPacket: (id, text, _) async {
        ids.add(id);
        packets.add((id, text));
      },
      onReceived: (_, _, _, _) {},
    );
    final bytes = Uint8List.fromList(
      List.generate(20 * AttachmentTransfer.chunkSize, (i) => i % 251),
    );
    final future = sender.send(
      'window',
      ChatAttachment(
        name: 'a.bin',
        mimeType: 'application/octet-stream',
        bytes: bytes,
      ),
      1,
    );
    await Future<void>.delayed(Duration.zero);
    expect(ids.length, 8);
    for (final id in ids.toList()) {
      sender.acknowledge(id, receivedAtMilliseconds: 1);
    }
    await Future<void>.delayed(Duration.zero);
    expect(ids.length, 16);
    for (final id in ids.skip(8).toList()) {
      sender.acknowledge(id, receivedAtMilliseconds: 2);
    }
    await Future<void>.delayed(Duration.zero);
    expect(ids.length, 20);
    for (final id in ids.skip(16).toList()) {
      sender.acknowledge(id, receivedAtMilliseconds: 3);
    }
    expect(await future, 3);
    ChatAttachment? received;
    final receiver = AttachmentTransfer(
      sendPacket: (_, _, _) async {},
      onReceived: (_, attachment, _, _) {
        received = attachment;
      },
    );
    for (final packet in packets.reversed) {
      await receiver.receive(packet.$1, packet.$2, 1, 2);
    }
    expect(received!.bytes, bytes);
  });
  test(
    'permits 26 MiB under direct policy and rejects it by default',
    () async {
      final bytes = Uint8List(26 * 1024 * 1024);
      bytes[0] = 41;
      bytes[bytes.length - 1] = 93;
      final attachment = ChatAttachment(
        name: 'large.bin',
        mimeType: 'application/octet-stream',
        bytes: bytes,
      );
      final defaultTransfer = AttachmentTransfer(
        sendPacket: (_, _, _) async {},
        onReceived: (_, _, _, _) {},
      );
      await expectLater(
        defaultTransfer.send('limited', attachment, 1),
        throwsFormatException,
      );
      ChatAttachment? received;
      final receiver = AttachmentTransfer(
        maxTransferBytes: () => ChatAttachment.maxBytes,
        sendPacket: (_, _, _) async {},
        onReceived: (_, item, _, _) {
          received = item;
        },
      );
      late AttachmentTransfer sender;
      var checkedDefaultReceive = false;
      sender = AttachmentTransfer(
        maxTransferBytes: () => ChatAttachment.maxBytes,
        sendPacket: (id, text, sentAt) async {
          if (!checkedDefaultReceive) {
            checkedDefaultReceive = true;
            await expectLater(
              defaultTransfer.receive(id, text, sentAt, 2),
              throwsFormatException,
            );
          }
          await receiver.receive(id, text, sentAt, 2);
          sender.acknowledge(id);
        },
        onReceived: (_, _, _, _) {},
      );
      await sender.send('direct', attachment, 1);
      expect(received!.bytes.length, bytes.length);
      expect(received!.bytes.first, 41);
      expect(received!.bytes.last, 93);
      var limit = ChatAttachment.maxBytes;
      var sent = 0;
      late AttachmentTransfer changing;
      changing = AttachmentTransfer(
        maxTransferBytes: () => limit,
        sendPacket: (id, _, _) async {
          sent++;
          changing.acknowledge(id);
          if (sent == 8) limit = ChatAttachment.relayMaxBytes;
        },
        onReceived: (_, _, _, _) {},
      );
      await expectLater(
        changing.send('change', attachment, 1),
        throwsFormatException,
      );
      expect(sent, 8);
    },
  );
}
