import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'relay_crypto_bridge.dart';
import 'relay_socket.dart';

typedef RelayConnector = Future<RelaySocket> Function(String endpoint);
typedef RoutedFrame = void Function(
  String endpoint,
  Map<String, dynamic> frame,
);

String normalizeRelayUrl(String source) {
  var uri = Uri.parse(source.trim());
  if (uri.scheme == 'https') uri = uri.replace(scheme: 'wss');
  final local =
      uri.host == 'localhost' || uri.host == '127.0.0.1' || uri.host == '::1';
  if ((!local && uri.scheme != 'wss') ||
      (local && !['ws', 'wss'].contains(uri.scheme)) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      source.length > 2048) {
    throw const FormatException('Use an https:// or wss:// relay address.');
  }
  if (uri.path.isEmpty || uri.path == '/') uri = uri.replace(path: '/cht');
  if (uri.path != '/cht') {
    throw const FormatException('Relay address must end in /cht.');
  }
  return uri.toString();
}

/// Public routes learned from a QR or peer must never target local services.
String normalizePublicRelayUrl(String source) {
  final endpoint = normalizeRelayUrl(source);
  final uri = Uri.parse(endpoint);
  final host = uri.host.replaceAll('[', '').replaceAll(']', '').toLowerCase();
  final octets = host.split('.').map(int.tryParse).toList();
  final privateIpv4 =
      octets.length == 4 &&
      octets.every((v) => v != null) &&
      (octets[0] == 0 ||
          octets[0] == 10 ||
          octets[0] == 127 ||
          octets[0] == 169 && octets[1] == 254 ||
          octets[0] == 172 && octets[1]! >= 16 && octets[1]! <= 31 ||
          octets[0] == 192 && octets[1] == 168 ||
          octets[0] == 100 && octets[1]! >= 64 && octets[1]! <= 127 ||
          octets[0]! >= 224);
  if (uri.scheme != 'wss' ||
      privateIpv4 ||
      host.contains(':') ||
      !host.contains('.') ||
      host.endsWith('.localhost') ||
      host.endsWith('.local') ||
      host.endsWith('.internal')) {
    throw const FormatException('Use a public relay QR.');
  }
  return endpoint;
}

enum RelayConnectionStatus { online, connecting, unavailable, disconnected }

const relayUnavailableRemovalAge = Duration(days: 7);

@immutable
class RelayActivity {
  const RelayActivity({
    this.addedAtMilliseconds,
    this.updatedAtMilliseconds,
    this.lastUsedAtMilliseconds,
  });
  final int? addedAtMilliseconds;
  final int? updatedAtMilliseconds;
  final int? lastUsedAtMilliseconds;

  Map<String, int?> toJson() => {
    'addedAtMilliseconds': addedAtMilliseconds,
    'updatedAtMilliseconds': updatedAtMilliseconds,
    'lastUsedAtMilliseconds': lastUsedAtMilliseconds,
  };
}

