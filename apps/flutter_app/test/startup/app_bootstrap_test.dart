import 'dart:async';

import 'package:cht/startup/app_bootstrap.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('draws a first frame while storage is pending', (tester) async {
    final pending = Completer<Widget>();
    await tester.pumpWidget(AppBootstrap(load: () => pending.future));
    expect(find.text('Opening chta…'), findsOneWidget);
    pending.complete(const MaterialApp(home: Text('Identity picker')));
    await tester.pumpAndSettle();
    expect(find.text('Identity picker'), findsOneWidget);
  });

  testWidgets('storage failure shows retry and can recover', (tester) async {
    var attempts = 0;
    await tester.pumpWidget(
      AppBootstrap(
        load: () async {
          if (++attempts == 1) throw StateError('storage unavailable');
          return const MaterialApp(home: Text('Identity picker'));
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('retry-startup')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('retry-startup')));
    await tester.pumpAndSettle();
    expect(find.text('Identity picker'), findsOneWidget);
  });

  testWidgets('stalled initialization leaves a usable error screen', (
    tester,
  ) async {
    final pending = Completer<Widget>();
    await tester.pumpWidget(
      AppBootstrap(
        load: () => pending.future,
        timeout: const Duration(seconds: 2),
      ),
    );
    await tester.pump(const Duration(seconds: 3));
    expect(find.byKey(const ValueKey('retry-startup')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    pending.complete(const SizedBox());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
