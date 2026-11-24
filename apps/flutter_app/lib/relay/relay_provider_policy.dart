/// Operator configuration is trusted local input, never copied from peer catalogs.
class RelayProviderPolicy {
  RelayProviderPolicy([Map<String, String> domains = const {}])
    : _domains = Map.unmodifiable(domains);
  final Map<String, String> _domains;
  String? domainFor(String? pinnedRelayId) => _domains[pinnedRelayId];
  int independentDomains(Iterable<String> pinnedIds) =>
      pinnedIds.map(domainFor).whereType<String>().toSet().length;
  List<String> order(
    Iterable<String> endpoints, {
    required String? Function(String) identityFor,
  }) {
    final unique = endpoints.toSet();
    final buckets = <String, List<String>>{};
    for (final endpoint in unique) {
      final domain = domainFor(identityFor(endpoint)) ?? 'unknown';
      buckets.putIfAbsent(domain, () => []).add(endpoint);
    }
    final result = <String>[];
    for (var i = 0; result.length < unique.length; i++) {
      for (final bucket in buckets.values) {
        if (i < bucket.length) result.add(bucket[i]);
      }
    }
    return result;
  }
}
