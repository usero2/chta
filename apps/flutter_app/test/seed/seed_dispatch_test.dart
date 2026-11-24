import 'dart:async';
import 'dart:convert';

import 'package:cht/seed/seed_crypto_bridge.dart';
import 'package:cht/seed/seed_dispatch.dart';
import 'package:flutter_test/flutter_test.dart';

const seed = 'e0ba672185682a830d168e31cee185b9434b49b210a7ec7a435e78fcb2a532a5';
Map<String, dynamic> challenge([int byte = 5]) => {
  'seedId': seed,
  'nonce': base64UrlEncode(List.filled(32, byte)).replaceAll('=', ''),
  'capabilities': ['session-dispatch-v1'],
};

class Crypto implements SeedDispatchCryptoBridge {
  Completer<void>? gate;
  final sequences = <int>[];
  @override
  Future<String> signSeedDispatch(
    String seedId,
    String connection,
    int sequence,
    String envelopeJson,
  ) async {
    sequences.add(sequence);
    await gate?.future;
    return jsonEncode({'sequence': sequence, 'connection': connection});
  }
}

void main() {
  test(
    'concurrent topics sign and emit in sequence without changing the envelope',
    () async {
      final crypto = Crypto()..gate = Completer<void>(),
          session = SeedDispatchSession();
      session.configure(challenge(), seed, crypto);
      final sent = <Map<String, dynamic>>[];
      final jobs = [
        for (final topic in ['direct', 'groups', 'contacts'])
          session.send(
            {'topic': topic},
            crypto: crypto,
            isActive: () async => true,
            emit: sent.add,
          ),
      ];
      await Future<void>.delayed(Duration.zero);
      expect(crypto.sequences, [1]);
      crypto.gate!.complete();
      await Future.wait(jobs);
      expect(crypto.sequences, [1, 2, 3]);
      expect(sent.map((f) => (f['dispatch'] as Map)['sequence']), [1, 2, 3]);
      expect(sent.map((f) => (f['envelope'] as Map)['topic']), [
        'direct',
        'groups',
        'contacts',
      ]);
    },
  );
  test(
    'reset and identity lock during signing never emit stale frames',
    () async {
      for (final reset in [true, false]) {
        final crypto = Crypto()..gate = Completer<void>(),
            session = SeedDispatchSession();
        session.configure(challenge(), seed, crypto);
        var active = true;
        final sent = <Map<String, dynamic>>[];
        final job = session.send(
          {'topic': 'direct'},
          crypto: crypto,
          isActive: () async => active,
          emit: sent.add,
        );
        final check = expectLater(job, throwsStateError);
        await Future<void>.delayed(Duration.zero);
        if (reset) {
          session.reset();
        } else {
          active = false;
        }
        crypto.gate!.complete();
        await check;
        expect(sent, isEmpty);
      }
    },
  );
  test('legacy bridge/server keep original frame, unsafe and reused upgraded nonce fail', () async {
    final crypto = Crypto(),
        session = SeedDispatchSession(),
        sent = <Map<String, dynamic>>[];
    session.configure(challenge(), seed, Object());
    await session.send(
      {'topic': 'contacts'},
      crypto: Object(),
      isActive: () async => true,
      emit: sent.add,
    );
    expect(sent.single, {
      'type': 'signal',
      'envelope': {'topic': 'contacts'},
    });
    session.configure({...challenge(), 'capabilities': []}, seed, crypto);
    await session.send(
      {'topic': 'groups'},
      crypto: crypto,
      isActive: () async => true,
      emit: sent.add,
    );
    expect(sent.last.containsKey('dispatch'), isFalse);
    session.configure(challenge(), seed, crypto);
    session.reset();
    expect(
      () => session.configure(challenge(), seed, crypto),
      throwsFormatException,
    );
    expect(
      () => session.configure({...challenge(6), 'nonce': 'x'}, seed, crypto),
      throwsFormatException,
    );
  });
}
