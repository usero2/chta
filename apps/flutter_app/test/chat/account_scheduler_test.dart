import 'dart:async';

import 'package:cht/chat/account_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('idle ticks every five seconds and active work every second', (
    tester,
  ) async {
    var active = false, ticks = 0;
    final scheduler = AccountScheduler(
      hasWork: () => active,
      tick: () async {
        ticks++;
      },
    );
    scheduler.request();
    await tester.pump();
    expect(ticks, 1);
    await tester.pump(const Duration(seconds: 4));
    expect(ticks, 1);
    await tester.pump(const Duration(seconds: 1));
    expect(ticks, 2);
    active = true;
    scheduler.request();
    await tester.pump();
    expect(ticks, 3);
    await tester.pump(const Duration(seconds: 1));
    expect(ticks, 4);
    scheduler.close();
    await tester.pump(const Duration(seconds: 10));
    expect(ticks, 4);
  });
  testWidgets('event bursts coalesce and an in-flight tick never overlaps', (
    tester,
  ) async {
    var ticks = 0;
    final release = Completer<void>();
    final scheduler = AccountScheduler(
      hasWork: () => false,
      tick: () async {
        ticks++;
        if (ticks == 1) await release.future;
      },
    );
    for (var i = 0; i < 100; i++) {
      scheduler.request();
    }
    await tester.pump();
    expect(ticks, 1);
    for (var i = 0; i < 100; i++) {
      scheduler.request();
    }
    await tester.pump();
    expect(ticks, 1);
    release.complete();
    await tester.pump();
    expect(ticks, 2);
    scheduler.close();
  });
}
