import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../account/account_bridge.dart';
import '../relay/relay_crypto_bridge.dart';
import '../relay/relay_network.dart';
import '../relay/relay_socket.dart';
import '../seed/seed_client.dart' show defaultSeedUrl, seedId;
import '../seed/seed_dispatch.dart';
import 'group_crypto_bridge.dart';

class GroupSeedSignal {
  const GroupSeedSignal(this.peerId, this.messageId, this.text);
  final String peerId, messageId, text;
}

class _PendingSignal {
  _PendingSignal(this.peerId, this.id, this.text);
  final String peerId, id, text;
  final Completer<void> done = Completer<void>();
}

/// One identity-bound seed socket for all group peer WebRTC negotiations.
class GroupSeedClient extends ChangeNotifier {
  GroupSeedClient({
    required this.account,
    required this.relayCrypto,
    required this.crypto,
    required this.network,
    RelayConnector? connector,
    int Function()? clock,
    this.endpoint = defaultSeedUrl,
  }) : connector = connector ?? openRelaySocket,
       _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final AccountBridge account;
  final RelayCryptoBridge relayCrypto;
  final GroupCryptoBridge crypto;
  final RelayNetwork network;
  final RelayConnector connector;
  final String endpoint;
  final int Function() _clock;
  final _signals = StreamController<GroupSeedSignal>.broadcast();
  Stream<GroupSeedSignal> get signals => _signals.stream;
  bool get registered => _registered;

  final _replays = <String, int>{};
  final _pending = <_PendingSignal>[];
  _PendingSignal? _inFlight;
  final _sentAt = <int>[];
  RelaySocket? _socket;
  StreamSubscription<String>? _subscription;
  Timer? _retry, _heartbeat, _challengeDeadline, _rateTimer;
  Future<void> _incoming = Future.value();
  int _generation = 0, _attempt = 0, _queuedIncoming = 0, _catalogOffset = 0;
  int? _pulseGeneration;
  int _lastAlive = 0;
  bool _closed = false,
      _registered = false,
      _challenged = false,
      _flushing = false;
  String? _owner;
  final _dispatch = SeedDispatchSession();
  bool _storageUnavailable = false;

