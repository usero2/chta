import 'dart:async';

import 'package:cht/runtime/network_monitor.dart';
import 'package:cht/runtime/network_recovery.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('handover is debounced and equivalent observations are quiet', (
    tester,
  ) async {
    var recovered = 0;
    final recovery = NetworkRecovery(
      isCurrent: () => true,
      recover: () async {
        recovered++;
      },
    );
    recovery.observe(
      const NetworkObservation(available: true, fingerprint: 'wifi'),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(recovered, 0);
    recovery.observe(
      const NetworkObservation(available: true, fingerprint: 'mobile'),
    );
    recovery.observe(
      const NetworkObservation(available: true, fingerprint: 'mobile'),
    );
    await tester.pump(const Duration(milliseconds: 799));
    expect(recovered, 0);
    await tester.pump(const Duration(milliseconds: 2));
    expect(recovered, 1);
    recovery.observe(
      const NetworkObservation(available: true, fingerprint: 'mobile'),
    );
    await tester.pump(const Duration(seconds: 2));
    expect(recovered, 1);
    recovery.dispose();
  });
  testWidgets('offline waits; online and explicit resume recover', (
    tester,
  ) async {
    var recovered = 0;
    final recovery = NetworkRecovery(
      isCurrent: () => true,
      recover: () async {
        recovered++;
      },
    );
    recovery.observe(
      const NetworkObservation(available: false, fingerprint: 'none'),
    );
    recovery.resume();
    await tester.pump(const Duration(seconds: 2));
    expect(recovered, 0);
    recovery.observe(
      const NetworkObservation(available: true, fingerprint: 'wifi'),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(recovered, 1);
    recovery.resume();
    await tester.pump(const Duration(seconds: 1));
    expect(recovered, 2);
    recovery.dispose();
  });
  testWidgets(
    'lock/dispose invalidates pending recovery and burst never overlaps',
    (tester) async {
      var active = true, recovered = 0;
      final release = Completer<void>();
      final recovery = NetworkRecovery(
        isCurrent: () => active,
        recover: () async {
          recovered++;
          await release.future;
        },
      );
      recovery.resume();
      active = false;
      await tester.pump(const Duration(seconds: 1));
      expect(recovered, 0);
      active = true;
      recovery.resume();
      await tester.pump(const Duration(seconds: 1));
      expect(recovered, 1);
      recovery.resume();
      recovery.resume();
      await tester.pump(const Duration(seconds: 2));
      expect(recovered, 1);
      release.complete();
      await tester.pump();
      recovery.dispose();
      await tester.pump(const Duration(seconds: 2));
      expect(recovered, 1);
    },
  );
}
