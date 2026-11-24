import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../chat/chat_attachment.dart';
import '../courier/courier_models.dart';
import 'delivery_crypto_bridge.dart';

const deliveryWirePrefix = 'chta-delivery-v2:';
String directDeliveryScope(String a, String b) {
  if (!RegExp(r'^did:cht:[0-9a-f]{64}$').hasMatch(a) ||
      !RegExp(r'^did:cht:[0-9a-f]{64}$').hasMatch(b) ||
      a == b) {
    throw const FormatException('Invalid delivery peers');
  }
  final ids = [a, b]..sort();
  return 'direct:${ids[0].substring(8)}:${ids[1].substring(8)}';
}

class DeliveryEnvelope {
  DeliveryEnvelope._(this.event, this.payloadSource);
  final Map<String, Object?> event;
  final String payloadSource;
  String get messageId => event['messageId'] as String;
  String get authorId => event['authorId'] as String;
  String get scope => event['scope'] as String;
  String get kind => event['kind'] as String;
  int get sentAt => event['sentAt'] as int;
  Map<String, Object?> get payload =>
      Map<String, Object?>.from(jsonDecode(payloadSource) as Map);
  static Future<DeliveryEnvelope> create(
    DeliveryCryptoBridge crypto, {
    required String scope,
    required String messageId,
    required int sentAt,
    required String kind,
    required Map<String, Object?> payload,
  }) async {
    final source = jsonEncode(payload);
    if (utf8.encode(source).length > 32768) {
      throw const FormatException('Delivery metadata too large');
    }
    final event = await crypto.deliveryCall('signEvent', {
      'scope': scope,
      'messageId': messageId,
      'sentAt': sentAt,
      'kind': kind,
      'payload': source,
    });
    return DeliveryEnvelope.fromJson({
      'version': 2,
      'event': event,
      'payload': source,
    });
  }

  Map<String, Object?> toJson() => {
    'version': 2,
    'event': event,
    'payload': payloadSource,
  };
  factory DeliveryEnvelope.fromJson(Map<String, Object?> value) {
    if (value.length != 3 ||
        value['version'] != 2 ||
        value['event'] is! Map ||
        value['payload'] is! String) {
      throw const FormatException('Invalid delivery envelope');
    }
    final source = value['payload'] as String,
        event = Map<String, Object?>.from(value['event'] as Map);
    if (utf8.encode(source).length > 32768 ||
        utf8.encode(jsonEncode(event)).length > 4096 ||
        jsonDecode(source) is! Map ||
        event['messageId'] is! String ||
        (event['messageId'] as String).isEmpty ||
        (event['messageId'] as String).length > 256 ||
        event['authorId'] is! String ||
        event['scope'] is! String ||
        event['sentAt'] is! int ||
        event['kind'] is! String) {
      throw const FormatException('Invalid delivery metadata');
    }
    return DeliveryEnvelope._(Map.unmodifiable(event), source);
  }
  String toWire() => '$deliveryWirePrefix${jsonEncode(toJson())}';
  factory DeliveryEnvelope.fromWire(String wire) {
    if (!wire.startsWith(deliveryWirePrefix) ||
        utf8.encode(wire).length > 65536) {
      throw const FormatException('Invalid delivery wire');
    }
    return DeliveryEnvelope.fromJson(
      Map<String, Object?>.from(
        jsonDecode(wire.substring(deliveryWirePrefix.length)) as Map,
      ),
    );
  }
  Future<void> verify(
    DeliveryCryptoBridge crypto, {
    required String author,
    required String scope,
    required int now,
    String? messageId,
    int? sentAt,
  }) async {
    if ((messageId != null && this.messageId != messageId) ||
        (sentAt != null && this.sentAt != sentAt)) {
      throw const FormatException('Delivery transport binding mismatch');
    }
    await crypto.deliveryCall('verifyEvent', {
      'event': event,
      'expectedAuthor': author,
      'scope': scope,
      'payload': payloadSource,
      'now': now,
    });
  }
}

/// A small private envelope header followed by streamed file bytes. Neither the
/// header nor the original file name is exposed in public deposit metadata.
class CourierPayload {
  CourierPayload(this.envelope, {this.file})
    : _header = Uint8List.fromList(utf8.encode(jsonEncode(envelope.toJson()))) {
    if (_header.length > 65536 ||
        size > courierMaxPackages * courierPackageBytes) {
      throw const FormatException('Courier payload exceeds capacity');
    }
  }
  final DeliveryEnvelope envelope;
  final ChatAttachment? file;
  final Uint8List _header;
  int get size => 4 + _header.length + (file?.size ?? 0);
  int get packageCount =>
      max(3, (size + courierPackageBytes - 1) ~/ courierPackageBytes);
  int get packageSize => (size + packageCount - 1) ~/ packageCount;
  Stream<List<int>> openRead() async* {
    final prefix = Uint8List(4);
    ByteData.sublistView(prefix).setUint32(0, _header.length, Endian.big);
    yield prefix;
    yield _header;
    var read = 0;
    if (file != null) {
      await for (final part in file!.openRead()) {
        read += part.length;
        if (read > file!.size) {
          throw const FormatException('Attachment grew during preparation');
        }
        yield part;
      }
      if (read != file!.size) {
        throw const FormatException('Attachment truncated during preparation');
      }
    }
  }

  Stream<Uint8List> packages() async* {
    var buffer = Uint8List(packageSize), used = 0, count = 0;
    await for (final part in openRead()) {
      for (var offset = 0; offset < part.length;) {
        final take = min(packageSize - used, part.length - offset);
        buffer.setRange(used, used + take, part, offset);
        used += take;
        offset += take;
        if (used == packageSize) {
          yield buffer;
          count++;
          buffer = Uint8List(packageSize);
          used = 0;
        }
      }
    }
    if (used > 0) {
      yield Uint8List.sublistView(buffer, 0, used);
      count++;
    }
    if (count != packageCount) {
      throw const FormatException('Courier package count mismatch');
    }
  }
}
