import 'dart:typed_data';

import 'package:cht/chat/chat_attachment.dart';
import 'package:cht/chat/file_transfer_progress.dart';
import 'package:cht/chat/peer_history.dart';
import 'package:cht/chat/widgets/message_transfer_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'streamed bytes at 100 percent still wait for the final receipt',
    (tester) async {
      await tester.pumpWidget(
        screen(
          message(DeliveryStatus.pending),
          snapshot: const TransferProgressSnapshot(
            confirmedBytes: 100,
            totalBytes: 100,
            bytesPerSecond: 0,
            transport: 'Direct',
            phase: FileTransferPhase.sending,
          ),
        ),
      );
      expect(find.text('Waiting for receipt'), findsOneWidget);
      expect(find.textContaining('100%'), findsNothing);
    },
  );
  testWidgets(
    'delivered attachment hides stale legacy and streamed progress completely',
    (tester) async {
      await tester.pumpWidget(
        screen(
          message(DeliveryStatus.delivered),
          progress: 1,
          snapshot: const TransferProgressSnapshot(
            confirmedBytes: 100,
            totalBytes: 100,
            bytesPerSecond: 0,
            transport: 'Direct',
            phase: FileTransferPhase.sending,
          ),
        ),
      );
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.textContaining('100%'), findsNothing);
      expect(tester.getSize(find.byType(MessageTransferStatus)).height, 0);
    },
  );
  testWidgets('active legacy transfer shows one compact percentage bar', (
    tester,
  ) async {
    await tester.pumpWidget(
      screen(message(DeliveryStatus.pending), progress: .4),
    );
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('40%'), findsOneWidget);
  });
  testWidgets('100 percent without a receipt waits for confirmation', (
    tester,
  ) async {
    await tester.pumpWidget(
      screen(message(DeliveryStatus.pending), progress: 1),
    );
    expect(find.text('Waiting for receipt'), findsOneWidget);
    expect(find.textContaining('100%'), findsNothing);
    expect(find.textContaining('Completed'), findsNothing);
  });
  testWidgets('streamed completion leaves no empty bottom padding', (
    tester,
  ) async {
    await tester.pumpWidget(
      screen(
        message(DeliveryStatus.pending),
        snapshot: const TransferProgressSnapshot(
          confirmedBytes: 100,
          totalBytes: 100,
          bytesPerSecond: 0,
          transport: 'Relay',
          phase: FileTransferPhase.completed,
        ),
      ),
    );
    expect(tester.getSize(find.byType(MessageTransferStatus)).height, 0);
  });
}

PeerMessage message(DeliveryStatus status) => PeerMessage(
  id: 'fixture',
  text: '[file]',
  incoming: false,
  status: status,
  attachment: ChatAttachment(
    name: 'fixture.bin',
    mimeType: 'application/octet-stream',
    bytes: Uint8List(100),
  ),
);

Widget screen(
  PeerMessage message, {
  double? progress,
  TransferProgressSnapshot? snapshot,
}) => MaterialApp(
  home: Scaffold(
    body: Align(
      alignment: Alignment.topRight,
      child: MessageTransferStatus(
        message: message,
        legacyProgress: progress,
        snapshot: snapshot,
      ),
    ),
  ),
);
