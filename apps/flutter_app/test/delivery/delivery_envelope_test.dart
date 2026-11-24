import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:cht/delivery/delivery_envelope.dart';
import 'package:cht/delivery/delivery_crypto_bridge.dart';
import 'package:cht/chat/chat_attachment.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dart:typed_data';

class Crypto implements DeliveryCryptoBridge {
  @override
  Future<Map<String, Object?>> deliveryCall(
    String operation,
    Map<String, Object?> args,
  ) async {
    if (operation == 'signEvent') {
      return {
        'version': 1,
        'authorId': 'did:cht:${'a' * 64}',
        'messageId': args['messageId'],
        'scope': args['scope'],
        'sentAt': args['sentAt'],
        'kind': args['kind'],
        'payloadHash': sha256
            .convert(utf8.encode(args['payload'] as String))
            .toString(),
        'signature': 'valid',
      };
    }
    final event = Map<String, Object?>.from(args['event'] as Map);
    if (event['authorId'] != args['expectedAuthor'] ||
        event['scope'] != args['scope'] ||
        event['payloadHash'] !=
            sha256.convert(utf8.encode(args['payload'] as String)).toString()) {
      throw StateError('invalid');
    }
    return event;
  }
}

void main() {
  test('forwardable envelopes preserve author, ID, timestamp and payload binding across wire and protected JSON', () async {
    final envelope = await DeliveryEnvelope.create(
      Crypto(),
      scope: 'direct:example',
      messageId: 'original',
      sentAt: 1000,
      kind: 'text',
      payload: {'text': 'hello **world**'},
    );
    final restored = DeliveryEnvelope.fromJson(envelope.toJson());
    await restored.verify(
      Crypto(),
      author: 'did:cht:${'a' * 64}',
      scope: 'direct:example',
      messageId: 'original',
      sentAt: 1000,
      now: 2000,
    );
    expect(DeliveryEnvelope.fromWire(envelope.toWire()).payload, {
      'text': 'hello **world**',
    });
    expect(restored.messageId, 'original');
    expect(restored.sentAt, 1000);
    await expectLater(
      restored.verify(
        Crypto(),
        author: 'did:cht:${'b' * 64}',
        scope: 'direct:example',
        now: 2000,
      ),
      throwsStateError,
    );
    final tampered = envelope.toJson()..['payload'] = '{"text":"forged"}';
    await expectLater(
      DeliveryEnvelope.fromJson(tampered).verify(
        Crypto(),
        author: 'did:cht:${'a' * 64}',
        scope: 'direct:example',
        now: 2000,
      ),
      throwsStateError,
    );
  });
  test('Courier payload framing is bounded, streamed and splits even tiny text across at least three packages', () async {
    for (final size in [0, 1, 262144, 262145, 700000]) {
      final bytes = Uint8List.fromList(List.generate(size, (i) => i % 251));
      final envelope = await DeliveryEnvelope.create(
        Crypto(),
        scope: 'direct:example',
        messageId: 'file-$size',
        sentAt: 1000,
        kind: size == 0 ? 'text' : 'file',
        payload: {'text': 'caption'},
      );
      final file = size == 0
          ? null
          : ChatAttachment(
              name: 'test.bin',
              mimeType: 'application/octet-stream',
              bytes: bytes,
            );
      final payload = CourierPayload(envelope, file: file),
          parts = await payload.packages().toList();
      expect(parts.length, payload.packageCount);
      expect(parts.length, greaterThanOrEqualTo(3));
      expect(parts.every((b) => b.length <= 262144), isTrue);
      final joined = BytesBuilder(copy: false);
      for (final p in parts) {
        joined.add(p);
      }
      final full = joined.takeBytes();
      expect(full.length, payload.size);
      final length = ByteData.sublistView(full, 0, 4).getUint32(0, Endian.big);
      expect(
        DeliveryEnvelope.fromJson(
          Map<String, Object?>.from(
            jsonDecode(utf8.decode(full.sublist(4, 4 + length))) as Map,
          ),
        ).messageId,
        envelope.messageId,
      );
      expect(full.sublist(4 + length), bytes);
    }
  });
}
