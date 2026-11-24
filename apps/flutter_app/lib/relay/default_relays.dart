import 'dart:convert';

import 'relay_network.dart' show normalizePublicRelayUrl;
import 'relay_provider_policy.dart';

// Public identity pins only; private relay keys are Workers secrets.
const defaultDataRelays = <String, String>{
  'wss://relay1.chta.app/cht':
      'd957ac2006126e021f0bd1146cd54413e83b0be06d2c584d92a0ddccf5f1137a',
  'wss://relay2.chta.app/cht':
      '8099933def079e6074c4b8f0c0662b1bc5c67b1e8d771348e008549c9b7d4eaf',
  'wss://relay3.chta.app/cht':
      '9d8748230bb14f7a5f2e4fc1d4b31a69291bd7eae0dd497f61aff15e7959feb5',
};

/// Operator-provided release configuration. This input never comes from relay
/// advertisements, and extra endpoints are pinned before attempting a dial.
({Map<String, String> pins, RelayProviderPolicy policy}) configuredDataRelays([
  String source = const String.fromEnvironment('CHTA_RELAY_PROVIDERS'),
]) {
  final pins = {...defaultDataRelays};
  final domains = {for (final id in pins.values) id: 'cloudflare'};
  if (source.isNotEmpty && source.length <= 16384) {
    try {
      final configured = jsonDecode(source);
      if (configured is List && configured.length <= 16) {
        for (final entry in configured) {
          if (entry is! Map ||
              entry['endpoint'] is! String ||
              entry['id'] is! String ||
              entry['domain'] is! String) {
            continue;
          }
          final endpoint = entry['endpoint'] as String,
              id = entry['id'] as String,
              domain = entry['domain'] as String;
          if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(id) ||
              !RegExp(r'^[a-z0-9][a-z0-9.-]{0,63}$').hasMatch(domain) ||
              pins.containsKey(endpoint) ||
              domains.containsKey(id)) {
            continue;
          }
          try {
            if (normalizePublicRelayUrl(endpoint) != endpoint) continue;
          } catch (_) {
            continue;
          }
          pins[endpoint] = id;
          domains[id] = domain;
        }
      }
    } catch (_) {
      /* Invalid operator input leaves the built-in pins intact. */
    }
  }
  return (pins: Map.unmodifiable(pins), policy: RelayProviderPolicy(domains));
}
