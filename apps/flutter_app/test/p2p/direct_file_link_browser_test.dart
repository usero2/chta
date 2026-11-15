import 'dart:async';

import 'package:cht/p2p/direct_file_link.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'real browser WebRTC peers exchange data after signaling loss',
    () async {
      late DirectFileLink alice;
      late DirectFileLink bob;
      final received = Completer<String>();
      alice = DirectFileLink(
        ownIdentityId: 'disposable-alice',
        sendSignal: (id, text) => bob.receiveSignal(id, text),
      );
      bob = DirectFileLink(
        ownIdentityId: 'disposable-bob',
        sendSignal: (id, text) => alice.receiveSignal(id, text),
      );
      final subscription = bob.frames.listen((frame) {
        if (!received.isCompleted) received.complete(frame);
      });
      try {
        await bob.bind('disposable-alice', signalingAvailable: true);
        await alice.bind('disposable-bob', signalingAvailable: true);
        final deadline = DateTime.now().add(const Duration(seconds: 20));
        while (!(alice.ready && bob.ready) &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(alice.ready && bob.ready, isTrue);
        await alice.bind('disposable-bob', signalingAvailable: false);
        await bob.bind('disposable-alice', signalingAvailable: false);
        await alice.send('synthetic-direct-frame');
        expect(
          await received.future.timeout(const Duration(seconds: 5)),
          'synthetic-direct-frame',
        );
      } finally {
        await subscription.cancel();
        await alice.close();
        await bob.close();
      }
    },
    skip: !kIsWeb,
  );
}
