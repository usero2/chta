import 'dart:convert';

import 'package:cht/chat/attachment_source.dart';
import 'package:cht/chat/chat_attachment.dart';
import 'package:cht/chat/attachment_ref.dart';
import 'package:cht/chat/peer_history.dart';
import 'package:cht/chat/widgets/attachment_content.dart';
import 'package:cht/chat/widgets/pending_attachment_tray.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('streamed Markdown opens in the in-app reader', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AttachmentContent(
            incoming: true,
            attachment: ChatAttachment.fromSource(
              name: 'Long message.md',
              mimeType: 'text/markdown',
              source: _MarkdownSource(),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Long message.md'));
    await tester.pumpAndSettle();
    expect(find.text('ข้อความยาว 😀', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Markdown card previews 300 characters with Read more below', (
    tester,
  ) async {
    final excerpt = 'ก้👩‍💻' * 150;
    final fullText = '$excerpt\n\n# Full Markdown document';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AttachmentContent(
              incoming: true,
              attachment: ChatAttachment.fromSource(
                name: 'Long message.md',
                mimeType: 'text/markdown',
                source: _MarkdownSource(fullText),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final preview = find.text('$excerpt…');
    final readMore = find.widgetWithText(TextButton, 'Read more');
    expect(preview, findsOneWidget);
    expect(
      find.text('Full Markdown document', findRichText: true),
      findsNothing,
    );
    expect(
      tester.getTopLeft(readMore).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(preview).dy),
    );
    await tester.ensureVisible(readMore);
    await tester.tap(readMore);
    await tester.pumpAndSettle();
    expect(
      find.text('Full Markdown document', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets(
    'whitespace caption adds no empty footer to streamed visual media',
    (tester) async {
      Widget page(String? caption) => MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 240,
              child: AttachmentContent(
                incoming: false,
                attachment: ChatAttachment.fromSource(
                  name: 'huge.jpg',
                  mimeType: 'image/jpeg',
                  source: _Source(),
                  caption: caption,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(page(null));
      final without = tester.getSize(find.byType(AttachmentContent)).height;
      await tester.pumpWidget(page('  \n '));
      expect(tester.getSize(find.byType(AttachmentContent)).height, without);
      expect(tester.takeException(), isNull);
    },
  );
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

class _MarkdownSource implements AttachmentSource {
  _MarkdownSource([String text = '# ข้อความยาว 😀'])
    : bytes = utf8.encode(text);
  final List<int> bytes;
  @override
  int get length => bytes.length;
  @override
  String get key => 'markdown-fixture';
  @override
  Stream<List<int>> openRead({int start = 0, int? end}) async* {
    final part = bytes.sublist(start, end);
    yield part.sublist(0, 6);
    yield part.sublist(6);
  }
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
