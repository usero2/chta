import 'dart:async';

import 'package:cht/chat/cache_policy.dart';
import 'package:cht/courier/courier_service.dart';
import 'package:cht/relay/relay_network.dart';
import 'package:flutter_test/flutter_test.dart';

import '../relay/relay_network_test.dart' as relay;
import 'courier_journal_test.dart' show Disk;
import 'courier_store_test.dart' as f;
import 'courier_transport_test.dart' as wire;
import 'sender_jobs_test.dart' as jobs_fixture;

class Crypto extends wire.Crypto {
  Crypto() : super(wire.host, node: f.nodeId);
  @override
  Future<Map<String, Object?>> deliveryCall(
    String op,
    Map<String, Object?> args,
  ) async {
    if (op == 'nodeCertificate') {
      return {
        'state': 'opaque-protected-state',
        'certificate': {'ownerId': wire.host, 'nodeId': f.nodeId},
      };
    }
    return super.deliveryCall(op, args);
  }
}

void main() {
  test('housekeeping never releases a reservation while its sender job is being created', () async {
    final budget = CachePolicy(
      ownerId: wire.host,
      settings: Disk(),
      availableSpace: () async => null,
    );
    await budget.initialize();
    final network = RelayNetwork(relay.Crypto(wire.host)),
        service = CourierService(
          ownerId: wire.host,
          crypto: Crypto(),
          storage: Disk(),
          budget: budget,
          network: network,
          carrier: wire.Bus().connect(wire.host),
          canHost: false,
          clock: () => 2000,
        );
    await service.start();
    final entered = Completer<void>(),
        release = Completer<void>(),
        id = 'e' * 32,
        key = 'courier_send_${'e' * 32}';
    final pending = service.jobs.withPreparation(id, () async {
      await budget.resizeCourierReservation(key, 1048576, 0);
      entered.complete();
      await release.future;
    });
    await entered.future;
    await service.refresh();
    expect(budget.entrySize(key), 1048576);
    release.complete();
    await pending;
    await service.refresh();
    expect(budget.entrySize(key), 0);
    await service.close();
    await network.close();
    budget.dispose();
  });
  test('terminal sender cleanup preserves only bounded receipt metadata and recovers orphan reservations', () async {
    final budget = CachePolicy(
      ownerId: wire.host,
      settings: Disk(),
      availableSpace: () async => null,
    );
    await budget.initialize();
    final network = RelayNetwork(relay.Crypto(wire.host));
    final service = CourierService(
      ownerId: wire.host,
      crypto: Crypto(),
      storage: Disk(),
      budget: budget,
      network: network,
      carrier: wire.Bus().connect(wire.host),
      canHost: false,
      clock: () => 2000,
    );
    await service.start();
    await jobs_fixture.prepare(service.jobs);
    await service.jobs.cancel('a' * 32);
    await budget.resizeCourierReservation(
      'courier_send_${'a' * 32}',
      2 * 1024 * 1024,
      1024 * 1024,
    );
    await budget.resizeCourierReservation(
      'courier_send_${'f' * 32}',
      1024 * 1024,
      0,
    );
    await service.refresh();
    expect(service.jobs.jobs.single.readyCount, 0);
    expect(budget.entrySize('courier_send_${'a' * 32}'), 65536);
    expect(budget.entrySize('courier_send_${'f' * 32}'), 0);
    await service.close();
    await network.close();
    budget.dispose();
  });
  test('Desktop starts a persistent node automatically, manual stop survives refresh, lock stops all callbacks', () async {
    var current = true;
    final disk = Disk(),
        budget = CachePolicy(
          ownerId: wire.host,
          settings: Disk(),
          availableSpace: () async => null,
        );
    await budget.initialize();
    final network = RelayNetwork(relay.Crypto(wire.host));
    final bus = wire.Bus();
    final service = CourierService(
      ownerId: wire.host,
      crypto: Crypto(),
      storage: disk,
      budget: budget,
      network: network,
      carrier: bus.connect(wire.host),
      canHost: true,
      clock: () => f.now,
      isCurrent: () => current,
    );
    await service.start();
    expect(service.hosting, isTrue);
    expect(service.advertisement?['signerId'], f.nodeId);
    final id = service.advertisement?['signerId'];
    await service.setHosting(false);
    await service.refresh();
    expect(service.hosting, isFalse);
    expect(service.directory.nodes, isEmpty);
    await service.setHosting(true);
    expect(service.advertisement?['signerId'], id);
    current = false;
    await service.refresh();
    expect(service.hosting, isFalse);
    await service.close();
    await network.close();
    budget.dispose();
  });
  test(
    'Android and Web use Courier clients without hosting third-party data',
    () async {
      final budget = CachePolicy(
        ownerId: wire.host,
        settings: Disk(),
        availableSpace: () async => null,
      );
      await budget.initialize();
      final network = RelayNetwork(relay.Crypto(wire.host));
      final service = CourierService(
        ownerId: wire.host,
        crypto: Crypto(),
        storage: Disk(),
        budget: budget,
        network: network,
        carrier: wire.Bus().connect(wire.host),
        canHost: false,
        clock: () => f.now,
      );
      await service.start();
      expect(service.hosting, isFalse);
      await expectLater(service.setHosting(true), throwsStateError);
      await service.close();
      await network.close();
      budget.dispose();
    },
  );
}
