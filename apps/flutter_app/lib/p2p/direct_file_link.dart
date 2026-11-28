import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../delivery/priority_send_queue.dart';
import 'direct_peer.dart';
import 'direct_peer_factory.dart';
import 'ice_route.dart';

export 'direct_peer.dart';

typedef DirectSignalSender = Future<void> Function(String id, String text);

/// A data-only link. The caller must pass signals exclusively through its
/// current authenticated, identity-bound encrypted control channel.
class DirectFileLink {
  DirectFileLink({
    required this.ownIdentityId,
    required this.sendSignal,
    this.onChanged,
    this.allowEitherInitiator = false,
    DirectPeerFactory? peerFactory,
  }) : _factory = peerFactory ?? createDirectPeerFactory();

  static const controlPrefix = 'cht-control-direct-v1-';
  static const maxSignalBytes = 11000;
  static const maxFrameBytes = 16384;
  static const maxPendingSends = 32;
  static const maxPendingCandidates = 128;
  static final _fingerprint = RegExp(
    r'^a=fingerprint:sha-256 (?:[0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2}\r?$',
    multiLine: true,
  );

  final String ownIdentityId;
  final DirectSignalSender sendSignal;
  final void Function()? onChanged;
  final DirectPeerFactory _factory;
  final bool allowEitherInitiator;
  final StreamController<String> _frames = StreamController<String>.broadcast();
  final StreamController<void> _changes = StreamController<void>.broadcast();
  final List<(String, String?, int?)> _pendingCandidates = [];
  final List<(String, String?, int?)> _localCandidates = [];

  Stream<String> get frames => _frames.stream;
  Stream<void> get changed => _changes.stream;
  String? get peerId => _peerId;
  bool get ready => _ready;
  bool get unmetered =>
      ready && (!_turnPossible || _iceRoute == IceRoute.direct);
  String get routeLabel => _iceRoute == IceRoute.turn
      ? 'TURN'
      : unmetered
      ? 'Direct'
      : 'WebRTC';

  String? _peerId;
  String? _session;
  DirectPeer? _peer;
  bool _turnPossible = false;
  IceRoute _iceRoute = IceRoute.unknown;
  bool _ready = false;
  bool _offering = false;
  bool _signalingAvailable = false;
  bool _remoteDescriptionSet = false;
  bool _descriptionSignaled = false;
  bool _closed = false;
  int _generation = 0;
  int _bindRequest = 0;
  int _signalNumber = 0;
  int _candidateCount = 0;
  int _pendingSends = 0;
  PrioritySendQueue _sends = PrioritySendQueue();
  Timer? _retryTimer;
  Timer? _negotiationTimer;
  Future<void> _signalTail = Future.value();
  int _queuedSignals = 0;

  void _watchNegotiation() {
    if (_closed || _ready || !_signalingAvailable || _session == null) return;
    _negotiationTimer?.cancel();
    _negotiationTimer = Timer(const Duration(seconds: 20), () {
      _negotiationTimer = null;
      if (!_closed && !_ready && _signalingAvailable) _scheduleRetry();
    });
  }

  bool _current(int generation, String peer, String session) =>
      !_closed &&
      _generation == generation &&
      _peerId == peer &&
      _session == session;

  Future<void> bind(String? peerId, {required bool signalingAvailable}) async {
    if (_closed) throw StateError('Direct link is closed');
    if (peerId == ownIdentityId) throw ArgumentError.value(peerId, 'peerId');
    final request = ++_bindRequest;
    if (_peerId != peerId) {
      final reset = _reset();
      _peerId = peerId;
      _signalingAvailable = signalingAvailable;
      _notify();
      await reset;
      if (_closed || request != _bindRequest) return;
    } else if (signalingAvailable &&
        !_signalingAvailable &&
        !_ready &&
        _peer != null) {
      // A failed channel cannot retry while rendezvous signaling is absent.
      // Discard it as soon as signaling returns, then negotiate afresh.
      final reset = _reset();
      _signalingAvailable = signalingAvailable;
      await reset;
      if (_closed || request != _bindRequest) return;
    }
    _signalingAvailable = signalingAvailable;
    if (peerId != null &&
        signalingAvailable &&
        !_ready &&
        _peer == null &&
        (allowEitherInitiator || ownIdentityId.compareTo(peerId) < 0)) {
      await _startOffer(peerId);
    }
  }

