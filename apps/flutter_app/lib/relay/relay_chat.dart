import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../account/account_bridge.dart';
import '../account/account_models.dart';
import '../groups/group_crypto_bridge.dart';
import '../p2p/p2p_bridge.dart';
import 'relay_network.dart';

/// One ordered Noise session, with warm relay connections for failover.
class RelayChat {
  RelayChat(
    this.account,
    this.network, {
    required this.ownCard,
    this.onFriendRequest,
    this.canAcceptPeer,
    this.ownsNetwork = true,
    this.boundPeer,
    this.onEvents,
    bool automaticTicks = true,
    int Function()? clock,
  }) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch) {
    network.addFrameListener(_receiveFrame);
    network.addListener(_networkChanged);
    if (automaticTicks) {
      _timer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => unawaited(tick()),
      );
    }
  }
  final void Function()? onEvents;
  void _event(PeerEvent event) {
    events.add(event);
    onEvents?.call();
  }

  final bool ownsNetwork;
  final String? boundPeer;
  void acceptFrame(String endpoint, Map<String, dynamic> frame) =>
      _receiveFrame(endpoint, frame);
  void _receiveFrame(String endpoint, Map<String, dynamic> frame) {
    if (_closed || _queuedFrames >= 64) return;
    if (boundPeer != null &&
        (frame['type'] == 'route' ? frame['from'] : frame['to']) != boundPeer) {
      return;
    }
    _queuedFrames++;
    _enqueue(() async {
      try {
        await _frame(endpoint, frame);
      } finally {
        _queuedFrames--;
      }
    });
  }

  void _networkChanged() {
    if (_closed) return;
    if (_route != null && !network.online.contains(_route)) _reset();
    unawaited(tick());
  }

  final AccountBridge account;
  final RelayNetwork network;
  final Future<String> Function() ownCard;
  final void Function(String card, ContactView contact)? onFriendRequest;
  final bool Function()? canAcceptPeer;
  final int Function() _clock;
  int _queuedFrames = 0;
  int _lastFriendRequest = 0;
  int _routeCursor = 0;
  final events = <PeerEvent>[];
  final _pending = <String, _Pending>{};
  final _seenPackets = <String>{};
  final _retired = <String>{};
  final _blocked = <String, int>{};
  Timer? _timer;
  Future<void> _serial = Future.value();
  bool _closed = false;
  bool _ticking = false;
  int _generation = 0;
  String? peerId;
  String? _route;
  String? _session;
  bool _v2 = false;
  bool _offeredV2 = false;
  _Candidate? _candidate;
  bool _initiator = false;
  bool authenticated = false;
  String state = 'new';
  int _lastAttempt = 0;
  int _lastReceived = 0;
  int _lastPing = 0;
  int get now => _clock();
  bool get selected => peerId != null;
  static String randomId() => List.generate(
    16,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  void select(String identityId) {
    if (boundPeer != null && identityId != boundPeer) {
      throw StateError('Wrong peer');
    }
    if (peerId != identityId) {
      events.clear();
      _pending.clear();
      _reset();
      peerId = identityId;
      _routeCursor = 0;
    }
    _lastAttempt = 0;
    unawaited(tick());
  }

  void disconnectPeer() {
    events.clear();
    _reset();
    peerId = null;
    _pending.clear();
  }

  void cancelPendingFor(String identityId) {
    if (peerId == identityId) _pending.clear();
  }

  void _reset() {
    _generation++;
    _dropCandidate();
    if (_session != null) {
      _retired.add(_session!);
      if (_retired.length > 128) _retired.remove(_retired.first);
      if (_v2) _closeV2(_session!);
    }
    _v2 = false;
    authenticated = false;
    state = 'connecting';
    _session = null;
    _route = null;
    network.leaseRoute(this, null);
    _event(const PeerEvent(type: 'connection', state: 'connecting'));
  }

  bool get _supportsV2 => account is GroupCryptoBridge;
  Future<Map<String, Object?>> _callV2(
    String operation,
    String session,
    Map<String, Object?> arguments,
  ) => (account as GroupCryptoBridge).groupCall(operation, {
    'peerId': peerId,
    'sessionId': session,
    'context': 'dm-v2',
    ...arguments,
  });
  void _closeV2(String session) {
    if (peerId == null || !_supportsV2) return;
    unawaited(
      _callV2(
        'closeSession',
        session,
        const {},
      ).catchError((Object _) => <String, Object?>{}),
    );
  }

  void _dropCandidate() {
    final candidate = _candidate;
    _candidate = null;
    if (candidate != null) _closeV2(candidate.session);
  }

  Future<void> _prepare(
    String card,
    bool initiator,
    String session,
    bool v2,
  ) async {
    if (v2) {
      await _callV2('prepare', session, {'initiator': initiator});
    } else {
      await account.preparePeer(card, initiator);
    }
  }

  Future<String> _startHandshake(String session, bool v2) async => v2
      ? (await _callV2('start', session, const {}))['frame'] as String
      : account.startPeerHandshake();
  Future<Map<String, Object?>> _receiveHandshake(
    String frame,
    String session,
    bool v2,
  ) => v2
      ? _callV2('handshake', session, {'frame': frame})
      : account.receivePeerHandshake(frame);

  bool _sendTo(
    String route,
    String session,
    String to,
    Map<String, dynamic> body,
  ) => network.send(route, {
    'type': 'route',
    'to': to,
    'session': session,
    'packet': randomId(),
    'body': body,
  });

  void _enqueue(Future<void> Function() task) {
    var taskGeneration = _generation;
    _serial = _serial
        .then((_) async {
          taskGeneration = _generation;
          if (!_closed) await task();
        })
        .catchError((Object _) {
          // Invalid frames cannot mark the session authenticated or acknowledge messages.
          // Noise counters may have diverged; start a fresh authenticated session.
          if (!_closed && peerId != null && taskGeneration == _generation) {
            _reset();
          }
        });
  }

  Future<void> tick() async {
    if (_closed || _ticking || peerId == null) return;
    _ticking = true;
    final complete = Completer<void>();
    _enqueue(() async {
      try {
        final candidate = _candidate;
        if (candidate != null && now - candidate.createdAt > 15000) {
          _dropCandidate();
        }
        if (authenticated) {
          if (now - _lastReceived > 65000) {
            _reset();
            return;
          }
          if (now - _lastPing > 20000) {
            _lastPing = now;
            await _encrypted({'type': 'ping'});
          }
          for (final pending in _pending.values.toList()) {
            if (_pending[pending.id] != pending) continue;
            if (now - pending.lastSent < 5000) continue;
            if (pending.attempts >= 8) {
              _pending.remove(pending.id);
              _event(
                PeerEvent(
                  type: 'failed',
                  messageId: pending.id,
                  reason: 'Message was not acknowledged',
                ),
              );
              continue;
            }
            try {
              await _sendPending(pending);
            } catch (_) {
              if (_pending[pending.id] == pending) rethrow;
            }
          }
        } else if (network.online.isNotEmpty && now - _lastAttempt > 5000) {
          if (_session != null) _reset();
          final online = network.online;
          final choices = <String>{
            ...network.preferredRoutes.where(online.contains),
            ...online,
          }.toList();
          if (choices.isEmpty) return;
          String? route;
          for (var attempt = 0; attempt < choices.length; attempt++) {
            final index = (_routeCursor + attempt) % choices.length;
            if ((_blocked[choices[index]] ?? 0) > now) continue;
            route = choices[index];
            _routeCursor = (index + 1) % choices.length;
            break;
          }
          if (route == null) return;
          _lastAttempt = now;
          _route = route;
          network.leaseRoute(this, _route);
          final current = _generation;
          final contacts = await account.contacts();
          final contact = contacts
              .where((c) => c.identityId == peerId && c.verified)
              .firstOrNull;
          if (contact == null) return;
          final card = await ownCard();
          final inspected = await account.inspectContactCard(card);
          final localIdentity = await account.identity();
          if (inspected.identityId != localIdentity.id ||
              current != _generation) {
            return;
          }
          _offeredV2 =
              _supportsV2 &&
              inspected.capabilities.contains('peer-sessions-v2');
          // preparePeer requires the friend's signed card. The account already
          // stores it; relay peers supply a fresh card in the initial probe.
          _session = randomId();
          _initiator = true;
          _sendBody({'type': 'probe', 'contactCard': card});
        }
      } finally {
        complete.complete();
      }
    });
    try {
      await complete.future;
    } finally {
      _ticking = false;
    }
  }

  Future<void> _frame(String endpoint, Map<String, dynamic> frame) async {
    var frameGeneration = _generation;
    bool stale() => _closed || frameGeneration != _generation;
    if (frame['type'] == 'unreachable') {
      if (endpoint == _route &&
          frame['session'] == _session &&
          frame['to'] == peerId) {
        _blocked[endpoint] = now + 10000;
        _reset();
        _lastAttempt = 0;
      }
      return;
    }
    final from = frame['from'];
    final session = frame['session'];
    final packet = frame['packet'];
    if (from is! String ||
        session is! String ||
        packet is! String ||
        packet.length != 32 ||
        session.length != 32 ||
        frame['body'] is! Map ||
        _retired.contains(session)) {
      return;
    }
    if (!_seenPackets.add(packet)) return;
    if (_seenPackets.length > 512) _seenPackets.remove(_seenPackets.first);
    final body = (frame['body'] as Map).cast<String, dynamic>();
    final candidate = _candidate;
    if (candidate != null &&
        session == candidate.session &&
        endpoint == candidate.route &&
        from == peerId) {
      if (body['type'] != 'noise' || body['payload'] is! String) return;
      try {
        final result = await _receiveHandshake(
          body['payload'] as String,
          candidate.session,
          true,
        );
        if (stale() || _candidate != candidate) return;
        if (result['reply'] is String &&
            !_sendTo(candidate.route, candidate.session, from, {
              'type': 'noise',
              'payload': result['reply'],
            })) {
          _dropCandidate();
          return;
        }
        if (result['established'] == true) {
          _promoteCandidate(candidate);
          for (final pending in _pending.values.toList()) {
            await _sendPending(pending);
          }
        }
      } catch (_) {
        if (_candidate == candidate) _dropCandidate();
      }
      return;
    }
    if (body['type'] == 'probe') {
      // Direct and relay transports share the account's Noise state.
      if (canAcceptPeer?.call() == false) return;
      final generation = _generation;
      final identity = await account.identity();
      if (stale()) return;
      if (from == identity.id || peerId != null && peerId != from) return;
      final card = body['contactCard'];
      if (card is! String || card.length > 16384) {
        return;
      }
      ContactView inspected;
      try {
        inspected = await account.inspectContactCard(card);
      } catch (_) {
        return;
      }
      if (stale()) return;
      if (inspected.identityId != from) return;
      List<ContactView> contacts;
      try {
        contacts = await account.contacts();
      } catch (_) {
        return;
      }
      if (_closed ||
          generation != _generation ||
          canAcceptPeer?.call() == false) {
        return;
      }
      if (!contacts.any((c) => c.identityId == from && c.verified)) {
        if (now - _lastFriendRequest > 60000) {
          _lastFriendRequest = now;
          onFriendRequest?.call(card, inspected);
        }
        return;
      }
      if (authenticated && _session != session) {
        // A signed contact card proves identity, not freshness or possession
        // of this new session. Keep the authenticated transport until Noise
        // completes in an independent session.
        if (!_supportsV2 ||
            !inspected.capabilities.contains('peer-sessions-v2') ||
            (_candidate != null && now - _candidate!.createdAt <= 15000)) {
          return;
        }
        String own;
        try {
          own = await ownCard();
          if (stale() ||
              !(await account.inspectContactCard(own)).capabilities
                  .contains('peer-sessions-v2')) {
            return;
          }
        } catch (_) {
          return;
        }
        final next = _Candidate(session, endpoint, now);
        _candidate = next;
        try {
          await _prepare(card, false, session, true);
          if (stale() || _candidate != next) return;
          if (!_sendTo(endpoint, session, from, {
            'type': 'ready',
            'contactCard': own,
          })) {
            _dropCandidate();
          }
        } catch (_) {
          if (_candidate == next) _dropCandidate();
        }
        return;
      }
      if (_session != null &&
          _session != session &&
          _initiator &&
          !authenticated &&
          identity.id.compareTo(from) < 0) {
        return;
      }
      if (_session != null && _session != session) _reset();
      // This accepted probe deliberately replaces the previous session.
      frameGeneration = _generation;
      peerId = from;
      _session = session;
      final own = await ownCard();
      if (stale()) return;
      _v2 =
          _supportsV2 &&
          inspected.capabilities.contains('peer-sessions-v2') &&
          (await account.inspectContactCard(own)).capabilities
              .contains('peer-sessions-v2');
      if (boundPeer != null && !_v2) {
        _reset();
        return;
      }
      _route = endpoint;
      network.leaseRoute(this, endpoint);
      _initiator = false;
      _lastReceived = now;
      _lastAttempt = now;
      // A probe is discovery only; it never enables the composer.
      final prepareGeneration = _generation;
      await _prepare(card, false, session, _v2);
      if (_closed ||
          prepareGeneration != _generation ||
          canAcceptPeer?.call() == false) {
        return;
      }
      if (stale()) return;
      _sendBody({'type': 'ready', 'contactCard': own});
    } else if (session == _session && from == peerId && endpoint == _route) {
      switch (body['type']) {
        case 'ready':
          if (!_initiator || authenticated) return;
          final card = body['contactCard'];
          if (card is! String ||
              (await account.inspectContactCard(card)).identityId != peerId) {
            return;
          }
          if (stale()) return;
          final remote = await account.inspectContactCard(card);
          _v2 = _offeredV2 && remote.capabilities.contains('peer-sessions-v2');
          if (boundPeer != null && !_v2) {
            _reset();
            return;
          }
          await _prepare(card, true, session, _v2);
          if (stale()) return;
          final handshake = await _startHandshake(session, _v2);
          if (stale()) return;
          _sendBody({'type': 'noise', 'payload': handshake});
        case 'noise':
          if (authenticated || body['payload'] is! String) return;
          final result = await _receiveHandshake(
            body['payload'] as String,
            session,
            _v2,
          );
          if (stale()) return;
          if (result['reply'] is String) {
            _sendBody({'type': 'noise', 'payload': result['reply']});
          }
          if (result['established'] == true) {
            authenticated = true;
            state = 'connected';
            _lastReceived = now;
            _lastPing = now;
            _event(const PeerEvent(type: 'authenticated'));
            for (final pending in _pending.values.toList()) {
              await _sendPending(pending);
            }
          }
        case 'encrypted':
          if (!authenticated || body['payload'] is! String) return;
          final decoded = _v2
              ? await _callV2('decrypt', session, {'frame': body['payload']})
              : await account.decryptPeerMessage(body['payload'] as String);
          if (stale()) return;
          final content =
              jsonDecode(decoded['text'] as String) as Map<String, dynamic>;
          // Crypto deduplication precedes durable history/ACK. A retry must
          // reach the history layer again so an interrupted receive can finish
          // or return its original receipt without adding another bubble.
          if (decoded['duplicate'] == true && content['type'] != 'message') {
            return;
          }
          _lastReceived = now;
          switch (content['type']) {
            case 'message':
              _event(
                PeerEvent(
                  type: 'message',
                  messageId: (decoded['messageId'] ?? decoded['id']) as String,
                  text: content['text'] as String,
                  sentAtMilliseconds:
                      (decoded['sentAtMilliseconds'] ??
                              content['sentAtMilliseconds'])
                          as int?,
                  receivedAtMilliseconds: now,
                ),
              );
            case 'peerControl':
              if (content['text'] is String) {
                _event(
                  PeerEvent(
                    type: 'control',
                    messageId:
                        (decoded['messageId'] ?? decoded['id']) as String,
                    text: content['text'] as String,
                  ),
                );
              }
            case 'ack':
              final id = content['messageId'] as String;
              _pending.remove(id);
              // Direct text can retry on this authenticated fallback. Its ACK
              // still belongs to history even without a relay-local pending ID.
              _event(
                PeerEvent(
                  type: 'delivered',
                  messageId: id,
                  receivedAtMilliseconds:
                      content['receivedAtMilliseconds'] as int,
                ),
              );
            case 'ping':
              await _encrypted({'type': 'pong'});
            case 'pong':
              break;
          }
      }
    }
  }

  void _promoteCandidate(_Candidate candidate) {
    if (_candidate != candidate || peerId == null) return;
    final previous = _session;
    final previousV2 = _v2;
    _candidate = null;
    _generation++;
    if (previous != null) {
      _retired.add(previous);
      if (_retired.length > 128) _retired.remove(_retired.first);
      if (previousV2) _closeV2(previous);
    }
    _session = candidate.session;
    _route = candidate.route;
    _initiator = false;
    _v2 = true;
    network.leaseRoute(this, candidate.route);
    authenticated = true;
    state = 'connected';
    _lastReceived = now;
    _lastPing = now;
    _event(const PeerEvent(type: 'authenticated'));
  }

  void _sendBody(Map<String, dynamic> body) {
    if (_route == null ||
        _session == null ||
        peerId == null ||
        !_sendTo(_route!, _session!, peerId!, body)) {
      _reset();
      throw StateError('Relay route is not connected');
    }
  }

  Future<void> _encrypted(
    Map<String, dynamic> content, {
    String? id,
    int? sentAt,
    bool Function()? isCurrent,
  }) async {
    final generation = _generation, session = _session, peer = peerId;
    void guard() {
      if (_closed ||
          generation != _generation ||
          session != _session ||
          peer != peerId ||
          isCurrent?.call() == false) {
        throw StateError('Control session changed');
      }
    }

    guard();
    if (isCurrent?.call() == false) throw StateError('Control session changed');
    if (!authenticated) throw StateError('The connection is not authenticated');
    final messageId = id ?? 'control-${randomId()}';
    final payload = _v2
        ? (await _callV2('encrypt', session!, {
                'id': messageId,
                'text': jsonEncode({...content, 'sentAtMilliseconds': sentAt}),
              }))['frame']
              as String
        : await account.encryptPeerMessage(
            messageId,
            jsonEncode(content),
            sentAtMilliseconds: sentAt ?? now,
          );
    guard();
    if (isCurrent?.call() == false) throw StateError('Control session changed');
    _sendBody({'type': 'encrypted', 'payload': payload});
  }

  Future<void> _sendPending(
    _Pending pending, {
    bool Function()? isCurrent,
  }) async {
    bool current() {
      if (pending.isCurrent?.call() == false || isCurrent?.call() == false) {
        if (identical(_pending[pending.id], pending)) {
          _pending.remove(pending.id);
        }
        return false;
      }
      return identical(_pending[pending.id], pending);
    }

    if (pending.peer != peerId || !current()) {
      throw StateError('Chat changed');
    }
    await _encrypted(
      {'type': 'message', 'text': pending.text},
      id: pending.id,
      sentAt: pending.sentAt,
      isCurrent: current,
    );
    if (!current()) throw StateError('Chat changed');
    pending.lastSent = now;
    pending.attempts++;
    _event(PeerEvent(type: 'sent', messageId: pending.id));
  }

  final _sendWaiters = <Completer<void>>{};
  Completer<void> _sendCompletion() {
    final done = Completer<void>();
    _sendWaiters.add(done);
    unawaited(
      done.future.then<void>(
        (_) {
          _sendWaiters.remove(done);
        },
        onError: (Object _, StackTrace ignoredStack) {
          _sendWaiters.remove(done);
        },
      ),
    );
    if (_closed) done.completeError(StateError('Connection closed'));
    return done;
  }

  static bool messageFits(String text) =>
      text.length <= 12000 &&
      utf8.encode(jsonEncode({'type': 'message', 'text': text})).length <=
          24000;

  Future<void> sendMessage(
    String id,
    String text,
    int sentAt, {
    bool Function()? isCurrent,
  }) async {
    if (!authenticated) throw StateError('The connection is not authenticated');
    if (_pending.length >= 100 || !messageFits(text)) {
      throw StateError('Message queue is full or message is too long');
    }
    final pending = _Pending(id, text, sentAt, peerId!, isCurrent);
    _pending[id] = pending;
    final done = _sendCompletion();
    _enqueue(() async {
      try {
        await _sendPending(pending, isCurrent: isCurrent);
        if (!done.isCompleted) done.complete();
      } catch (e, st) {
        if (!done.isCompleted) done.completeError(e, st);
        if (_pending[id] == pending) rethrow;
      }
    });
    await done.future;
  }

  void cancelPendingWhere(bool Function(String id) matches) {
    _pending.removeWhere((id, _) => matches(id));
  }

  Future<void> sendControl(String id, String text) async {
    if (text.length > 12000 ||
        utf8.encode(jsonEncode({'type': 'peerControl', 'text': text})).length >
            24000) {
      throw const FormatException('Relay control is too large');
    }
    final generation = _generation;
    final session = _session;
    final peer = peerId;
    bool isCurrent() =>
        !_closed &&
        authenticated &&
        generation == _generation &&
        session == _session &&
        peer == peerId;
    final done = _sendCompletion();
    _enqueue(() async {
      try {
        await _encrypted(
          {'type': 'peerControl', 'text': text},
          id: id,
          isCurrent: isCurrent,
        );
        if (!done.isCompleted) done.complete();
      } catch (error, stack) {
        if (!done.isCompleted) done.completeError(error, stack);
        // Best-effort discovery must not reset a newer peer's Noise session.
      }
    });
    await done.future;
  }

  Future<void> acknowledge(String id, int receivedAt) async {
    final done = _sendCompletion();
    _enqueue(() async {
      try {
        await _encrypted({
          'type': 'ack',
          'messageId': id,
          'receivedAtMilliseconds': receivedAt,
        });
        if (!done.isCompleted) done.complete();
      } catch (e, st) {
        if (!done.isCompleted) done.completeError(e, st);
        rethrow;
      }
    });
    await done.future;
  }

  List<PeerEvent> drainEvents() {
    final result = List<PeerEvent>.of(events);
    events.clear();
    return result;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    authenticated = false;
    state = 'closed';
    for (final done in _sendWaiters.toList()) {
      if (!done.isCompleted) {
        done.completeError(StateError('Connection closed'));
      }
    }
    _sendWaiters.clear();
    network.removeFrameListener(_receiveFrame);
    network.removeListener(_networkChanged);
    network.leaseRoute(this, null);
    _timer?.cancel();
    _dropCandidate();
    if (_v2 && _session != null) _closeV2(_session!);
    _generation++;
    if (ownsNetwork) await network.close();
  }
}

class _Candidate {
  const _Candidate(this.session, this.route, this.createdAt);
  final String session;
  final String route;
  final int createdAt;
}

class _Pending {
  _Pending(this.id, this.text, this.sentAt, this.peer, this.isCurrent);
  final bool Function()? isCurrent;
  final String peer;
  final String id;
  final String text;
  final int sentAt;
  int lastSent = 0;
  int attempts = 0;
}
