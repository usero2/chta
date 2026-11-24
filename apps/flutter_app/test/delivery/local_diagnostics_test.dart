import 'dart:convert';

import 'package:cht/courier/courier_models.dart';
import 'package:cht/courier/courier_service.dart';
import 'package:cht/courier/courier_store.dart';
import 'package:cht/delivery/courier_settings_tile.dart';
import 'package:cht/delivery/local_diagnostics.dart';
import 'package:cht/relay/default_relays.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../courier/courier_journal_test.dart' show Disk;

class MobileService extends ChangeNotifier implements CourierService {
  @override
  bool get canHost => false;
  @override
  bool get ready => true;
  @override
  CourierStore? get hostStore => null;
  @override
  String diagnosticReport() => '{"knownCouriers":2}';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('operator pins add an independent provider without relabeling existing defaults', () {
    final id = 'd' * 64,
        endpoint = 'wss://relay.example.com/cht',
        builtIn = defaultDataRelays.entries.first;
    final config = configuredDataRelays(
      jsonEncode([
        {
          'endpoint': builtIn.key,
          'id': builtIn.value,
          'domain': 'fake-relabel',
        },
        {'endpoint': endpoint, 'id': id, 'domain': 'community'},
        {
          'endpoint': 'wss://127.0.0.1/cht',
          'id': 'e' * 64,
          'domain': 'private',
        },
      ]),
    );
    expect(config.pins[endpoint], id);
    expect(config.pins.length, defaultDataRelays.length + 1);
    expect(config.policy.domainFor(builtIn.value), 'cloudflare');
    expect(config.policy.independentDomains(config.pins.values), 2);
  });
  testWidgets('narrow mobile settings offers report but no persistent host', (
    tester,
  ) async {
    final service = MobileService();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: CourierSettingsTile(service: service),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Courier'));
    await tester.pumpAndSettle();
    expect(find.text('Send and receive only'), findsOneWidget);
    expect(find.text('Host Courier'), findsNothing);
    await tester.tap(find.text('Delivery diagnostics'));
    await tester.pumpAndSettle();
    expect(find.text('Copy report'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    service.dispose();
  });
  test(
    'diagnostics persists only aggregate metrics and stops on identity change',
    () async {
      final storage = Disk();
      final owner = 'did:cht:${'a' * 64}';
      var active = true;
      final diagnostic = LocalDeliveryDiagnostics(
        owner: owner,
        storage: storage,
        isCurrent: () => active,
      );
      await diagnostic.load();
      diagnostic.count(DeliveryMetric.repaired, 2);
      await diagnostic.flush();
      final report = diagnostic.export(
        seed: DiagnosticSeed.connected,
        activeRoutes: 3,
        warmRoutes: 2,
        knownCouriers: 4,
        hosting: true,
      );
      expect(report, isNot(contains(owner)));
      expect(report, isNot(contains('https://')));
      expect((jsonDecode(report)['totals'] as Map)['repaired'], 2);
      active = false;
      diagnostic.count(DeliveryMetric.repaired);
      await diagnostic.flush();
      final restored = LocalDeliveryDiagnostics(owner: owner, storage: storage);
      await restored.load();
      expect(restored.total(DeliveryMetric.repaired), 2);
      diagnostic.close();
      restored.close();
    },
  );
  test('waiting, deposited and recipient receipt have different labels', () {
    expect(
      courierStatusLabel(CourierJobStatus.waitingForNodes, 1),
      'Waiting for 2 Couriers',
    );
    expect(
      courierStatusLabel(CourierJobStatus.waitingForNodes, 3),
      'Waiting for Courier space',
    );
    expect(
      courierStatusLabel(CourierJobStatus.stored, 2),
      'Deposited · waiting for recipient',
    );
    expect(courierStatusLabel(CourierJobStatus.delivered, 2), isNull);
  });
}
