import 'package:cht/chat/widgets/file_offer_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('an open offer shows its metadata and reports both decisions', (
    tester,
  ) async {
    final decisions = <String>[];
    await tester.pumpWidget(
      _frame(
        FileOfferCard(
          fileName: 'photo.png',
          mimeType: 'image/png',
          sizeBytes: 2048,
          caption: 'Original photo',
          cover: 'https://example.test/cover.png',
          onAccept: () => decisions.add('accepted'),
          onReject: () => decisions.add('rejected'),
        ),
      ),
    );

    expect(find.text('photo.png'), findsOneWidget);
    expect(find.textContaining('image/png'), findsOneWidget);
    expect(find.textContaining('2 KiB'), findsOneWidget);
    expect(find.text('Original photo'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(find.byIcon(Icons.image_outlined), findsOneWidget);
    await tester.tap(find.text('Accept'));
    await tester.tap(find.text('Reject'));
    expect(decisions, ['accepted', 'rejected']);
  });

  testWidgets('busy offers block decisions and show an error when present', (
    tester,
  ) async {
    await tester.pumpWidget(
      _frame(
        FileOfferCard(
          fileName: 'example.pdf',
          mimeType: 'application/pdf',
          sizeBytes: 128,
          busy: true,
          error: 'Try again',
          onAccept: () => fail('Busy offer was accepted'),
          onReject: () => fail('Busy offer was rejected'),
        ),
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    await tester.tap(find.text('Accept'));
    await tester.tap(find.text('Reject'));
  });

  testWidgets('a resolved offer shows its status without decision buttons', (
    tester,
  ) async {
    await tester.pumpWidget(
      _frame(
        FileOfferCard(
          fileName: 'example.pdf',
          mimeType: 'application/pdf',
          sizeBytes: 128,
          status: 'Accepted',
          onAccept: () => fail('Resolved offer was accepted again'),
          onReject: () => fail('Resolved offer was rejected'),
        ),
      ),
    );

    expect(find.text('Accepted'), findsOneWidget);
    expect(find.text('Accept'), findsNothing);
    expect(find.text('Reject'), findsNothing);
  });
}

Widget _frame(Widget child) => MaterialApp(
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: 260, child: child),
    ),
  ),
);
