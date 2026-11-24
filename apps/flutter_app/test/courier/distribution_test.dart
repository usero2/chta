import 'dart:math';

import 'package:cht/courier/courier_models.dart';
import 'package:cht/courier/distribution.dart';
import 'package:flutter_test/flutter_test.dart';

CourierNode node(int n, {int free = 1024 * 1024 * 1024, int? root}) =>
    CourierNode.verified(
      nodeId: n.toRadixString(16).padLeft(64, '0'),
      ownerId: 'did:cht:${(root ?? n).toRadixString(16).padLeft(64, '0')}',
      certificate: const {},
      routes: ['wss://node$n.example.com/cht'],
      expiresAt: 1000000,
      freeBytes: free,
    );
void main() {
  test('root-addressed relay fanout cannot give a sibling device the other partition', () {
    final a = node(1, root: 7), b = node(2, root: 7), c = node(3, root: 8);
    final siblings = DistributionPlan.allocate(
      count: 2,
      nodes: [a, b],
      everAssigned: {},
      now: 1,
    );
    expect(siblings.canDeposit, isFalse);
    final split = DistributionPlan.allocate(
      count: 2,
      nodes: [a, c],
      everAssigned: {},
      now: 1,
    );
    expect(split.canDeposit, isTrue);
    final churn = DistributionPlan.allocate(
      count: 2,
      nodes: [b, c],
      everAssigned: split.everAssigned,
      now: 1,
      routingRoots: {a.nodeId: a.ownerId, c.nodeId: c.ownerId},
    );
    expect(churn.canDeposit, isFalse);
  });
  test('reallocation does not reserve acknowledged packages twice', () {
    final original = {node(1).nodeId: IndexBitmap(2)..mark(0)};
    final p = DistributionPlan.allocate(
      count: 2,
      nodes: [node(1, free: 0), node(3, free: 40)],
      everAssigned: original,
      storedOnNodes: original,
      now: 1,
      packageSizes: [40, 40],
    );
    expect(p.canDeposit, isTrue);
    expect(p.assignments[node(1).nodeId]!.contains(0), isTrue);
  });
  test('one certified node or URL aliases wait; two partition without a complete set', () {
    for (final nodes in [
      [node(1)],
      [node(1), node(1)],
    ]) {
      final p = DistributionPlan.allocate(
        count: 2,
        nodes: nodes,
        everAssigned: {},
        now: 1,
      );
      expect(p.canDeposit, isFalse);
      expect(p.assignments, isEmpty);
    }
    final p = DistributionPlan.allocate(
      count: 2,
      nodes: [node(1), node(2)],
      everAssigned: {},
      now: 1,
    );
    expect(p.canDeposit, isTrue);
    expect(p.assignments.length, 2);
    for (final bitmap in p.everAssigned.values) {
      expect(bitmap.length, lessThan(2));
    }
  });
  test('three-node replication and deterministic churn never hand one node the full set', () {
    var ever = <String, IndexBitmap>{};
    final random = Random(47);
    for (var round = 0; round < 300; round++) {
      final nodes = [
        for (var n = 1; n <= 8; n++)
          if (random.nextBool()) node(n),
      ];
      final p = DistributionPlan.allocate(
        count: 17,
        nodes: nodes,
        everAssigned: ever,
        now: 1,
        replicas: 2,
      );
      if (p.canDeposit) {
        ever = p.everAssigned;
        for (final b in ever.values) {
          expect(b.length, lessThan(17));
        }
        for (var i = 0; i < 17; i++) {
          expect(
            p.assignments.values.where((b) => b.contains(i)).length,
            greaterThanOrEqualTo(1),
          );
        }
      }
    }
    final recovered = ever.map(
      (id, b) => MapEntry(id, IndexBitmap.fromEncoded(17, b.encoded)),
    );
    for (final id in ever.keys) {
      expect(recovered[id]!.encoded, ever[id]!.encoded);
    }
  });
  test('capacity, unavailable nodes, historical node bound and tiny payloads never weaken privacy', () {
    final sizes = [40, 40];
    final p = DistributionPlan.allocate(
      count: 2,
      nodes: [node(1, free: 39), node(2)],
      everAssigned: {},
      now: 1,
      packageSizes: sizes,
    );
    expect(p.canDeposit, isFalse);
    final ever = {
      node(1).nodeId: IndexBitmap(2)..mark(0),
      node(2).nodeId: IndexBitmap(2)..mark(1),
    };
    final replacement = DistributionPlan.allocate(
      count: 2,
      nodes: [node(1), node(3)],
      everAssigned: ever,
      now: 1,
      packageSizes: sizes,
    );
    expect(replacement.canDeposit, isTrue);
    expect(replacement.everAssigned[node(1).nodeId]!.length, 1);
    expect(replacement.assignments[node(3).nodeId]!.contains(1), isTrue);
  });
}
