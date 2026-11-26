import 'dart:async';

import 'package:cht/delivery/delivery_router.dart';
import 'package:cht/relay/relay_provider_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a durable Courier queue is not cooled down because its recipient is offline', () async {
    var now = 1000;
    final router = DeliveryRouter(clock: () => now, jitter: () => 0.5);
    final routes = [
      DeliveryRoute(
        id: 'courier',
        kind: DeliveryRouteKind.courier,
        authenticated: true,
        send: () async {},
      ),
    ];
    expect(
      await router.send('queued', routes, isCurrent: () => true),
      'courier',
    );
    now += 60000;
    expect(
      await router.send('queued', routes, isCurrent: () => true),
      'courier',
    );
    expect(router.healthFor('courier').cooldownUntil, 0);
  });
  test('blocked Direct times out to live relay without claiming a recipient receipt', () async {
    final sent = <String>[],
        router = DeliveryRouter(
          attemptTimeout: const Duration(milliseconds: 10),
        );
    final never = Completer<void>();
    final chosen = await router.send('original-id', [
      DeliveryRoute(
        id: 'direct',
        kind: DeliveryRouteKind.direct,
        authenticated: true,
        send: () => never.future,
      ),
      DeliveryRoute(
        id: 'relay',
        kind: DeliveryRouteKind.relay,
        authenticated: true,
        send: () async {
          sent.add('original-id');
        },
      ),
    ], isCurrent: () => true);
    expect(chosen, 'relay');
    expect(sent, ['original-id']);
    expect(router.pendingCount, 1);
    router.acknowledge('original-id');
    expect(router.pendingCount, 0);
    never.complete();
  });
  test(
    'unreceipted retry uses a healthy alternative until Direct recovers',
    () async {
      var now = 1000;
      final sent = <String>[],
          router = DeliveryRouter(clock: () => now, jitter: () => 0.5);
      List<DeliveryRoute> routes() => [
        for (final kind in [DeliveryRouteKind.direct, DeliveryRouteKind.relay])
          DeliveryRoute(
            id: kind.name,
            kind: kind,
            authenticated: true,
            send: () async {
              sent.add(kind.name);
            },
          ),
      ];
      await router.send('a', routes(), isCurrent: () => true);
      now += 5000;
      await router.send('a', routes(), isCurrent: () => true);
      router.acknowledge('a');
      await router.send('b', routes(), isCurrent: () => true);
      now += 5000;
      await router.send('c', routes(), isCurrent: () => true);
      expect(sent, ['direct', 'relay', 'relay', 'direct']);
      expect(router.healthFor('direct').cooldownUntil, greaterThan(1000));
    },
  );
  test(
    'Relay receipts do not pin new messages after Direct authenticates',
    () async {
      final router = DeliveryRouter();
      var directReady = false;
      List<DeliveryRoute> routes() => [
        DeliveryRoute(
          id: 'direct',
          kind: DeliveryRouteKind.direct,
          authenticated: directReady,
          send: () async {},
        ),
        DeliveryRoute(
          id: 'relay',
          kind: DeliveryRouteKind.relay,
          authenticated: true,
          send: () async {},
        ),
      ];
      expect(
        await router.send('first', routes(), isCurrent: () => true),
        'relay',
      );
      router.acknowledge('first', routeId: 'relay');
      expect(
        await router.send('in-flight', routes(), isCurrent: () => true),
        'relay',
      );
      directReady = true;
      expect(
        await router.send('next', routes(), isCurrent: () => true),
        'direct',
      );
      // Session negotiation still uses the original route-affinity policy.
      expect(router.rank(routes()).first.id, 'relay');
      expect(router.pendingCount, 2);
      router.acknowledge('in-flight', routeId: 'relay');
      expect(router.pendingCount, 1);
      expect(
        await router.send('last', routes(), isCurrent: () => true),
        'direct',
      );
    },
  );
  test('lock during a slow attempt stops fallback and unauthenticated routes never send', () async {
    var active = true;
    final gate = Completer<void>(), sent = <String>[];
    final router = DeliveryRouter();
    final job = router.send('a', [
      DeliveryRoute(
        id: 'untrusted',
        kind: DeliveryRouteKind.direct,
        authenticated: false,
        send: () async {
          sent.add('bad');
        },
      ),
      DeliveryRoute(
        id: 'direct',
        kind: DeliveryRouteKind.direct,
        authenticated: true,
        send: () => gate.future,
      ),
      DeliveryRoute(
        id: 'relay',
        kind: DeliveryRouteKind.relay,
        authenticated: true,
        send: () async {
          sent.add('relay');
        },
      ),
    ], isCurrent: () => active);
    final check = expectLater(job, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    active = false;
    gate.completeError(StateError('closed'));
    await check;
    expect(sent, isEmpty);
  });
  test('provider domains come from local pinned identities and interleave independent providers', () {
    final policy = RelayProviderPolicy({
      'a': 'cloudflare',
      'b': 'cloudflare',
      'c': 'independent',
    });
    expect(
      policy.order([
        'u1',
        'u2',
        'u3',
        'u4',
      ], identityFor: (u) => {'u1': 'a', 'u2': 'b', 'u3': 'c'}[u]),
      ['u1', 'u3', 'u4', 'u2'],
    );
    expect(policy.independentDomains(['a', 'b']), 1);
    expect(policy.independentDomains(['a', 'c']), 2);
    expect(policy.independentDomains(['unknown1', 'unknown2']), 0);
  });
}
