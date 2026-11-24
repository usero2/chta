import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../p2p/direct_file_link.dart';
import '../delivery/delivery_router.dart';
import '../relay/relay_network.dart';
import 'group_crypto_bridge.dart';
import 'group_framing.dart';
import 'group_seed_client.dart';

abstract class GroupSignaling implements Listenable {
  bool get registered;
  Stream<GroupSeedSignal> get signals;
  Future<void> start(String owner);
  Future<void> send(String peer, String id, String text);
  Future<void> close();
}

class SeedGroupSignaling implements GroupSignaling {
  SeedGroupSignaling(this.client);
  final GroupSeedClient client;
  @override
  bool get registered => client.registered;
  @override
  Stream<GroupSeedSignal> get signals => client.signals;
  @override
  Future<void> start(String owner) => client.start(owner);
  @override
  Future<void> send(String peer, String id, String text) =>
      client.send(peer, id, text);
  @override
  Future<void> close() => client.close();
  @override
  void addListener(VoidCallback listener) => client.addListener(listener);
  @override
  void removeListener(VoidCallback listener) => client.removeListener(listener);
}

class GroupPeerFrame {
  const GroupPeerFrame(this.peerId, this.text);
  final String peerId, text;
}

String groupRandomId() => List.generate(
  16,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

/// Background group sessions, isolated from the selected direct-message session.
class GroupTransport extends ChangeNotifier {
  static const _operationTimeout = Duration(seconds: 10);
  GroupTransport({
    required this.ownerId,
    required this.crypto,
    required this.network,
    required this.signaling,
    this._peerFactory,
    int Function()? clock,
  }) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);
  final String ownerId;
  final GroupCryptoBridge crypto;
  final RelayNetwork network;
  final GroupSignaling signaling;
  final DirectPeerFactory? _peerFactory;
  final int Function() _clock;
  final _peers = <String, _GroupPeer>{};
  final _frames = StreamController<GroupPeerFrame>.broadcast();
  Stream<GroupPeerFrame> get frames => _frames.stream;
  StreamSubscription<GroupSeedSignal>? _signals;
  Timer? _timer;
  bool _closed = false, _started = false, _ticking = false;
  bool connected(String peer) => !_closed && _peers[peer]?.ready == true;
  bool isDirect(String peer) =>
      connected(peer) &&
      _peers[peer]?.route == '@direct' &&
      _peers[peer]!.link.ready;
  Set<String> get onlinePeers =>
      _peers.values.where((p) => p.ready).map((p) => p.id).toSet();

  Future<void> start() async {
    if (_closed || _started) return;
    _started = true;
    network.addFrameListener(_relayFrame);
    network.addListener(_wake);
    signaling.addListener(_wake);
    _signals = signaling.signals.listen((signal) {
      unawaited(_signal(signal).catchError((Object _) {}));
    });
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _wake());
    await signaling.start(ownerId);
    _wake();
  }

  Future<bool> _allowed(String id) async {
    if (_closed ||
        id == ownerId ||
        !RegExp(r'^did:cht:[0-9a-f]{64}$').hasMatch(id)) {
      return false;
    }
    final result = await crypto
        .groupCall('authorize', {'peerId': id})
        .timeout(_operationTimeout);
    return !_closed && result['allowed'] == true;
  }

  Future<void> connect(String id) async {
    if (!await _allowed(id)) throw StateError('Unauthorized group peer');
    final peer = _peer(id);
    await _run(peer, () async {
      await _bind(peer);
      await _attempt(peer);
    });
  }

  _GroupPeer _peer(String id) {
    final existing = _peers[id];
    if (existing != null) return existing;
    if (_closed || _peers.length >= 64) {
      throw StateError('Group peer limit reached');
    }
    final p = _GroupPeer(id, _clock);
    p.link = DirectFileLink(
      ownIdentityId: ownerId,
      allowEitherInitiator: true,
      peerFactory: _peerFactory,
      sendSignal: (messageId, text) => signaling.send(
        id,
        messageId.replaceFirst(
          'cht-control-direct-v1-',
          'cht-control-groups-v1-',
        ),
        text,
      ),
      onChanged: () => _linkChanged(p),
    );
    p.subscription = p.link.frames.listen(
      (source) => _receive(p, '@direct', source),
    );
    _peers[id] = p;
    return p;
  }

  Future<void> _signal(GroupSeedSignal signal) async {
    if (!await _allowed(signal.peerId)) return;
    final p = _peer(signal.peerId);
    await _run(p, () async {
      await _bind(p);
      if (_closed) return;
      await p.link
          .receiveSignal(
            signal.messageId.replaceFirst(
              'cht-control-groups-v1-',
              'cht-control-direct-v1-',
            ),
            signal.text,
          )
          .timeout(_operationTimeout);
    });
  }

  Future<void> _bind(_GroupPeer p) async {
    try {
      await p.link
          .bind(p.id, signalingAvailable: signaling.registered)
          .timeout(_operationTimeout);
    } catch (_) {
      // A Direct setup failure must not block an authenticated relay route.
      // DirectFileLink keeps its own bounded retry schedule.
    }
  }

  void _linkChanged(_GroupPeer p) {
    if (_closed) return;
    unawaited(
      _run(p, () async {
        if (p.route == '@direct' && !p.link.ready) {
          p.router.failed('@direct');
          await _reset(p);
        }
        await _attempt(p);
      }).catchError((Object _) {}),
    );
  }

  Future<T> _run<T>(_GroupPeer peer, Future<T> Function() task) {
    if (_closed || peer.queued >= 64) {
      return Future<T>.error(StateError('Group channel unavailable'));
    }
    peer.queued++;
    final result = peer.serial.catchError((Object _) {}).then((_) async {
      if (_closed) throw StateError('Group channel closed');
      return task();
    });
    peer.serial = result
        .then<void>((_) {})
        .catchError((Object _) {})
        .whenComplete(() => peer.queued--);
    return result;
  }

  void _wake() {
    if (!_closed) unawaited(_tick());
  }

  Future<void> _tick() async {
    if (_closed || _ticking) return;
    _ticking = true;
    try {
      for (final peer in _peers.values.toList()) {
        try {
          await _run(peer, () async {
            await _bind(peer);
            if (peer.route != '@direct' &&
                peer.route != null &&
                !network.online.contains(peer.route)) {
              await _reset(peer);
            }
            final candidate = peer.candidate;
            if (candidate != null && _clock() - candidate.createdAt > 15000) {
              await _dropCandidate(peer);
            }
            if (peer.ready && _clock() - peer.lastReceived > 90000) {
              await _reset(peer);
            }
            if (!peer.ready) {
              await _attempt(peer);
            } else if (_clock() - peer.lastPing > 25000) {
              peer.lastPing = _clock();
              await _send(peer, jsonEncode({'_groupTransport': 'ping'}));
            }
          });
        } catch (_) {
          if (peer.ready) {
            await _run(peer, () => _reset(peer)).catchError((Object _) {});
          }
        }
      }
    } finally {
      _ticking = false;
    }
  }

  Future<void> _attempt(_GroupPeer p) async {
    if (_closed || p.ready || _clock() - p.lastAttempt < 5000) return;
    if (p.session != null && p.route != null) {
      p.router.failed(p.route!);
      // Retire the unanswered attempt once. Keeping it through cooldown
      // penalizes the same attempt on every tick and can strand a sole relay.
      await _reset(p);
    }
    final route = p.router
        .rank([
          DeliveryRoute(
            id: '@direct',
            kind: DeliveryRouteKind.direct,
            authenticated: p.link.ready,
            send: () async {},
          ),
          for (final endpoint in network.online)
            DeliveryRoute(
              id: endpoint,
              kind: DeliveryRouteKind.relay,
              authenticated: true,
              send: () async {},
            ),
        ])
        .firstOrNull
        ?.id;
    if (route == null) return;
    if (!await _allowed(p.id)) return;
    if (p.session != null) await _reset(p);
    p.lastAttempt = _clock();
    p.route = route;
    p.session = groupRandomId();
    p.initiator = true;
    final session = p.session!;
    await crypto
        .groupCall('prepare', {
          'peerId': p.id,
          'sessionId': session,
          'initiator': true,
        })
        .timeout(_operationTimeout);
    if (!_current(p, session)) return;
    final reply = await crypto
        .groupCall('start', {'peerId': p.id, 'sessionId': session})
        .timeout(_operationTimeout);
    if (!_current(p, session)) return;
    await _wire(p, {
      'v': 1,
      't': 'noise',
      's': session,
      'step': 'start',
      'frame': reply['frame'],
    });
  }

  bool _current(_GroupPeer p, String s) =>
      !_closed && _peers[p.id] == p && p.session == s;
  Future<void> _reset(_GroupPeer p) async {
    await _dropCandidate(p);
    final old = p.session;
    p.ready = false;
    p.session = null;
    p.route = null;
    p.lastHandshakeReply = null;
    p.assembler.clear();
    if (old != null) {
      p.retired.add(old);
      if (p.retired.length > 128) p.retired.remove(p.retired.first);
      try {
        await crypto
            .groupCall('closeSession', {'peerId': p.id, 'sessionId': old})
            .timeout(_operationTimeout);
      } catch (_) {}
    }
    if (!_closed) notifyListeners();
  }

  Future<void> _dropCandidate(_GroupPeer p) async {
    final candidate = p.candidate;
    p.candidate = null;
    if (candidate == null) return;
    try {
      await crypto
          .groupCall('closeSession', {
            'peerId': p.id,
            'sessionId': candidate.session,
          })
          .timeout(_operationTimeout);
    } catch (_) {}
  }

  Future<void> _wire(_GroupPeer p, Map<String, dynamic> frame) async {
    final route = p.route, session = p.session;
    if (route == null || session == null) {
      throw StateError('Group route unavailable');
    }
    await _wireTo(p, route, session, frame);
  }

  Future<void> _wireTo(
    _GroupPeer p,
    String route,
    String session,
    Map<String, dynamic> frame,
  ) async {
    final source = jsonEncode(frame);
    if (utf8.encode(source).length > 16384) {
      throw const FormatException('Group wire frame too large');
    }
    if (route == '@direct') {
      if (!p.link.ready) throw StateError('Direct group channel unavailable');
      await p.link.send(source).timeout(const Duration(seconds: 2));
    } else {
      if (!network.send(route, {
        'type': 'route',
        'to': p.id,
        'session': session,
        'packet': groupRandomId(),
        'body': {'type': 'group-v1', 'frame': source},
      })) {
        throw StateError('Group relay unavailable');
      }
    }
  }

  void _relayFrame(String endpoint, Map<String, dynamic> frame) {
    if (_closed || frame['type'] != 'route' || frame['from'] is! String) return;
    final body = frame['body'];
    if (body is! Map ||
        body['type'] != 'group-v1' ||
        body['frame'] is! String) {
      return;
    }
    final source = body['frame'] as String;
    if (utf8.encode(source).length > 16384) return;
    final from = frame['from'] as String;
    unawaited(
      () async {
        if (!await _allowed(from)) return;
        final p = _peer(from);
        _receive(p, endpoint, source);
      }().catchError((Object _) {}),
    );
  }

  void _receive(_GroupPeer p, String route, String source) {
    if (_closed || utf8.encode(source).length > 16384) return;
    unawaited(
      _run(p, () async {
        final raw = jsonDecode(source);
        if (raw is! Map<String, dynamic>) return;
        final session = raw['s'];
        if (raw['v'] != 1 ||
            session is! String ||
            !RegExp(r'^[0-9a-f]{32}$').hasMatch(session) ||
            p.retired.contains(session)) {
          return;
        }
        if (raw['t'] == 'noise') {
          if (raw.length != 5 ||
              !['start', 'reply'].contains(raw['step']) ||
              raw['frame'] is! String ||
              (raw['frame'] as String).length > 8192) {
            return;
          }
          if (!await _allowed(p.id)) return;
          if (raw['step'] == 'start') {
            if (p.session == session) {
              if (!p.initiator &&
                  p.route == route &&
                  p.lastHandshakeReply != null) {
                await _wireTo(p, route, session, {
                  'v': 1,
                  't': 'noise',
                  's': session,
                  'step': 'reply',
                  'frame': p.lastHandshakeReply,
                });
              }
              return;
            }
            if (p.ready) {
              if (p.candidate != null) return;
              final active = p.session;
              final candidate = _GroupCandidate(session, route, _clock());
              p.candidate = candidate;
              try {
                await crypto
                    .groupCall('prepare', {
                      'peerId': p.id,
                      'sessionId': session,
                      'initiator': false,
                    })
                    .timeout(_operationTimeout);
                if (p.candidate != candidate ||
                    p.session != active ||
                    !p.ready) {
                  return;
                }
                final result = await crypto
                    .groupCall('handshake', {
                      'peerId': p.id,
                      'sessionId': session,
                      'frame': raw['frame'],
                    })
                    .timeout(_operationTimeout);
                if (p.candidate != candidate ||
                    p.session != active ||
                    !p.ready) {
                  return;
                }
                final reply = result['reply'];
                if (result['established'] != true || reply is! String) {
                  await _dropCandidate(p);
                  return;
                }
                await _wireTo(p, route, session, {
                  'v': 1,
                  't': 'noise',
                  's': session,
                  'step': 'reply',
                  'frame': reply,
                });
                if (p.candidate != candidate ||
                    p.session != active ||
                    !p.ready) {
                  return;
                }
                p.candidate = null;
                if (active != null) {
                  p.retired.add(active);
                  if (p.retired.length > 128) p.retired.remove(p.retired.first);
                }
                p.assembler.clear();
                p.session = session;
                p.route = route;
                p.initiator = false;
                p.lastHandshakeReply = reply;
                p.lastReceived = _clock();
                p.lastPing = _clock();
                notifyListeners();
                if (active != null) {
                  try {
                    await crypto
                        .groupCall('closeSession', {
                          'peerId': p.id,
                          'sessionId': active,
                        })
                        .timeout(_operationTimeout);
                  } catch (_) {}
                }
              } catch (_) {
                if (p.candidate == candidate) await _dropCandidate(p);
              }
              return;
            }
            if (p.initiator &&
                !p.ready &&
                p.session != null &&
                ownerId.compareTo(p.id) < 0 &&
                _clock() - p.lastAttempt < 15000) {
              return;
            }
            await _reset(p);
            if (_closed) return;
            p.session = session;
            p.route = route;
            p.initiator = false;
            p.lastAttempt = _clock();
            await crypto
                .groupCall('prepare', {
                  'peerId': p.id,
                  'sessionId': session,
                  'initiator': false,
                })
                .timeout(_operationTimeout);
          } else if (p.session != session ||
              !p.initiator ||
              p.ready ||
              p.route != route) {
            return;
          }
          if (!_current(p, session)) return;
          final result = await crypto
              .groupCall('handshake', {
                'peerId': p.id,
                'sessionId': session,
                'frame': raw['frame'],
              })
              .timeout(_operationTimeout);
          if (!_current(p, session)) return;
          if (result['reply'] is String) {
            await _wire(p, {
              'v': 1,
              't': 'noise',
              's': session,
              'step': 'reply',
              'frame': result['reply'],
            });
          }
          if (result['reply'] is String) {
            p.lastHandshakeReply = result['reply'] as String;
          }
          if (!_current(p, session)) return;
          if (result['established'] == true) {
            p.ready = true;
            p.router.receivedOn(route);
            p.lastReceived = _clock();
            p.lastPing = _clock();
            notifyListeners();
          }
        } else if (raw['t'] == 'box' &&
            p.ready &&
            p.session == session &&
            p.route == route) {
          final ciphertext = p.assembler.add(raw, session, _clock());
          if (ciphertext == null) return;
          final result = await crypto
              .groupCall('decrypt', {
                'peerId': p.id,
                'sessionId': session,
                'frame': ciphertext,
              })
              .timeout(_operationTimeout);
          if (!_current(p, session) ||
              result['duplicate'] == true ||
              result['text'] is! String) {
            return;
          }
          p.lastReceived = _clock();
          p.router.receivedOn(route);
          final text = result['text'] as String;
          Object? control;
          try {
            control = jsonDecode(text);
          } catch (_) {}
          if (control is Map &&
              control.length == 1 &&
              control['_groupTransport'] == 'ping') {
            unawaited(
              send(
                p.id,
                jsonEncode({'_groupTransport': 'pong'}),
              ).catchError((Object _) {}),
            );
          } else if (!(control is Map &&
              control.length == 1 &&
              control['_groupTransport'] == 'pong')) {
            _frames.add(GroupPeerFrame(p.id, text));
          }
        }
      }).catchError((Object _) {
        /* Malformed or stale packets never touch another peer. */
      }),
    );
  }

  Future<void> send(String id, String text) async {
    if (utf8.encode(text).length > 32768) {
      throw const FormatException('Group packet too large');
    }
    final p = _peers[id];
    if (p == null || !p.ready) throw StateError('Group peer offline');
    await _run(p, () => _send(p, text));
  }

  Future<void> _send(_GroupPeer p, String text) async {
    final session = p.session;
    try {
      if (session == null || !p.ready || !await _allowed(p.id)) {
        throw StateError('Group peer unavailable');
      }
      final id = groupRandomId();
      final encrypted = await crypto
          .groupCall('encrypt', {
            'peerId': p.id,
            'sessionId': session,
            'id': id,
            'text': text,
          })
          .timeout(_operationTimeout);
      if (!_current(p, session) || !p.ready) {
        throw StateError('Group session changed');
      }
      for (final fragment in fragmentGroupCiphertext(
        session,
        id,
        encrypted['frame'] as String,
      )) {
        if (!_current(p, session)) throw StateError('Group session changed');
        await _wire(p, fragment);
      }
    } catch (_) {
      if (p.route != null) p.router.failed(p.route!);
      if (session != null && _current(p, session)) await _reset(p);
      rethrow;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    network.removeFrameListener(_relayFrame);
    network.removeListener(_wake);
    signaling.removeListener(_wake);
    await _signals?.cancel();
    await signaling.close();
    for (final peer in _peers.values) {
      await peer.subscription?.cancel();
      await _reset(peer);
      await peer.link.close();
    }
    _peers.clear();
    await _frames.close();
    super.dispose();
  }
}

class _GroupPeer {
  _GroupPeer(this.id, int Function() clock)
    : router = DeliveryRouter(clock: clock);
  final String id;
  final DeliveryRouter router;
  late final DirectFileLink link;
  StreamSubscription<String>? subscription;
  Future<void> serial = Future.value();
  int queued = 0, lastAttempt = 0, lastReceived = 0, lastPing = 0;
  String? session, route;
  String? lastHandshakeReply;
  _GroupCandidate? candidate;
  bool ready = false, initiator = false;
  final retired = <String>{};
  final assembler = GroupFrameAssembler();
}

class _GroupCandidate {
  const _GroupCandidate(this.session, this.route, this.createdAt);
  final String session, route;
  final int createdAt;
}
