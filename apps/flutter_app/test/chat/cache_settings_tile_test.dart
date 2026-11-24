import 'package:cht/chat/cache_policy.dart';
import 'package:cht/chat/widgets/cache_settings_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'room_history_store_test.dart' show Blobs;

void main() {
  testWidgets('failed cache settings expose Retry and recover in place', (
    tester,
  ) async {
    final blobs = RetryBlobs()..failRead = true;
    final policy = CachePolicy(
      ownerId: 'owner',
      settings: blobs,
      availableSpace: () async => null,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CacheSettingsTile(policy: policy)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Retry'), findsOneWidget);
    blobs.failRead = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(policy.ready, isTrue);
    expect(find.text('Retry'), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('apply-cache-limit')))
          .onPressed,
      isNotNull,
    );
    policy.dispose();
  });
  testWidgets(
    'Profile cache settings persist valid limits and show validation',
    (tester) async {
      final policy = CachePolicy(
        ownerId: 'owner',
        settings: Blobs(),
        availableSpace: () async => null,
      );
      await policy.initialize();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: CacheSettingsTile(policy: policy)),
        ),
      );
      expect(find.text('Cache'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('cache-limit')), '2');
      await tester.tap(find.byKey(const Key('apply-cache-limit')));
      await tester.pumpAndSettle();
      expect(policy.limitBytes, 2 * CachePolicy.gib);
      await tester.enterText(find.byKey(const Key('cache-limit')), '0');
      await tester.tap(find.byKey(const Key('apply-cache-limit')));
      await tester.pumpAndSettle();
      expect(find.text('Choose 1–1024 GB.'), findsOneWidget);
      expect(policy.limitBytes, 2 * CachePolicy.gib);
      policy.dispose();
    },
  );
}

class RetryBlobs extends Blobs {
  bool failRead = false;
  @override
  Future<String?> loadGroupBlob(String owner, String key) async {
    if (failRead) throw StateError('Synthetic temporary read failure');
    return super.loadGroupBlob(owner, key);
  }
}
