import 'package:cht/chat/delivery_feedback.dart';
import 'package:cht/chat/peer_history.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('receipt is never inferred from seed/route availability', () {
    expect(
      deliveryFeedback(DeliveryStatus.pending, online: false),
      'Waiting for connection',
    );
    expect(deliveryFeedback(DeliveryStatus.pending, online: true), 'Sending');
    expect(
      deliveryFeedback(DeliveryStatus.sent, online: true),
      'Waiting for receipt',
    );
    expect(
      deliveryFeedback(DeliveryStatus.sent, online: false),
      'Waiting for connection',
    );
    expect(deliveryFeedback(DeliveryStatus.delivered, online: false), isNull);
    expect(deliveryFeedback(DeliveryStatus.failed, online: true), 'Not sent');
    expect(
      deliveryFeedback(DeliveryStatus.pending, online: true, needsDirect: true),
      'Waiting for Direct',
    );
  });
  test('text validation respects escaped UTF-8 wire limits', () {
    expect(() => validateOutgoingText('hello'), returnsNormally);
    expect(() => validateOutgoingText('a' * 12000), returnsNormally);
    expect(() => validateOutgoingText('a' * 12001), throwsFormatException);
    expect(() => validateOutgoingText('😀' * 6000), throwsFormatException);
    expect(() => validateOutgoingText('\\' * 12000), throwsFormatException);
    expect(() => validateOutgoingText('  '), throwsFormatException);
  });
}
