import 'package:cht/chat/attachment_source.dart';
import 'package:cht/chat/chat_attachment.dart';
import 'package:cht/chat/attachment_ref.dart';
import 'package:cht/chat/peer_history.dart';
import 'package:cht/chat/widgets/attachment_content.dart';
import 'package:cht/chat/widgets/pending_attachment_tray.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'incoming chunked card waits for completion then opens automatically',
    (tester) async {
      final history = _PendingHistory();
      final message = PeerMessage(
        id: 'incoming-large-fixture-01',
        text: 'file',
        incoming: true,
        status: DeliveryStatus.pending,
        attachmentRef: AttachmentRef(
          name: 'huge.jpg',
          mimeType: 'image/jpeg',
          size: 200 * 1024 * 1024,
          digest: 'a' * 64,
          chunkedId: 'incoming-cache-fixture-01',
          chunkSize: 262144,
        ),
      );
      Widget page() => MaterialApp(
        home: Scaffold(
          body: CachedAttachmentContent(
            key: const ValueKey('same-file'),
            history: history,
            message: message,
          ),
        ),
      );
      await tester.pumpWidget(page());
      await tester.pump();
      expect(history.reads, 0);
      message.status = DeliveryStatus.delivered;
      await tester.pumpWidget(page());
      await tester.pump();
      expect(history.reads, 1);
      expect(find.text('huge.jpg'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('streamed media cards and pending tray avoid in-memory bytes', (
    tester,
  ) async {
    final image = ChatAttachment.fromSource(
      name: 'huge.jpg',
      mimeType: 'image/jpeg',
      source: _Source(),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              AttachmentContent(attachment: image, incoming: false),
              PendingAttachmentTray(files: [image], onRemove: null),
            ],
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('huge.jpg'), findsWidgets);
    expect(find.byType(Image), findsNothing);
  });
}

class _PendingHistory extends PeerHistory {
  int reads = 0;
  @override
  Future<ChatAttachment> resolveAttachment(PeerMessage message) async {
    reads++;
    if (message.status != DeliveryStatus.delivered) {
      throw StateError('Not complete');
    }
    return ChatAttachment.fromSource(
      name: 'huge.jpg',
      mimeType: 'image/jpeg',
      source: _Source(),
    );
  }
}

class _Source implements AttachmentSource {
  @override
  int get length => 200 * 1024 * 1024;
  @override
  String get key => 'huge-image';
  @override
  Stream<List<int>> openRead({int start = 0, int? end}) =>
      throw StateError('Preview should not read the source');
}