  Future<void> _startOffer(String peerId) async {
    final session = _randomSession();
    final generation = _generation;
    _session = session;
    _offering = true;
    try {
      final peer = await _makePeer(generation, peerId, session);
      if (peer == null) return;
      final description = await peer.createOffer();
      if (!_current(generation, peerId, session)) return;
      _validateDescription(description);
      await _signal(generation, peerId, session, 'offer', {'d': description});
      if (_current(generation, peerId, session)) {
        _descriptionSignaled = true;
        await _sendLocalCandidates(generation, peerId, session);
        _watchNegotiation();
      }
    } catch (_) {
      if (_current(generation, peerId, session)) {
        await _disposePeer();
        _scheduleRetry();
      }
      rethrow;
    }
  }

  Future<DirectPeer?> _makePeer(
    int generation,
    String peerId,
    String session,
  ) async {
    final peer = await _factory.create();
    if (!_current(generation, peerId, session)) {
      await peer.close();
      return null;
    }
    _peer = peer;
    final route = peer is IceRoutePeer ? peer as IceRoutePeer : null;
    _turnPossible = route?.configuredTurn == true;
    _iceRoute = IceRoute.unknown;
    peer.onFrame = (frame) {
      if (_current(generation, peerId, session) &&
          _ready &&
          utf8.encode(frame).length <= maxFrameBytes) {
        _frames.add(frame);
      }
    };
    peer.onReadyChanged = (isReady) {
      if (!_current(generation, peerId, session) || !identical(_peer, peer)) {
        return;
      }
      if (_ready != isReady) {
        _ready = isReady;
        if (isReady) {
          _negotiationTimer?.cancel();
          _negotiationTimer = null;
          _retryTimer?.cancel();
          _retryTimer = null;
        } else {
          _iceRoute = IceRoute.unknown;
        }
        _notify();
      }
      if (!isReady) {
        _scheduleRetry();
      } else {
        unawaited(_refreshIceRoute());
      }
    };
    peer.onIceCandidate = (candidate, mid, line) {
      if (!_current(generation, peerId, session) ||
          !_signalingAvailable ||
          _candidateCount >= maxPendingCandidates ||
          candidate.length > 2048 ||
          relayIceType.hasMatch(candidate) && !validTurnCandidate(candidate)) {
        return;
      }
      if (relayIceType.hasMatch(candidate)) _markTurnPossible();
      _candidateCount++;
      _localCandidates.add((candidate, mid, line));
      if (_descriptionSignaled) {
        unawaited(
          _sendLocalCandidates(
            generation,
            peerId,
            session,
          ).catchError((Object _) => _scheduleRetry()),
        );
      }
    };
    return peer;
  }

  Future<void> receiveSignal(String id, String text) {
    if (_closed || _queuedSignals >= 128) return Future.value();
    final generation = _generation;
    _queuedSignals++;
    final result = _signalTail.catchError((Object _) {}).then((_) async {
      if (_closed || generation != _generation) return;
      await _receiveSignal(id, text);
    });
    _signalTail = result
        .catchError((Object _) {})
        .whenComplete(() => _queuedSignals--);
    return result;
  }