  static final _did = RegExp(r'^did:cht:[0-9a-f]{64}$');
  static final _session = RegExp(r'^[0-9a-f]{32}$');
  static final _fingerprint = RegExp(
    r'^a=fingerprint:sha-256 (?:[0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2}\r?$',
    multiLine: true,
  );
  static final _relayCandidate = RegExp(
    r'\btyp\s+relay\b',
    caseSensitive: false,
  );
  static bool _currentPayload(String id, String text) {
    try {
      final packet = jsonDecode(text);
      if (packet is! Map ||
          packet['v'] != 1 ||
          packet['s'] is! String ||
          !_session.hasMatch(packet['s']) ||
          !['offer', 'answer', 'ice'].contains(packet['t'])) {
        return false;
      }
      final kind = packet['t'] as String, session = packet['s'] as String;
      final prefix = 'cht-control-groups-v1-$session-$kind-';
      if (!id.startsWith(prefix) ||
          !RegExp(r'^[0-9]{1,20}$').hasMatch(id.substring(prefix.length))) {
        return false;
      }
      if (BigInt.parse(id.substring(prefix.length)) >
          BigInt.parse('18446744073709551615')) {
        return false;
      }
      if (kind == 'ice') {
        if (packet.length != 6 ||
            !packet.keys.toSet().containsAll(['v', 't', 's', 'c', 'm', 'l'])) {
          return false;
        }
        final c = packet['c'];
        return c is String &&
            _validCandidate(c) &&
            (packet['m'] == null ||
                packet['m'] is String &&
                    utf8.encode(packet['m'] as String).length <= 64 &&
                    !RegExp(r'[\r\n\x00]').hasMatch(packet['m'])) &&
            (packet['l'] == null ||
                packet['l'] is int && packet['l'] >= 0 && packet['l'] <= 65535);
      }
      if (packet.length != 4 ||
          !packet.keys.toSet().containsAll(['v', 't', 's', 'd'])) {
        return false;
      }
      final d = packet['d'];
      if (d is! String ||
          utf8.encode(d).length > 11000 ||
          !RegExp(r'^v=0\r?\n').hasMatch(d) ||
          d.contains('\x00') ||
          !_fingerprint.hasMatch(d) ||
          _relayCandidate.hasMatch(d)) {
        return false;
      }
      final roles = RegExp(r'(?:^|\n)a=setup:([^\r\n]+)')
          .allMatches(d)
          .map((m) => m.group(1))
          .toList();
      if (roles.isEmpty ||
          roles.any(
            (r) => kind == 'offer'
                ? r != 'actpass'
                : r != 'active' && r != 'passive',
          )) {
        return false;
      }
      for (final line in d.split(RegExp(r'\r?\n'))) {
        if (line.startsWith('a=candidate:') &&
            !_validCandidate(line.substring(2))) {
          return false;
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  static bool _validCandidate(String value) {
    if (utf8.encode(value).length > 2048 ||
        RegExp(r'[\r\n\x00]').hasMatch(value)) {
      return false;
    }
    final p = value.trim().split(RegExp(r'\s+'));
    if (p.length < 8 ||
        !RegExp(r'^candidate:[A-Za-z0-9+/]{1,32}$').hasMatch(p[0]) ||
        !['udp', 'tcp'].contains(p[2].toLowerCase()) ||
        p[6] != 'typ' ||
        !['host', 'srflx', 'prflx'].contains(p[7])) {
      return false;
    }
    final component = int.tryParse(p[1]),
        priority = int.tryParse(p[3]),
        port = int.tryParse(p[5]);
    return component != null &&
        component >= 1 &&
        component <= 256 &&
        priority != null &&
        priority >= 0 &&
        priority <= 4294967295 &&
        p[4].length <= 253 &&
        port != null &&
        port >= 1 &&
        port <= 65535 &&
        !_relayCandidate.hasMatch(value);
  }

  bool _current(int generation) =>
      !_closed && _owner != null && generation == _generation;
  Future<bool> _active(int generation) async {
    if (!_current(generation)) return false;
    try {
      final identity = await account.identity();
      if (!_current(generation)) return false;
      if (identity.id == _owner) return true;
    } catch (_) {
      if (!_current(generation)) return false;
    }
    await stop();
    return false;
  }

  Future<void> start(String owner) async {
    if (_closed) throw StateError('Seed closed');
    if (!_did.hasMatch(owner)) throw const FormatException('Invalid owner');
    if (_owner == owner) return;
    await stop();
    if (_closed) throw StateError('Seed closed');
    _owner = owner;
    await _connect(_generation);
  }

  Future<void> _connect(int generation) async {
    try {
      final uri = Uri.parse(endpoint);
      final local = ['localhost', '127.0.0.1', '::1'].contains(uri.host);
      if (uri.path != '/relay' ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          (uri.scheme != 'wss' && !(local && uri.scheme == 'ws'))) {
        throw const FormatException('Invalid seed endpoint');
      }
      final socket = await connector(endpoint);
      if (!_current(generation)) {
        await socket.close();
        return;
      }
      _socket = socket;
      _challenged = false;
      _incoming = Future.value();
      _challengeDeadline = Timer(
        const Duration(seconds: 30),
        () => _drop(generation),
      );
      _subscription = socket.frames.listen(
        (source) {
          if (!_current(generation)) return;
          if (utf8.encode(source).length > 16384 || _queuedIncoming >= 64) {
            _drop(generation);
            return;
          }
          _queuedIncoming++;
          final work = _incoming.then((_) async {
            if (_current(generation)) {
              await _frame(
                source,
                generation,
              ).timeout(const Duration(seconds: 10));
            }
          });
          _incoming = work
              .catchError((Object _) {
                _drop(generation);
              })
              .whenComplete(() => _queuedIncoming--);
        },
        onError: (Object _) => _drop(generation),
        onDone: () => _drop(generation),
      );
    } catch (_) {
      _drop(generation);
    }
    if (_current(generation)) notifyListeners();
  }

  void _send(Map<String, Object?> frame) => _socket?.send(jsonEncode(frame));
  Future<void> _frame(String source, int generation) async {
    if (!await _active(generation)) return;
    final value = jsonDecode(source);
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Invalid seed frame');
    }
    if (!_registered) {
      if (value['type'] == 'challenge' &&
          !_challenged &&
          value['protocol'] == 'chta-seed' &&
          value['version'] == 1 &&
          value['seedId'] == seedId &&
          value['nonce'] is String &&
          RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value['nonce'])) {
        _challenged = true;
        _dispatch.configure(value, seedId, crypto);
        final proof = jsonDecode(
          await relayCrypto.relayProof(value['nonce'] as String, seedId),
        );
        if (!await _active(generation)) return;
        if (proof is! Map || proof['identityId'] != _owner) {
          _drop(generation);
          return;
        }
        _send({'type': 'register', 'proof': proof});
        return;
      }
      if (value['type'] == 'registered' &&
          _challenged &&
          value['protocol'] == 'chta-seed' &&
          value['version'] == 1) {
        _registered = true;
        _storageUnavailable = false;
        _attempt = 0;
        _lastAlive = _clock();
        _challengeDeadline?.cancel();
        _heartbeat = Timer.periodic(
          const Duration(seconds: 20),
          (_) => unawaited(_pulse(generation)),
        );
        _publishCatalog();
        _kickFlush();
        notifyListeners();
        return;
      }
      throw const FormatException('Unexpected seed registration frame');
    }
    switch (value['type']) {
      case 'error':
        if (value['code'] != 'storage-unavailable') {
          throw const FormatException('Unexpected seed error');
        }
        _storageUnavailable = true;
        _drop(generation);
      case 'alive':
        _lastAlive = _clock();
      case 'catalog':
        final records = value['records'];
        if (records is! List || records.length > 64) {
          throw const FormatException('Invalid catalog');
        }
        await network.mergePeerCatalog({
          'protocol': 'cht-relays',
          'version': 1,
          'urls': <String>[],
          'relays': records,
        });
      case 'signal':
        final e = value['envelope'];
        if (e is! Map<String, dynamic>) {
          throw const FormatException('Invalid envelope');
        }
        if (e.length != 12 ||
            !e.keys.toSet().containsAll([
              'version',
              'topic',
              'from',
              'to',
              'session',
              'id',
              'kind',
              'payload',
              'issuedAt',
              'expiresAt',
              'publicKey',
              'signature',
            ])) {
          return;
        }
        final from = e['from'], expiry = e['expiresAt'], issued = e['issuedAt'];
        if (e['version'] != 2 ||
            e['topic'] != 'groups' ||
            from is! String ||
            !_did.hasMatch(from) ||
            from == _owner ||
            e['to'] != _owner ||
            expiry is! int ||
            issued is! int ||
            expiry <= _clock() ||
            expiry > _clock() + 150000 ||
            expiry - issued > 120000 ||
            issued > _clock() + 30000 ||
            e['id'] is! String ||
            e['payload'] is! String ||
            !_currentPayload(e['id'] as String, e['payload'] as String) ||
            e['session'] != (jsonDecode(e['payload'] as String) as Map)['s'] ||
            e['kind'] != (jsonDecode(e['payload'] as String) as Map)['t']) {
          return;
        }
        try {
          final inspected = await crypto.groupCall('inspectSignal', {
            'source': jsonEncode(e),
            'expectedPeer': from,
            'now': _clock(),
          });
          if (!await _active(generation) ||
              !_registered ||
              expiry <= _clock() ||
              inspected['peerId'] != from ||
              inspected['messageId'] != e['id'] ||
              inspected['text'] != e['payload']) {
            return;
          }
          _replays.removeWhere((_, until) => until <= _clock());
          final key = '$from\u0000${e['id']}';
          if (_replays.containsKey(key) || _replays.length >= 4096) return;
          _replays[key] = expiry;
          _signals.add(
            GroupSeedSignal(from, e['id'] as String, e['payload'] as String),
          );
        } catch (_) {
          /* An invalid peer signature cannot affect other peers. */
        }
      case 'unreachable':
        if (value['identityId'] is! String ||
            !_did.hasMatch(value['identityId'])) {
          throw const FormatException('Invalid unreachable');
        }
      default:
        throw const FormatException('Unexpected seed frame');
    }
  }

  Future<void> _pulse(int generation) async {
    if (!_current(generation) || _pulseGeneration == generation) return;
    _pulseGeneration = generation;
    try {
      if (!await _active(generation).timeout(const Duration(seconds: 5))) {
        return;
      }
      if (_clock() - _lastAlive > 45000) {
        _drop(generation);
        return;
      }
      _send({'type': 'keepalive'});
      _publishCatalog();
      _kickFlush();
    } catch (_) {
      _drop(generation);
    } finally {
      if (_pulseGeneration == generation) _pulseGeneration = null;
    }
  }

  void _publishCatalog() {
    final available = network.peerCatalog()['relays'] as List;
    if (available.isEmpty) return;
    final records = <Object?>[];
    var scanned = 0;
    while (scanned < available.length && records.length < 64) {
      final record = available[(_catalogOffset + scanned) % available.length];
      scanned++;
      if (utf8
              .encode(
                jsonEncode({
                  'type': 'catalog',
                  'records': [...records, record],
                }),
              )
              .length >
          16384) {
        break;
      }
      records.add(record);
    }
    _catalogOffset =
        (_catalogOffset + (records.isEmpty ? 1 : records.length)) %
        available.length;
    if (records.isNotEmpty) _send({'type': 'catalog', 'records': records});
  }

  Future<void> send(String peerId, String id, String text) async {
    if (!_did.hasMatch(peerId) ||
        peerId == _owner ||
        !_currentPayload(id, text)) {
      throw const FormatException('Seed accepts group WebRTC control only');
    }
    if (_closed || _owner == null) throw StateError('Seed unavailable');
    if (_pending.length >= 128) throw StateError('Seed signal queue full');
    final item = _PendingSignal(peerId, id, text);
    _pending.add(item);
    _kickFlush();
    return item.done.future;
  }

  void _kickFlush() {
    if (_registered && !_flushing) unawaited(_flush(_generation));
  }

  Future<void> _flush(int generation) async {
    if (_flushing) return;
    _flushing = true;
    try {
      while (_registered && _current(generation) && _pending.isNotEmpty) {
        final now = _clock();
        _sentAt.removeWhere((at) => at <= now - 60000);
        if (_sentAt.length >= 80) {
          _rateTimer?.cancel();
          _rateTimer = Timer(
            Duration(milliseconds: max(1, _sentAt.first + 60001 - now)),
            _kickFlush,
          );
          break;
        }
        final item = _pending.removeAt(0);
        _inFlight = item;
        if (!await _active(generation)) {
          _reject(item);
          break;
        }
        try {
          final result = await crypto.groupCall('signSignal', {
            'peerId': item.peerId,
            'id': item.id,
            'text': item.text,
            'now': _clock(),
          });
          if (!_current(generation) ||
              !_registered ||
              !await _active(generation)) {
            _reject(item);
            continue;
          }
          final source = result['source'];
          if (source is! String) {
            throw const FormatException('Missing signed signal');
          }
          final e = jsonDecode(source);
          if (e is! Map ||
              e['version'] != 2 ||
              e['topic'] != 'groups' ||
              e['from'] != _owner ||
              e['to'] != item.peerId ||
              e['id'] != item.id ||
              e['payload'] != item.text) {
            throw const FormatException('Invalid signed signal');
          }
          await _dispatch.send(
            Map<String, dynamic>.from(e),
            crypto: crypto,
            isActive: () async =>
                _current(generation) &&
                _registered &&
                await _active(generation),
            emit: _send,
          );
          _sentAt.add(_clock());
          item.done.complete();
        } catch (error, stack) {
          if (!item.done.isCompleted) item.done.completeError(error, stack);
          if (error is! FormatException && _current(generation)) {
            _drop(generation);
          }
        } finally {
          if (identical(_inFlight, item)) _inFlight = null;
        }
      }
    } finally {
      _flushing = false;
      if (_registered && _pending.isNotEmpty && _rateTimer?.isActive != true) {
        _kickFlush();
      }
    }
  }

  void _reject(_PendingSignal item) {
    if (!item.done.isCompleted) {
      item.done.completeError(StateError('Seed session changed'));
    }
  }

  void _rejectAll() {
    for (final item in _pending) {
      _reject(item);
    }
    _pending.clear();
  }

  void _drop(int generation) {
    if (!_current(generation)) return;
    _generation++;
    _dispatch.reset();
    _registered = false;
    _heartbeat?.cancel();
    _challengeDeadline?.cancel();
    _rateTimer?.cancel();
    _rejectAll();
    if (_inFlight != null) _reject(_inFlight!);
    unawaited(_subscription?.cancel());
    unawaited(_socket?.close());
    _socket = null;
    final next = _generation;
    _retry?.cancel();
    _retry = Timer(
      Duration(
        seconds: _storageUnavailable ? 300 : min(30, 1 << min(_attempt++, 5)),
      ),
      () {
        if (_current(next)) unawaited(_connect(next));
      },
    );
    notifyListeners();
  }

  Future<void> stop() async {
    _generation++;
    _dispatch.reset();
    _storageUnavailable = false;
    _owner = null;
    _registered = false;
    _attempt = 0;
    _incoming = Future.value();
    _replays.clear();
    _sentAt.clear();
    _retry?.cancel();
    _heartbeat?.cancel();
    _challengeDeadline?.cancel();
    _rateTimer?.cancel();
    _rejectAll();
    if (_inFlight != null) _reject(_inFlight!);
    final subscription = _subscription, socket = _socket;
    _subscription = null;
    _socket = null;
    await subscription?.cancel();
    await socket?.close();
    if (!_closed) notifyListeners();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await stop();
    await _signals.close();
    dispose();
  }
}
