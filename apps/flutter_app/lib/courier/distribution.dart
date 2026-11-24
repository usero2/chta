import 'courier_models.dart';

/// Each certificate keeps an exact historical bitmap, across URL changes and retries.
class DistributionPlan {
  DistributionPlan._(this.assignments, this.everAssigned, this.reason);
  final Map<String, IndexBitmap> assignments, everAssigned;
  final String? reason;
  bool get canDeposit => reason == null;
  static DistributionPlan allocate({
    required int count,
    required List<CourierNode> nodes,
    required Map<String, IndexBitmap> everAssigned,
    Map<String, IndexBitmap> storedOnNodes = const {},
    Map<String, String> routingRoots = const {},
    required int now,
    List<int>? packageSizes,
    int replicas = 1,
  }) {
    if (count < 2 ||
        count > courierMaxPackages ||
        everAssigned.length > courierMaxHistoricalNodes ||
        replicas < 1 ||
        replicas > 2) {
      throw const FormatException('Invalid Courier allocation');
    }
    if (everAssigned.entries.any(
      (e) =>
          !courierHex(e.key, 64) ||
          e.value.count != count ||
          e.value.length >= count,
    )) {
      throw const FormatException('Unsafe historical Courier allocation');
    }
    final original = everAssigned.map((k, v) => MapEntry(k, v.copy()));
    if (storedOnNodes.entries.any(
      (e) =>
          e.value.count != count ||
          !original.containsKey(e.key) ||
          e.value.intersectionLength(original[e.key]!) != e.value.length,
    )) {
      throw const FormatException('Invalid stored package bitmap');
    }
    DistributionPlan waiting(String reason) =>
        DistributionPlan._({}, original, reason);
    final sizes = packageSizes ?? List.filled(count, courierPackageBytes + 40);
    if (sizes.length != count ||
        sizes.any((n) => n < 40 || n > courierPackageBytes + 40)) {
      throw const FormatException('Invalid package sizes');
    }
    int cost(String node, int index) =>
        storedOnNodes[node]?.contains(index) == true ? 0 : sizes[index];
    final unique = <String, CourierNode>{};
    for (final node in nodes) {
      if (node.eligible(now)) unique[node.nodeId] = node;
    }
    final eligible = unique.values.toList()
      ..sort((a, b) {
        final knownA = original.containsKey(a.nodeId),
            knownB = original.containsKey(b.nodeId);
        if (knownA != knownB) return knownA ? -1 : 1;
        final capacity = b.freeBytes.compareTo(a.freeBytes);
        return capacity != 0 ? capacity : a.nodeId.compareTo(b.nodeId);
      });
    // Relays fan out to every session of a routing root. Reserve that root to
    // its original node for the entire job, even when the node goes offline.
    final reserved = <String, String>{};
    for (final entry in routingRoots.entries) {
      if (!original.containsKey(entry.key) ||
          reserved.containsKey(entry.value)) {
        throw const FormatException('Unsafe historical routing roots');
      }
      reserved[entry.value] = entry.key;
    }
    final distinct = <CourierNode>[];
    for (final node in eligible) {
      final bound = reserved.putIfAbsent(node.ownerId, () => node.nodeId);
      if (bound == node.nodeId) distinct.add(node);
    }
    final selected = distinct
        .where((n) => original.containsKey(n.nodeId))
        .toList();
    selected.addAll(
      distinct
          .where((n) => !original.containsKey(n.nodeId))
          .take(courierMaxHistoricalNodes - original.length),
    );
    if (selected.length < 2) return waiting('Waiting for two Couriers');
    final history = original.map((k, v) => MapEntry(k, v.copy())),
        assigned = <String, IndexBitmap>{};
    final budget = {for (final n in selected) n.nodeId: n.freeBytes};
    final order = List.generate(count, (i) => i)
      ..sort((a, b) {
        final size = sizes[b].compareTo(sizes[a]);
        return size != 0 ? size : a.compareTo(b);
      });
    final copies = replicas == 2 && selected.length >= 3 && count >= 3 ? 2 : 1;
    for (final index in order) {
      for (var replica = 0; replica < copies; replica++) {
        final candidates = selected.where((n) {
          final h = history[n.nodeId];
          return assigned[n.nodeId]?.contains(index) != true &&
              budget[n.nodeId]! >= cost(n.nodeId, index) &&
              ((h?.length ?? 0) + (h?.contains(index) == true ? 0 : 1)) < count;
        }).toList();
        candidates.sort((a, b) {
          final reuseA = history[a.nodeId]?.contains(index) == true,
              reuseB = history[b.nodeId]?.contains(index) == true;
          if (reuseA != reuseB) return reuseA ? -1 : 1;
          final load = (assigned[a.nodeId]?.length ?? 0).compareTo(
            assigned[b.nodeId]?.length ?? 0,
          );
          if (load != 0) return load;
          final space = budget[b.nodeId]!.compareTo(budget[a.nodeId]!);
          return space != 0 ? space : a.nodeId.compareTo(b.nodeId);
        });
        if (candidates.isEmpty) return waiting('Waiting for Courier capacity');
        final id = candidates.first.nodeId;
        assigned.putIfAbsent(id, () => IndexBitmap(count)).mark(index);
        history.putIfAbsent(id, () => IndexBitmap(count)).mark(index);
        budget[id] = budget[id]! - cost(id, index);
      }
    }
    if (assigned.length < 2) return waiting('Waiting for two Couriers');
    return DistributionPlan._(
      Map.unmodifiable(assigned),
      Map.unmodifiable(history),
      null,
    );
  }
}
