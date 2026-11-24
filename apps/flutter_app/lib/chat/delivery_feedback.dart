import 'dart:convert';

import 'peer_history.dart';

/// A connected discovery service is deliberately not an input here.
String? deliveryFeedback(
  DeliveryStatus status, {
  required bool online,
  bool needsDirect = false,
}) => switch (status) {
  DeliveryStatus.delivered => null,
  DeliveryStatus.failed => 'Not sent',
  _ when needsDirect => 'Waiting for Direct',
  DeliveryStatus.sent when online => 'Waiting for receipt',
  DeliveryStatus.pending when online => 'Sending',
  _ => 'Waiting for connection',
};

void validateOutgoingText(String text) {
  if (text.trim().isEmpty) throw const FormatException('Enter a message.');
  // Match the strictest existing relay wire limit, including JSON escaping.
  if (text.length > 12000 ||
      utf8.encode(jsonEncode({'type': 'message', 'text': text})).length >
          24000) {
    throw const FormatException(
      'Message is too long. Split it into smaller messages.',
    );
  }
}
