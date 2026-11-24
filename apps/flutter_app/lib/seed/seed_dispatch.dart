import 'dart:async';
import 'dart:convert';

import 'seed_crypto_bridge.dart';

/// A single socket owns its sequence. Proof signing and sending are serialized.
class SeedDispatchSession {
  int _generation = 0, _sequence = 0, _queued = 0;
  String? _seed, _connection;
  final _nonces = <String>{};
  Future<void> _tail = Future.value();

  void configure(Map<String, dynamic> challenge, String seedId, Object crypto) {
    reset();
    if (crypto is! SeedDispatchCryptoBridge ||
        challenge['capabilities'] is! List ||
        !(challenge['capabilities'] as List).contains('session-dispatch-v1')) {
      return;
    }
    final nonce = challenge['nonce'];
    if (challenge['seedId'] != seedId ||
        nonce is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(nonce) ||
        base64UrlEncode(base64Url.decode(base64Url.normalize(nonce)))
                .replaceAll('=', '') !=
            nonce ||
        !_nonces.add(nonce)) {
      throw const FormatException('Invalid seed dispatch challenge');
    }
    if (_nonces.length > 64) _nonces.remove(_nonces.first);
    _seed = seedId;
    _connection = nonce;
  }

  void reset() {
    _generation++;
    _sequence = 0;
    _queued = 0;
    _seed = null;
    _connection = null;
    _tail = Future.value();
  }

  Future<void> send(
    Map<String, dynamic> envelope, {
    required Object crypto,
    required Future<bool> Function() isActive,
    required void Function(Map<String, dynamic>) emit,
  }) {
    if (_queued >= 16) {
      return Future.error(StateError('Seed signaling queue full'));
    }
    final generation = _generation, seed = _seed, connection = _connection;
    _queued++;
    final operation = _tail
        .then((_) async {
          if (generation != _generation ||
              !await isActive() ||
              generation != _generation) {
            throw StateError('Seed session changed');
          }
          final frame = <String, dynamic>{
            'type': 'signal',
            'envelope': envelope,
          };
          if (seed != null && connection != null) {
            if (crypto is! SeedDispatchCryptoBridge ||
                _sequence >= 9007199254740991) {
              throw StateError('Seed dispatch unavailable');
            }
            frame['dispatch'] = jsonDecode(
              await crypto.signSeedDispatch(
                seed,
                connection,
                ++_sequence,
                jsonEncode(envelope),
              ),
            );
          }
          if (utf8.encode(jsonEncode(frame)).length > 16384) {
            throw const FormatException('Signal too large');
          }
          if (generation != _generation ||
              !await isActive() ||
              generation != _generation) {
            throw StateError('Seed session changed');
          }
          emit(frame);
        })
        .whenComplete(() {
          if (generation == _generation) _queued--;
        });
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }
}