class RelayNetwork extends ChangeNotifier {
  RelayNetwork(this.crypto, {RelayConnector? connector, int Function()? clock})
    : connector = connector ?? openRelaySocket,
      _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);
  final RelayCryptoBridge crypto;
  final RelayConnector connector;
  final int Function() _clock;
  final _activity = <String, RelayActivity>{};
  final _userLockedRelays = <String>{};
  final _unavailableSince = <String, int>{};
  bool _notifyActivityOnSave = false;
  RelayActivity activityFor(String endpoint) =>
      _activity[endpoint] ?? const RelayActivity();
  RelayConnectionStatus statusFor(String endpoint) {
    if (_closed) return RelayConnectionStatus.disconnected;
    final link = _links[endpoint];
    if (link != null) {
      return link.registered
          ? RelayConnectionStatus.online
          : RelayConnectionStatus.connecting;
    }
    return _failures.containsKey(endpoint)
        ? RelayConnectionStatus.unavailable
        : RelayConnectionStatus.disconnected;
  }

  bool _knows(String endpoint) =>
      _activity.containsKey(endpoint) ||
      seeds.contains(endpoint) ||
      pins.containsKey(endpoint) ||
      _userLockedRelays.contains(endpoint) ||
      records.values.any((record) => record['endpoint'] == endpoint);

  void _metadataChanged(String endpoint, {bool added = false}) {
    final previous = activityFor(endpoint);
    _activity[endpoint] = RelayActivity(
      addedAtMilliseconds: added ? now : previous.addedAtMilliseconds,
      updatedAtMilliseconds: now,
      lastUsedAtMilliseconds: previous.lastUsedAtMilliseconds,
    );
  }

  void _routeUsed(String endpoint) {
    final previous = activityFor(endpoint);
    _activity[endpoint] = RelayActivity(
      addedAtMilliseconds: previous.addedAtMilliseconds,
      updatedAtMilliseconds: previous.updatedAtMilliseconds,
      lastUsedAtMilliseconds: now,
    );
    _schedulePersist(notifyActivity: true);
  }

  void _pruneActivity() {
    final retained = <String>{
      ...seeds,
      ...pins.keys,
      ..._links.keys,
      ...records.values.map((record) => record['endpoint'] as String),
      ..._userLockedRelays,
      ?hostedEndpoint,
    };
    _activity.removeWhere((endpoint, _) => !retained.contains(endpoint));
    while (_activity.length > 1008) {
      final removable = _activity.keys
          .where(
            (endpoint) =>
                !seeds.contains(endpoint) &&
                !_links.containsKey(endpoint) &&
                !_userLockedRelays.contains(endpoint),
          )
          .firstOrNull;
      _activity.remove(removable ?? _activity.keys.first);
    }
  }

  void _schedulePersist({bool notifyActivity = false}) {
    if (_closed) return;
    _notifyActivityOnSave |= notifyActivity;
    _saveTimer ??= Timer(const Duration(seconds: 1), () {
      _saveTimer = null;
      unawaited(_persist());
      if (_notifyActivityOnSave && !_closed) notifyListeners();
      _notifyActivityOnSave = false;
    });
  }

  final seeds = <String>[];
  final records = <String, Map<String, dynamic>>{};
  final pins = <String, String>{};
  Set<String> get userLockedRelays => Set.unmodifiable(_userLockedRelays);
  bool isRelayLocked(String url) => _userLockedRelays.contains(url);

  Future<void> setRelayLocked(String url, bool locked) async {
    final endpoint = normalizeRelayUrl(url);
    if (endpoint != url) {
      throw const FormatException('Relay address must be normalized first.');
    }
    if (locked) {
      _userLockedRelays.add(endpoint);
    } else {
      _userLockedRelays.remove(endpoint);
    }
    _pruneActivity();
    await _persist();
    if (!locked) _pruneFailedEndpoint(endpoint);
    if (!_closed) notifyListeners();
  }

  void _pruneFailedEndpoint(String endpoint) {
    final firstUnavailable = _unavailableSince[endpoint];
    if (firstUnavailable == null ||
        _userLockedRelays.contains(endpoint) ||
        !_failures.containsKey(endpoint) ||
        _links.containsKey(endpoint) ||
        endpoint == hostedEndpoint ||
        endpoint == activeEndpoint ||
        now - firstUnavailable < relayUnavailableRemovalAge.inMilliseconds) {
      return;
    }
    seeds.remove(endpoint);
    records.removeWhere((_, record) => record['endpoint'] == endpoint);
    _preferredRoutes.remove(endpoint);
    _activity.remove(endpoint);
    _failures.remove(endpoint);
    _unavailableSince.remove(endpoint);
    _pruneActivity();
    _schedulePersist();
    if (!_closed) notifyListeners();
  }

  final _links = <String, _Link>{};
  final _preferredRoutes = <String>[];
  List<String> get preferredRoutes => List.unmodifiable(_preferredRoutes);
  final _failures = <String, (int, int)>{};
  Timer? _timer;
  Timer? _saveTimer;
  bool _closed = false;
  bool _ticking = false;
  int connectionLimit = 50;
  String? activeEndpoint;
  int _catalogOffset = 0;
  int get connectingCount =>
      _links.values.where((link) => !link.registered).length;
  Future<void> setConnectionLimit(int value) async {
    if (value < 50 || value > 1000) {
      throw const FormatException('Choose 50 to 1000 relay connections.');
    }
    connectionLimit = value;
    for (final entry in _links.entries.toList().reversed) {
      if (_links.length <= connectionLimit) break;
      if (entry.key == activeEndpoint) continue;
      _links.remove(entry.key);
      unawaited(entry.value.subscription?.cancel());
      unawaited(entry.value.socket?.close());
    }
    await _persist();
    await tick();
    if (!_closed) notifyListeners();
  }

  List<Map<String, dynamic>> _catalogBatch() {
    final entries = records.values.toList();
    if (entries.isEmpty) return [];
    final result = List.generate(
      min(64, entries.length),
      (index) => entries[(_catalogOffset + index) % entries.length],
    );
    _catalogOffset = (_catalogOffset + result.length) % entries.length;
    return result;
  }

  String? error;
  bool hostEnabled = false;
  String? hostedEndpoint;
  Future<void> setHostEnabled(bool value) async {
    hostEnabled = value;
    await _persist();
  }

  Future<void> addHostedEndpoint(String? previous, String endpoint) async {
    final known = _knows(endpoint);
    previous ??= hostedEndpoint;
    if (previous != null && previous != endpoint) {
      await forget(previous);
    }
    hostedEndpoint = endpoint;
    // The local hosted endpoint is the bootstrap route for this Desktop.
    seeds.remove(endpoint);
    seeds.insert(0, endpoint);
    if (seeds.length > 8) seeds.removeLast();
    if (!known) _metadataChanged(endpoint, added: true);
    _pruneActivity();
    await _persist();
    await tick();
    notifyListeners();
  }

  RoutedFrame? onFrame;
  final _frameListeners = <RoutedFrame>{};
  void addFrameListener(RoutedFrame listener) {
    if (!_closed) _frameListeners.add(listener);
  }
  void removeFrameListener(RoutedFrame listener) => _frameListeners.remove(listener);
  ValueChanged<String>? onDisconnected;
  VoidCallback? onReady;
  List<String> get online => _links.entries
      .where((e) => e.value.registered)
      .map((e) => e.key)
      .toList();
  bool get enabled =>
      seeds.isNotEmpty || records.isNotEmpty || _userLockedRelays.isNotEmpty;
  int get now => _clock();

  List<String> get contactRelayUrls =>
      <String>{
            ...online,
            ...records.values
                .where((r) => (r['expiresAt'] as int) > now)
                .map((r) => r['endpoint'] as String),
          }
          .where(
            (url) =>
                url.startsWith('wss://') &&
                url.length <= 256 &&
                ![
                  'localhost',
                  '127.0.0.1',
                  '::1',
                ].contains(Uri.parse(url).host),
          )
          .take(2)
          .toList();

  Future<void> addContactRoutes(List<String> urls) async {
    _preferredRoutes
      ..clear()
      ..addAll(urls.take(2).map(normalizeRelayUrl));
    for (final url in urls.take(2)) {
      final endpoint = normalizeRelayUrl(url);
      final known = _knows(endpoint);
      if (!seeds.contains(endpoint)) {
        if (seeds.length >= 8) seeds.removeLast();
        seeds.insert(0, endpoint);
        _metadataChanged(endpoint, added: !known);
      }
      _failures.remove(endpoint);
    }
    _pruneActivity();
    await _persist();
    await tick();
    if (!_closed) notifyListeners();
  }

  Future<void> initialize() async {
    try {
      final source = await crypto.loadRelayState();
      if (source.length <= 8388608 && source.isNotEmpty) {
        final saved = jsonDecode(source) as Map<String, dynamic>;
        hostEnabled = saved['hostEnabled'] == true;
        final limit = saved['connectionLimit'];
        if (limit is int && limit >= 50 && limit <= 1000) {
          connectionLimit = limit;
        }
        hostedEndpoint = saved['hostedEndpoint'] as String?;
        for (final value in (saved['seeds'] as List? ?? []).take(8)) {
          try {
            seeds.add(normalizeRelayUrl(value as String));
          } catch (_) {}
        }
        for (final entry in (saved['pins'] as Map? ?? {}).entries.take(1008)) {
          if (entry.key is String && entry.value is String) {
            pins[entry.key as String] = entry.value as String;
          }
        }
        for (final value in (saved['userLockedRelays'] as List? ?? []).take(
          1008,
        )) {
          if (value is! String) continue;
          try {
            final endpoint = normalizeRelayUrl(value);
            if (endpoint == value) _userLockedRelays.add(endpoint);
          } catch (_) {}
        }
        final unavailable = saved['unavailableSince'];
        if (unavailable is Map) {
          for (final entry in unavailable.entries.take(1008)) {
            if (entry.key is! String ||
                entry.value is! int ||
                (entry.value as int) < 0 ||
                (entry.value as int) > 8640000000000000) {
              continue;
            }
            try {
              final endpoint = normalizeRelayUrl(entry.key as String);
              if (endpoint == entry.key) {
                _unavailableSince[endpoint] = entry.value as int;
              }
            } catch (_) {}
          }
        }
        // Restore local history before merging cached records. Missing dates
        // in older caches stay unknown rather than acquiring a false add date.
        final history = saved['activity'];
        if (history is Map) {
          for (final entry in history.entries.take(1008)) {
            if (entry.key is! String || entry.value is! Map) continue;
            final value = entry.value as Map;
            int? timestamp(String key) =>
                value[key] is int &&
                    (value[key] as int) >= 0 &&
                    (value[key] as int) <= 8640000000000000
                ? value[key] as int
                : null;
            _activity[entry.key as String] = RelayActivity(
              addedAtMilliseconds: timestamp('addedAtMilliseconds'),
              updatedAtMilliseconds: timestamp('updatedAtMilliseconds'),
              lastUsedAtMilliseconds: timestamp('lastUsedAtMilliseconds'),
            );
          }
        }
        final entries = saved['relays'];
        if (entries is List && entries.length <= 1000) {
          for (var start = 0; start < entries.length; start += 64) {
            await _merge(
              entries.sublist(start, min(start + 64, entries.length)),
              restoring: true,
            );
          }
        }
        _pruneActivity();
      }
    } catch (_) {
      error = 'Could not load relays. Add a relay URL.';
    }
    if (_closed) return;
    _timer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(tick()),
    );
    await tick();
  }

  Future<void> addSeed(String source) async {
    final endpoint = normalizeRelayUrl(source);
    final known = _knows(endpoint);
    if (!seeds.contains(endpoint)) {
      if (seeds.length >= 8) {
        throw const FormatException('Keep up to 8 starting relay addresses.');
      }
      seeds.add(endpoint);
      _metadataChanged(endpoint, added: !known);
    }
    error = null;
    _failures.remove(endpoint);
    await _persist();
    await tick();
    notifyListeners();
  }

  Future<void> importList(String source) async {
    if (!source.trimLeft().startsWith('{')) {
      await addSeed(source);
      return;
    }
    if (source.length > 8388608) {
      throw const FormatException('Relay list is too large.');
    }
    final value = jsonDecode(source) as Map<String, dynamic>;
    if (value['version'] != 1 ||
        value['relays'] is! List ||
        (value['relays'] as List).length > 1000) {
      throw const FormatException('Invalid relay list.');
    }
    final entries = value['relays'] as List;
    for (var start = 0; start < entries.length; start += 64) {
      await _merge(entries.sublist(start, min(start + 64, entries.length)));
    }
    if (records.isEmpty) {
      throw const FormatException(
        'No valid, unexpired public relays in this list.',
      );
    }
    await _persist();
    await tick();
    notifyListeners();
  }

  String exportList() => jsonEncode({
    'version': 1,
    'relays': records.values
        .where((r) => (r['expiresAt'] as int) > now)
        .toList(),
  });

  /// Only metadata is exchanged with friends; relay signatures remain mandatory.
  Map<String, dynamic> peerCatalog() {
    final entries = records.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return {
      'protocol': 'cht-relays',
      'version': 1,
      'urls': seeds
          .where((url) {
            try {
              normalizePublicRelayUrl(url);
              return url.length <= 256;
            } catch (_) {
              return false;
            }
          })
          .take(8)
          .toList(),
      'relays': entries
          .where((e) {
            try {
              normalizePublicRelayUrl(e.value['endpoint'] as String);
              return (e.value['expiresAt'] as int) > now;
            } catch (_) {
              return false;
            }
          })
          .map((e) => e.value)
          .toList(),
    };
  }

  Future<void> mergePeerCatalog(Map<String, dynamic> catalog) async {
    final urls = catalog['urls'];
    final relays = catalog['relays'];
    if (catalog['protocol'] != 'cht-relays' ||
        catalog['version'] != 1 ||
        urls is! List ||
        urls.length > 8 ||
        relays is! List ||
        relays.length > 64) {
      return;
    }
    var changed = false;
    for (final value in urls) {
      try {
        if (value is! String || value.length > 256) continue;
        final endpoint = normalizePublicRelayUrl(value);
        if (seeds.length < 8 && !seeds.contains(endpoint)) {
          final known = _knows(endpoint);
          seeds.add(endpoint);
          _metadataChanged(endpoint, added: !known);
          changed = true;
        }
      } catch (_) {
        /* Ignore unsafe hints from authenticated peers too. */
      }
    }
    final publicRecords = relays.where((record) {
      try {
        normalizePublicRelayUrl((record as Map)['endpoint'] as String);
        return true;
      } catch (_) {
        return false;
      }
    }).toList();
    await _merge(publicRecords);
    if (_closed) return;
    if (changed) {
      await _persist();
      notifyListeners();
    }
    await tick();
  }

  Future<void> forget(String endpoint) async {
    if (hostedEndpoint == endpoint) hostedEndpoint = null;
    seeds.remove(endpoint);
    records.removeWhere((_, r) => r['endpoint'] == endpoint);
    pins.remove(endpoint);
    _activity.remove(endpoint);
    _failures.remove(endpoint);
    _unavailableSince.remove(endpoint);
    _userLockedRelays.remove(endpoint);
    _preferredRoutes.remove(endpoint);
    final link = _links.remove(endpoint);
    if (link != null) {
      await link.subscription?.cancel();
      await link.socket?.close();
      onDisconnected?.call(endpoint);
    }
    await _persist();
    notifyListeners();
  }

  Future<void> _merge(Object? values, {bool restoring = false}) async {
    if (values is! List || values.length > 64) return;
    final before = records.length;
    records.removeWhere((_, r) => (r['expiresAt'] as int) <= now);
    var changed = before != records.length;
    for (final value in values) {
      try {
        final source = jsonEncode(value);
        if (source.length > 4096) continue;
        final endpoint = (value as Map)['endpoint'] as String;
        final verified = jsonDecode(
          await crypto.inspectRelayRecord(
            source,
            now,
            seeds.contains(endpoint),
          ),
        ) as Map<String, dynamic>;
        final id = verified['relayId'] as String;
        final previous = records[id];
        if (previous != null &&
            (previous['issuedAt'] as int) >= (verified['issuedAt'] as int)) {
          continue;
        }
        if (previous == null && records.length >= 1000) continue;
        final verifiedEndpoint = verified['endpoint'] as String;
        final known = _knows(verifiedEndpoint);
        records[id] = verified;
        if (!restoring) _metadataChanged(verifiedEndpoint, added: !known);
        changed = true;
      } catch (_) {
        /* Untrusted gossip is ignored; bootstrap peers remain available. */
      }
    }
    if (!restoring) _pruneActivity();
    if (changed && !_closed) {
      _schedulePersist();
      notifyListeners();
    }
  }

  Future<void> _persist() async {
    try {
      await crypto.saveRelayState(
        jsonEncode({
          'version': 1,
          'connectionLimit': connectionLimit,
          'hostEnabled': hostEnabled,
          'hostedEndpoint': hostedEndpoint,
          'seeds': seeds,
          'pins': pins,
          'userLockedRelays': _userLockedRelays.toList()..sort(),
          'unavailableSince': _unavailableSince,
          'relays': records.values.toList(),
          'activity': _activity.map(
            (endpoint, value) => MapEntry(endpoint, value.toJson()),
          ),
        }),
      );
    } catch (_) {
      error = 'Could not save relays. Available until you close chta.';
    }
  }

  Future<void> tick() async {
    if (_closed || _ticking) return;
    _ticking = true;
    try {
      records.removeWhere((_, r) => (r['expiresAt'] as int) <= now);
      _pruneActivity();
      var subscribers = _links.values
          .where((link) => link.catalogSubscribed)
          .length;
      for (final entry in _links.entries.toList()) {
        final link = entry.value;
        if (link.registered && !link.catalogSubscribed && subscribers < 3) {
          link.catalogSubscribed = true;
          link.lastShared = 0;
          subscribers++;
        }
        if (now - link.lastReceived > (link.registered ? 65000 : 15000)) {
          _disconnect(entry.key, link);
          continue;
        }
        if (link.registered && now - link.lastShared > 20000) {
          link.lastShared = now;
          try {
            link.socket!.send(
              jsonEncode({
                'type': link.catalogSubscribed ? 'directory' : 'keepalive',
                if (link.catalogSubscribed) 'relays': _catalogBatch(),
                if (link.catalogSubscribed) 'subscribeCatalog': true,
              }),
            );
          } catch (_) {
            _disconnect(entry.key, link);
          }
        }
      }
      // Dial gradually: the configured total is independent of concurrency.
      final sorted = records.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      final candidates = <String>{
        ..._preferredRoutes,
        ...seeds.take(1),
        ...sorted.map((e) => e.value['endpoint'] as String),
        ...seeds.skip(1),
        ..._userLockedRelays,
      };
      // A new friend's route must get a slot even when the grid is full.
      for (final endpoint in _preferredRoutes) {
        if (_links.containsKey(endpoint) || _links.length < connectionLimit) {
          continue;
        }
        final idle = _links.entries
            .where(
              (e) =>
                  e.key != activeEndpoint && !_preferredRoutes.contains(e.key),
            )
            .lastOrNull;
        if (idle == null) break;
        _links.remove(idle.key);
        unawaited(idle.value.subscription?.cancel());
        unawaited(idle.value.socket?.close());
      }
      var pending = connectingCount;
      var started = false;
      for (final endpoint in candidates) {
        if (_links.length >= connectionLimit || pending >= 6) break;
        if (_links.containsKey(endpoint) ||
            (_failures[endpoint]?.$2 ?? 0) > now) {
          continue;
        }
        final link = _Link(now);
        _links[endpoint] = link;
        started = true;
        pending++;
        unawaited(_connect(endpoint, link));
      }
      if (started && !_closed) notifyListeners();
    } finally {
      _ticking = false;
    }
  }

  Future<void> _connect(String endpoint, _Link link) async {
    try {
      final socket = await connector(endpoint);
      if (_closed || _links[endpoint] != link) {
        await socket.close();
        return;
      }
      link.socket = socket;
      Future<void> serial = Future.value();
      link.subscription = socket.frames.listen(
        (text) {
          serial = serial
              .then((_) async {
                if (_closed || _links[endpoint] != link) return;
                if (text.length > 262144) {
                  throw const FormatException('Relay frame too large');
                }
                link.lastReceived = now;
                final frame = jsonDecode(text) as Map<String, dynamic>;
                switch (frame['type']) {
                  case 'challenge':
                    if (link.challenged) {
                      throw const FormatException('Repeated relay challenge');
                    }
                    link.challenged = true;
                    final record = jsonDecode(
                      await crypto.inspectRelayRecord(
                        jsonEncode(frame['relay']),
                        now,
                        seeds.contains(endpoint),
                      ),
                    ) as Map<String, dynamic>;
                    final id = record['relayId'] as String;
                    if (record['endpoint'] != endpoint ||
                        pins[endpoint] != null && pins[endpoint] != id) {
                      throw const FormatException(
                        'Relay identity changed. Re-add only if you trust it.',
                      );
                    }
                    link.relayId = id;
                    pins[endpoint] = id;
                    while (pins.length > 1008) {
                      final removable = pins.keys
                          .where(
                            (url) =>
                                !seeds.contains(url) &&
                                !_links.containsKey(url),
                          )
                          .firstOrNull;
                      if (removable == null) break;
                      pins.remove(removable);
                    }
                    await _merge(
                      [
                        record,
                        ...((frame['relays'] as List?) ?? []),
                      ].take(64).toList(),
                    );
                    final proof = jsonDecode(
                      await crypto.relayProof(frame['nonce'] as String, id),
                    );
                    if (_closed || _links[endpoint] != link) return;
                    link.catalogSubscribed =
                        _links.values
                            .where((other) => other.catalogSubscribed)
                            .length <
                        3;
                    socket.send(
                      jsonEncode({
                        'type': 'register',
                        'proof': proof,
                        'relays': _catalogBatch(),
                        'subscribeCatalog': link.catalogSubscribed,
                      }),
                    );
                  case 'registered':
                    if (!link.challenged) {
                      throw const FormatException('Missing relay challenge');
                    }
                    if (link.registered) break;
                    link.registered = true;
                    _metadataChanged(endpoint);
                    _failures.remove(endpoint);
                    _unavailableSince.remove(endpoint);
                    error = null;
                    _schedulePersist();
                    notifyListeners();
                    onReady?.call();
                  case 'catalog':
                    await _merge(frame['relays']);
                  case 'route' || 'unreachable':
                    if (link.registered) {
                      if (frame['type'] == 'route') _routeUsed(endpoint);
                      onFrame?.call(endpoint, frame);
                      for (final listener in _frameListeners.toList()) {
                        try { listener(endpoint, frame); } catch (_) {
                          // One protocol consumer cannot disconnect the shared relay.
                        }
                      }
                    }
                }
              })
              .catchError((Object caught) {
                error = '$caught';
                _disconnect(endpoint, link);
              });
        },
        onError: (Object _) => _disconnect(endpoint, link),
        onDone: () => _disconnect(endpoint, link),
      );
    } catch (_) {
      _disconnect(endpoint, link);
    }
  }

  bool send(String endpoint, Map<String, dynamic> envelope) {
    final link = _links[endpoint];
    if (link?.registered != true) return false;
    try {
      link!.socket!.send(jsonEncode(envelope));
      if (envelope['type'] == 'route') _routeUsed(endpoint);
      return true;
    } catch (_) {
      _disconnect(endpoint, link!);
      return false;
    }
  }

  void _disconnect(String endpoint, _Link link) {
    if (_closed || _links[endpoint] != link) return;
    _links.remove(endpoint);
    unawaited(link.subscription?.cancel());
    unawaited(link.socket?.close());
    final attempts = min((_failures[endpoint]?.$1 ?? 0) + 1, 7);
    _failures[endpoint] = (
      attempts,
      now +
          min(60000, 1000 * (1 << (attempts - 1))).toInt() +
          Random().nextInt(500),
    );
    _unavailableSince.putIfAbsent(endpoint, () => now);
    _pruneFailedEndpoint(endpoint);
    _schedulePersist();
    onDisconnected?.call(endpoint);
    notifyListeners();
  }

  Future<void> close() async {
    final pendingSave = _saveTimer?.isActive == true;
    _closed = true;
    _timer?.cancel();
    _saveTimer?.cancel();
    _saveTimer = null;
    if (pendingSave) await _persist();
    for (final link in _links.values.toList()) {
      await link.subscription?.cancel();
      await link.socket?.close();
    }
    _links.clear();
  }
}

class _Link {
  _Link(this.lastReceived);
  RelaySocket? socket;
  StreamSubscription<String>? subscription;
  bool challenged = false;
  bool registered = false;
  bool catalogSubscribed = false;
  String? relayId;
  int lastReceived;
  int lastShared = 0;
}
