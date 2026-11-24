import 'package:cht/chat/file_transfer_progress.dart';
import 'package:cht/chat/widgets/file_transfer_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'completed streamed transfer leaves no status row or progress gap',
    (tester) async {
      await tester.pumpWidget(
        _screen(
          const TransferProgressSnapshot(
            confirmedBytes: 100,
            totalBytes: 100,
            bytesPerSecond: 0,
            transport: 'Relay',
            phase: FileTransferPhase.completed,
          ),
        ),
      );
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.textContaining('Completed'), findsNothing);
    },
  );
  testWidgets(
    'failed transfer is a compact error without a stale percentage bar',
    (tester) async {
      await tester.pumpWidget(
        _screen(
          const TransferProgressSnapshot(
            confirmedBytes: 100,
            totalBytes: 100,
            bytesPerSecond: 0,
            transport: 'Direct',
            phase: FileTransferPhase.failed,
          ),
        ),
      );
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.textContaining('100%'), findsNothing);
      expect(find.textContaining('failed'), findsOneWidget);
    },
  );
  testWidgets('compact status shows direct bytes and speed without overflow', (
    tester,
  ) async {
    await tester.pumpWidget(
      _screen(
        const TransferProgressSnapshot(
          confirmedBytes: 123456789,
          totalBytes: 10 * 1024 * 1024 * 1024,
          bytesPerSecond: 2345678,
          transport: 'Direct',
          phase: FileTransferPhase.sending,
        ),
      ),
    );
    expect(find.textContaining('Direct'), findsOneWidget);
    expect(find.textContaining('MB/s'), findsOneWidget);
    expect(find.textContaining('1%'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('waiting and verifying phases remain explicit', (tester) async {
    await tester.pumpWidget(
      _screen(
        const TransferProgressSnapshot(
          confirmedBytes: 262144,
          totalBytes: 1048576,
          bytesPerSecond: 0,
          transport: 'Direct',
          phase: FileTransferPhase.waiting,
        ),
      ),
    );
    expect(find.textContaining('Waiting'), findsOneWidget);
    await tester.pumpWidget(
      _screen(
        const TransferProgressSnapshot(
          confirmedBytes: 1048576,
          totalBytes: 1048576,
          bytesPerSecond: 0,
          transport: 'Direct',
          phase: FileTransferPhase.verifying,
        ),
      ),
    );
    expect(find.textContaining('Verifying'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Widget _screen(TransferProgressSnapshot snapshot) => MaterialApp(
  home: Scaffold(
    body: SizedBox(width: 320, child: FileTransferStatus(snapshot: snapshot)),
  ),
);