  Future<void> _receiveSignal(String id, String text) async {
    if (_closed ||
        !_signalingAvailable ||
        _peerId == null ||
        !id.startsWith(controlPrefix) ||
        utf8.encode(text).length > maxSignalBytes) {
      return;
    }
    Map<String, dynamic> packet;
    try {
      packet = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final type = packet['t'];
    final session = packet['s'];
    if (packet['v'] != 1 ||
        session is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(session) ||
        type is! String ||
        !id.startsWith('$controlPrefix$session-$type-')) {
      return;
    }
    final peerId = _peerId!;
    final generation = _generation;
    if (type == 'offer') {
      if (_ready ||
          (!allowEitherInitiator && ownIdentityId.compareTo(peerId) < 0)) {
        return;
      }
      if (_peer != null) {
        // The higher identity is polite during simultaneous group offers.
        // Default direct-message links retain their original fixed roles.
        if (!allowEitherInitiator ||
            !_offering ||
            ownIdentityId.compareTo(peerId) < 0) {
          return;
        }
        await _disposePeer();
        if (_closed || generation != _generation || _peerId != peerId) return;
        _localCandidates.clear();
        _descriptionSignaled = false;
        _candidateCount = 0;
      }
      final description = packet['d'];
      if (description is! String || !_validDescription(description)) return;
      _session = session;
      _offering = false;
      try {
        final peer = await _makePeer(generation, peerId, session);
        if (peer == null) return;
        if (relayIceType.hasMatch(description)) _markTurnPossible();
        await peer.setRemoteDescription('offer', description);
        if (!_current(generation, peerId, session)) return;
        _remoteDescriptionSet = true;
        await _drainCandidates(generation, peerId, session);
        final answer = await peer.createAnswer();
        if (!_current(generation, peerId, session)) return;
        _validateDescription(answer);
        await _signal(generation, peerId, session, 'answer', {'d': answer});
        if (_current(generation, peerId, session)) {
          _descriptionSignaled = true;
          await _sendLocalCandidates(generation, peerId, session);
          _watchNegotiation();
        }
      } catch (_) {
        if (_current(generation, peerId, session)) {
          await _disposePeer();
          _scheduleRetry();
        }
        rethrow;
      }
    } else if (type == 'answer') {
      if (session != _session || !_offering) return;
      final description = packet['d'];
      if (description is! String || !_validDescription(description)) return;
      final peer = _peer;
      if (peer == null) return;
      if (relayIceType.hasMatch(description)) _markTurnPossible();
      await peer.setRemoteDescription('answer', description);
      if (!_current(generation, peerId, session)) return;
      _remoteDescriptionSet = true;
      await _drainCandidates(generation, peerId, session);
    } else if (type == 'ice') {
      if (session != _session) return;
      final candidate = packet['c'];
      final mid = packet['m'];
      final line = packet['l'];
      if (candidate is! String ||
          candidate.length > 2048 ||
          relayIceType.hasMatch(candidate) && !validTurnCandidate(candidate) ||
          (mid != null && mid is! String) ||
          (line != null && (line is! int || line < 0 || line > 16)) ||
          _candidateCount >= maxPendingCandidates) {
        return;
      }
      if (relayIceType.hasMatch(candidate)) _markTurnPossible();
      _candidateCount++;
      if (!_remoteDescriptionSet) {
        _pendingCandidates.add((candidate, mid as String?, line as int?));
      } else {
        await _peer?.addIceCandidate(candidate, mid as String?, line as int?);
        if (relayIceType.hasMatch(candidate)) unawaited(_refreshIceRoute());
      }
    }
  }

  Future<void> _drainCandidates(
    int generation,
    String peerId,
    String session,
  ) async {
    while (_pendingCandidates.isNotEmpty &&
        _current(generation, peerId, session)) {
      final candidate = _pendingCandidates.removeAt(0);
      await _peer?.addIceCandidate(candidate.$1, candidate.$2, candidate.$3);
    }
  }

  Future<void> _sendLocalCandidates(
    int generation,
    String peerId,
    String session,
  ) async {
    while (_localCandidates.isNotEmpty &&
        _current(generation, peerId, session) &&
        _signalingAvailable) {
      final candidate = _localCandidates.removeAt(0);
      await _signal(generation, peerId, session, 'ice', {
        'c': candidate.$1,
        'm': candidate.$2,
        'l': candidate.$3,
      });
    }
  }

  Future<void> _signal(
    int generation,
    String peerId,
    String session,
    String type,
    Map<String, Object?> fields,
  ) async {
    if (!_current(generation, peerId, session) || !_signalingAvailable) {
      return;
    }
    final text = jsonEncode({'v': 1, 't': type, 's': session, ...fields});
    if (utf8.encode(text).length > maxSignalBytes) {
      throw const FormatException('Direct signal is too large');
    }
    final id = '$controlPrefix$session-$type-${_signalNumber++}';
    if (!_current(generation, peerId, session)) {
      return;
    }
    await sendSignal(id, text);
  }

  Future<void> send(String frame, {bool bulk = false}) async {
    if (utf8.encode(frame).length > maxFrameBytes) {
      throw const FormatException('Direct frame is too large');
    }
    final peer = _peer;
    final peerId = _peerId;
    final session = _session;
    final generation = _generation;
    if (!_ready || peer == null || peerId == null || session == null) {
      throw StateError('Direct link is not ready');
    }
    // Leave room for text and receipts even if file writes are backed up.
    if (_pendingSends >= (bulk ? maxPendingSends - 4 : maxPendingSends)) {
      throw StateError('Direct send queue is full');
    }
    if (!_current(generation, peerId, session)) {
      throw StateError('Direct peer changed');
    }
    _pendingSends++;
    try {
      await _sends.add(() async {
        if (!_ready || !_current(generation, peerId, session)) {
          throw StateError('Direct peer changed');
        }
        await peer.send(frame);
        if (!_current(generation, peerId, session)) {
          throw StateError('Direct peer changed');
        }
      }, bulk: bulk);
    } finally {
      _pendingSends--;
    }
  }

  Future<void> _reset() async {
    _generation++;
    _sends = PrioritySendQueue();
    _negotiationTimer?.cancel();
    _negotiationTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    _ready = false;
    _offering = false;
    _session = null;
    _remoteDescriptionSet = false;
    _descriptionSignaled = false;
    _signalNumber = 0;
    _candidateCount = 0;
    _pendingCandidates.clear();
    _localCandidates.clear();
    await _disposePeer();
  }

  Future<void> _disposePeer() async {
    final peer = _peer;
    _peer = null;
    _turnPossible = false;
    _iceRoute = IceRoute.unknown;
    _checkingRoute = null;
    _remoteDescriptionSet = false;
    _pendingCandidates.clear();
    if (peer != null) {
      await peer.close();
    }
  }

  Future<bool> verifyUnmetered() async {
    await _refreshIceRoute();
    return unmetered;
  }

  Future<void>? _checkingRoute;

  Future<void> _refreshIceRoute() async {
    if (!_ready || !_turnPossible) return;
    final peer = _peer;
    if (peer is! IceRoutePeer) return;
    final check = _checkingRoute ??= _readRoute(peer as IceRoutePeer);
    try {
      await check;
    } finally {
      if (identical(_checkingRoute, check)) _checkingRoute = null;
    }
  }

  Future<void> _readRoute(IceRoutePeer peer) async {
    final generation = _generation;
    IceRoute selected;
    try {
      selected = await peer.selectedRoute().timeout(const Duration(seconds: 2));
    } catch (_) {
      selected = IceRoute.unknown;
    }
    if (!_closed &&
        generation == _generation &&
        identical(_peer, peer) &&
        _ready &&
        _iceRoute != selected) {
      _iceRoute = selected;
      _notify();
    }
  }

  void _markTurnPossible() {
    if (_turnPossible) return;
    _turnPossible = true;
    if (_ready) _notify();
  }

  void _scheduleRetry() {
    if (_closed || !_signalingAvailable || _ready || _retryTimer != null) {
      return;
    }
    _retryTimer = Timer(const Duration(seconds: 3), () {
      _retryTimer = null;
      final peerId = _peerId;
      if (peerId == null || !_signalingAvailable || _ready) {
        return;
      }
      unawaited(
        _reset()
            .then((_) async {
              if (_peerId == peerId &&
                  !_closed &&
                  _signalingAvailable &&
                  (allowEitherInitiator ||
                      ownIdentityId.compareTo(peerId) < 0)) {
                await _startOffer(peerId);
              }
            })
            .catchError((Object _) => _scheduleRetry()),
      );
    });
  }

  Future<void> recoverNetwork() async {
    if (_closed) return;
    final peer = _peerId;
    final available = _signalingAvailable;
    final request = ++_bindRequest;
    await _reset();
    if (_closed || request != _bindRequest || peer != _peerId) return;
    _notify();
    await bind(peer, signalingAvailable: available);
  }

  void _notify() {
    onChanged?.call();
    if (!_changes.isClosed) {
      _changes.add(null);
    }
  }

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _reset();
    _peerId = null;
    await _frames.close();
    await _changes.close();
  }

  static bool _validDescription(String sdp) =>
      sdp.length <= 10000 &&
      _fingerprint.hasMatch(sdp) &&
      validTurnDescription(sdp);

  static void _validateDescription(String sdp) {
    if (!_validDescription(sdp)) {
      throw const FormatException('Invalid direct SDP');
    }
  }

  static String _randomSession() {
    final random = Random.secure();
    return List<int>.generate(
      16,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }
}
