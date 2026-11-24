import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../account/account_models.dart';
import '../account/account_bridge.dart';
import '../relay/relay_crypto_bridge.dart';
import '../relay/relay_network.dart';
import '../relay/relay_socket.dart';
import 'seed_crypto_bridge.dart';
import 'seed_dispatch.dart';
import '../contact_requests/contact_request_transport.dart';

final seedId = sha256.convert(utf8.encode('chta.app/relay/v1')).toString();
const defaultSeedUrl = String.fromEnvironment(
  'CHT_SEED_URL',
  defaultValue: 'wss://chta.app/relay',
);

class SeedVerifiedSignal {
  const SeedVerifiedSignal(this.peerId, this.messageId, this.text);
  final String peerId, messageId, text;
}

/// Discovery and signed WebRTC control only. No user-content send API exists.
class SeedClient extends ChangeNotifier implements ContactRequestTransport {
  SeedClient({
    required this.account,
    required this.relayCrypto,
    required this.signalCrypto,
    required this.network,
    this.acceptIncomingPeer,
    this.multiPeer = false,
    RelayConnector? connector,
    int Function()? clock,
    this.endpoint = defaultSeedUrl,
  }) : connector = connector ?? openRelaySocket,
       _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);
  final bool multiPeer;
  final RelayCryptoBridge relayCrypto;
  final AccountBridge account;
  final SeedCryptoBridge signalCrypto;
  final RelayNetwork network;
  final Future<bool> Function(String peerId)? acceptIncomingPeer;
  final RelayConnector connector;
  final String endpoint;
  final int Function() _clock;
  final _signals = StreamController<SeedVerifiedSignal>.broadcast();
  Stream<SeedVerifiedSignal> get signals => _signals.stream;
  final _contactRequests = StreamController<Map<String, Object?>>.broadcast();
  @override
  Stream<Map<String, Object?>> get contactRequests => _contactRequests.stream;
  final _replays = <String, int>{};
  RelaySocket? _socket;
  StreamSubscription<String>? _subscription;
  Timer? _retry, _heartbeat, _challengeDeadline;
  int _generation = 0, _selection = 0, _attempt = 0, _queued = 0;
  int _catalogOffset = 0;
  int? _pulseGeneration;
  bool _closed = false, _registered = false, _challenged = false;
  String? _owner, _selectedPeer;
  int _lastAlive = 0, _presenceAt = 0;
  bool _online = false;
  Future<void> _incoming = Future.value();
  final _dispatch = SeedDispatchSession();
  final _courierRecords = StreamController<List<Object?>>.broadcast();
  Stream<List<Object?>> get courierRecords => _courierRecords.stream;
  bool _courierCapable = false;
  List<Object?> _courierCatalog = const [];
  void publishCouriers(List<Object?> records) {
    if (_closed) return;
    if (records.length > 8 || utf8.encode(jsonEncode(records)).length > 12000) {
      throw const FormatException('Courier catalog too large');
    }
    _courierCatalog = List.unmodifiable(records);
    if (_registered && _courierCapable) {
      _send({'type': 'couriers', 'records': _courierCatalog});
    }
  }

  bool _storageUnavailable = false;
  bool get storageUnavailable => _storageUnavailable;
  @override
  bool get registered => _registered;
  bool get needsRecovery => !_registered || _clock() - _lastAlive > 35000;
  String? get selectedPeer => _selectedPeer;
  bool get peerOnline =>
      _registered && _online && _clock() - _presenceAt < 30000;
  String get status => _storageUnavailable
      ? 'Seed · update required'
      : _registered
      ? 'Seed · connected'
      : _owner == null
      ? 'Seed · offline'
      : 'Seed · reconnecting';
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
    if (_closed) return;
    if (_owner == owner) return;
    final stopping = stop();
    final generation = _generation;
    await stopping;
    if (_closed || generation != _generation) return;
    if (!_did(owner)) throw const FormatException('Invalid owner');
    _owner = owner;
    await _connect(generation);
  }

  static bool _did(Object? value) =>
      value is String && RegExp(r'^did:cht:[0-9a-f]{64}$').hasMatch(value);
  Future<void> recoverNetwork() async {
    if (_closed || _owner == null) return;
    final selected = _selectedPeer;
    _drop(_generation);
    _retry?.cancel();
    _retry = null;
    _attempt = 0;
    _selectedPeer = selected;
    final generation = _generation;
    if (_current(generation)) await _connect(generation);
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
      _incoming = Future.value();
      _socket = socket;
      _challenged = false;
      _challengeDeadline = Timer(
        const Duration(seconds: 30),
        () => _drop(generation),
      );
      _subscription = socket.frames.listen(
        (source) {
          if (!_current(generation)) return;
          if (utf8.encode(source).length > 16384 || _queued >= 64) {
            _drop(generation);
            return;
          }
          _queued++;
          final queued = _incoming.then((_) async {
            if (_current(generation)) {
              await _frame(
                source,
                generation,
              ).timeout(const Duration(seconds: 10));
            }
          });
          _incoming = queued
              .catchError((Object _) {
                _drop(generation);
              })
              .whenComplete(() => _queued--);
        },
        onError: (Object _) => _drop(generation),
        onDone: () => _drop(generation),
      );
    } catch (_) {
      _drop(generation);
    }
    if (_current(generation)) notifyListeners();
  }

  void selectContact(ContactView? contact) {
    final selected =
        contact?.verified == true &&
            contact!.identityId != _owner &&
            _did(contact.identityId)
        ? contact.identityId
        : null;
    if (selected == _selectedPeer) return;
    _selection++;
    _selectedPeer = selected;
    _online = false;
    _presenceAt = 0;
    if (_registered && selected != null) {
      try {
        _send({'type': 'lookup', 'identityId': selected});
      } catch (_) {
        _drop(_generation);
      }
    }
    if (!_closed) notifyListeners();
  }

  void _send(Map<String, dynamic> value) => _socket?.send(jsonEncode(value));
  Future<void> _frame(String source, int generation) async {
    if (!await _active(generation)) return;
    final value = jsonDecode(source) as Map<String, dynamic>;
    if (!_registered) {
      if (value['type'] == 'challenge' &&
          !_challenged &&
          value['protocol'] == 'chta-seed' &&
          value['version'] == 1 &&
          value['seedId'] == seedId &&
          value['nonce'] is String &&
          RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value['nonce'] as String)) {
        _challenged = true;
        _courierCapable =
            (value['capabilities'] as List?)?.contains(
              'courier-directory-v1',
            ) ==
            true;
        _dispatch.configure(value, seedId, signalCrypto);
        final proof = jsonDecode(
          await relayCrypto.relayProof(value['nonce'] as String, seedId),
        ) as Map<String, dynamic>;
        if (!await _active(generation)) return;
        if (proof['identityId'] != _owner) {
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
          const Duration(seconds: 15),
          (_) => unawaited(_pulse(generation)),
        );
        if (_selectedPeer != null) {
          _send({'type': 'lookup', 'identityId': _selectedPeer});
        }
        _publishCatalog();
        if (_courierCapable) {
          _send({'type': 'couriers', 'records': _courierCatalog});
        }
        notifyListeners();
        return;
      }
      throw const FormatException('Unexpected seed registration frame');
    }
    switch (value['type']) {
      case 'couriers':
        if (!_courierCapable ||
            value['records'] is! List ||
            (value['records'] as List).length > 8) {
          throw const FormatException('Unexpected Courier directory');
        }
        _courierRecords.add(List<Object?>.from(value['records'] as List));
      case 'error':
        if (value['code'] != 'storage-unavailable') {
          throw const FormatException('Unexpected seed error');
        }
        _storageUnavailable = true;
        _drop(generation);
      case 'alive':
        _lastAlive = _clock();
      case 'presence':
        if (value['identityId'] == _selectedPeer && value['online'] is bool) {
          _online = value['online'] as bool;
          _presenceAt = _clock();
          notifyListeners();
        }
      case 'unreachable':
        if (value['identityId'] == _selectedPeer) {
          _online = false;
          notifyListeners();
        }
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
        final selected = _selectedPeer, selection = _selection;
        final envelope = value['envelope'];
        if (envelope is Map &&
            envelope['version'] == 2 &&
            envelope['topic'] == 'contacts') {
          if (_did(envelope['from']) &&
              envelope['from'] != _owner &&
              envelope['to'] == _owner) {
            // A separate Rust-backed controller verifies these before Review.
            // Never route an unknown contact into the trusted chat stream.
            _contactRequests.add(Map<String, Object?>.from(envelope));
          }
          return;
        }
        if (envelope is! Map ||
            envelope['from'] is! String ||
            !_did(envelope['from'] as String) ||
            envelope['from'] == _owner ||
            envelope['to'] != _owner) {
          return;
        }
        final peer = envelope['from'] as String;
        final incoming = peer != selected;
        if (incoming && !multiPeer && acceptIncomingPeer == null) return;
        final expires = envelope['expiresAt'];
        if (expires is! int ||
            expires <= _clock() ||
            expires > _clock() + 150000) {
          return;
        }
        try {
          final inspected = jsonDecode(
            await signalCrypto.inspectSeedSignal(
              jsonEncode(envelope),
              peer,
              _clock(),
            ),
          ) as Map<String, dynamic>;
          if (!await _active(generation) ||
              (!multiPeer &&
                  (selection != _selection || selected != _selectedPeer)) ||
              inspected['peerId'] != peer ||
              expires <= _clock()) {
            return;
          }
          final id = inspected['messageId'], text = inspected['text'];
          if (id is! String || text is! String || id != envelope['id']) return;
          _replays.removeWhere((_, until) => until <= _clock());
          final key = '$peer\u0000$id';
          if (_replays.containsKey(key) || _replays.length >= 2048) return;
          if (multiPeer) {
            final known = await account.contacts();
            if (!known.any((c) => c.identityId == peer && c.verified) ||
                !await _active(generation)) {
              return;
            }
          }
          if (incoming && !multiPeer) {
            final packet = jsonDecode(text);
            if (packet is! Map || packet['v'] != 1 || packet['t'] != 'offer') {
              return;
            }
            final known = await account.contacts();
            if (!known.any((c) => c.identityId == peer && c.verified) ||
                selection != _selection ||
                !await _active(generation)) {
              return;
            }
            if (!await acceptIncomingPeer!(peer) ||
                !await _active(generation) ||
                _selectedPeer != peer) {
              return;
            }
          }
          _replays[key] = expires;
          _signals.add(SeedVerifiedSignal(peer, id, text));
        } catch (_) {
          /* A malicious seed cannot authenticate a peer. */
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
      if (_selectedPeer != null) {
        _send({'type': 'lookup', 'identityId': _selectedPeer});
      }
      _publishCatalog();
      if (_courierCapable) {
        _send({'type': 'couriers', 'records': _courierCatalog});
      }
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

  Future<void> sendSignal(String messageId, String text) =>
      _sendSignal(_selectedPeer, messageId, text, selectedOnly: true);

  Future<void> sendPeerSignal(String peer, String messageId, String text) =>
      _sendSignal(peer, messageId, text, selectedOnly: false);

  Future<void> _sendSignal(
    String? destination,
    String messageId,
    String text, {
    required bool selectedOnly,
  }) async {
    final peer = destination, generation = _generation, selection = _selection;
    final packet = jsonDecode(text);
    if (!messageId.startsWith('cht-control-direct-v1-') ||
        packet is! Map ||
        packet['v'] != 1 ||
        !['offer', 'answer', 'ice'].contains(packet['t'])) {
      throw const FormatException('Seed accepts WebRTC control only');
    }
    if (!_registered || peer == null || (!selectedOnly && !multiPeer)) {
      throw StateError('Seed unavailable');
    }
    if (!selectedOnly &&
        !(await account.contacts()).any(
          (c) => c.identityId == peer && c.verified,
        )) {
      throw StateError('Verify friend first');
    }
    if (!await _active(generation)) throw StateError('Identity changed');
    final envelope = jsonDecode(
      await signalCrypto.signSeedSignal(peer, messageId, text, _clock()),
    );
    if (!await _active(generation) ||
        !_registered ||
        (selectedOnly && (selection != _selection || peer != _selectedPeer))) {
      throw StateError('Seed session changed');
    }
    try {
      await _dispatch.send(
        Map<String, dynamic>.from(envelope as Map),
        crypto: signalCrypto,
        isActive: () async =>
            await _active(generation) &&
            _registered &&
            (!selectedOnly ||
                (selection == _selection && peer == _selectedPeer)),
        emit: _send,
      );
    } catch (_) {
      _drop(generation);
      rethrow;
    }
  }

  @override
  Future<void> sendContactRequest(Map<String, Object?> envelope) async {
    final generation = _generation;
    if (!_registered ||
        envelope['version'] != 2 ||
        envelope['topic'] != 'contacts' ||
        envelope['from'] != _owner ||
        !_did(envelope['to']) ||
        envelope['to'] == _owner) {
      throw StateError('Contact setup unavailable');
    }
    if (!await _active(generation) || !_registered) {
      throw StateError('Identity changed');
    }
    try {
      await _dispatch.send(
        Map<String, dynamic>.from(envelope),
        crypto: signalCrypto,
        isActive: () async => await _active(generation) && _registered,
        emit: _send,
      );
    } catch (_) {
      _drop(generation);
      rethrow;
    }
  }

  void _drop(int generation) {
    if (!_current(generation)) return;
    _generation++;
    _dispatch.reset();
    _registered = false;
    _online = false;
    _heartbeat?.cancel();
    _challengeDeadline?.cancel();
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
    _courierCapable = false;
    _courierCatalog = const [];
    _dispatch.reset();
    _storageUnavailable = false;
    _selection++;
    _owner = null;
    _selectedPeer = null;
    _registered = false;
    _online = false;
    _attempt = 0;
    _incoming = Future.value();
    _retry?.cancel();
    _heartbeat?.cancel();
    _challengeDeadline?.cancel();
    final subscription = _subscription, socket = _socket;
    _subscription = null;
    _socket = null;
    final cancellation = subscription?.cancel();
    final closing = socket?.close();
    await cancellation;
    await closing;
    if (!_closed) notifyListeners();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await stop();
    await _signals.close();
    await _contactRequests.close();
    await _courierRecords.close();
    dispose();
  }
}
