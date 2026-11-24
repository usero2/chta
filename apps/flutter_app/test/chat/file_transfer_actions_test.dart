import 'package:cht/chat/peer_history.dart';
import 'package:cht/chat/chat_attachment.dart';
import 'package:cht/chat/widgets/file_transfer_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dart:typed_data';

void main() {
  testWidgets(
    'pending files offer pause/cancel; paused offers resume; delivered hides actions',
    (tester) async {
      final message = PeerMessage(
        id: 'file',
        text: 'file',
        incoming: false,
        status: DeliveryStatus.pending,
        queuedForDelivery: true,
        attachment: ChatAttachment(
          name: 'fixture.bin',
          mimeType: 'application/octet-stream',
          bytes: Uint8List(1),
        ),
      );
      var pauses = 0, resumes = 0, cancels = 0;
      Future<void> show() => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FileTransferActions(
              message: message,
              onPause: () async {
                pauses++;
              },
              onResume: () async {
                resumes++;
              },
              onCancel: () async {
                cancels++;
              },
            ),
          ),
        ),
      );
      await show();
      await tester.tap(find.byTooltip('Pause transfer'));
      await tester.pumpAndSettle();
      expect(pauses, 1);
      expect(find.byTooltip('Cancel transfer'), findsOneWidget);
      message.deliveryPaused = true;
      await show();
      await tester.pump();
      expect(find.text('Paused'), findsOneWidget);
      await tester.tap(find.byTooltip('Resume transfer'));
      await tester.pumpAndSettle();
      expect(resumes, 1);
      await tester.tap(find.byTooltip('Cancel transfer'));
      await tester.pumpAndSettle();
      expect(cancels, 1);
      message.status = DeliveryStatus.delivered;
      await show();
      await tester.pump();
      expect(find.byType(IconButton), findsNothing);
    },
  );
}
