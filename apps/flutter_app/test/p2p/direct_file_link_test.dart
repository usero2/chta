import 'dart:async';
import 'dart:convert';

import 'package:cht/p2p/direct_file_link.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('queued Direct chunks yield to text and receipts', () async {
    final gate = Completer<void>();
    final factory = FakeFactory()..sendGate = gate.future;
    final link = DirectFileLink(
      ownIdentityId: 'alice',
      sendSignal: (_, _) async {},
      peerFactory: factory,
    );
    try {
      await link.bind('bob', signalingAvailable: true);
      final peer = factory.peers.single;
      peer.onReadyChanged?.call(true);
      final first = link.send('first file chunk', bulk: true);
      await Future<void>.delayed(Duration.zero);
      final second = link.send('second file chunk', bulk: true);
      final text = link.send('chat text');
      final receipt = link.send('receipt');
      gate.complete();
      await Future.wait([first, second, text, receipt]);
      expect(peer.sent, [
        'first file chunk',
        'chat text',
        'receipt',
        'second file chunk',
      ]);
    } finally {
      if (!gate.isCompleted) gate.complete();
      await link.close();
    }
  });

  test(
    'network recovery replaces the old channel and preserves the selected peer',
    () async {
      final factory = FakeFactory(), signals = <String>[];
      final link = DirectFileLink(
        ownIdentityId: 'alice',
        peerFactory: factory,
        sendSignal: (id, _) async => signals.add(id),
      );
      await link.bind('bob', signalingAvailable: true);
      expect(factory.peers.length, 1);
      await link.recoverNetwork();
      expect(factory.peers.first.closed, isTrue);
      expect(factory.peers.length, 2);
      expect(link.peerId, 'bob');
      expect(signals.where((id) => id.contains('-offer-')).length, 2);
      await link.close();
      await link.recoverNetwork();
      expect(factory.peers.length, 2);
    },
  );
  test('ICE waits behind glare disposal instead of being lost', () async {
    final gate = Completer<void>(), factory = FakeFactory();
    final link = DirectFileLink(
      ownIdentityId: 'bob',
      allowEitherInitiator: true,
      peerFactory: factory,
      sendSignal: (_, _) async {},
    );
    final session = 'e' * 32;
    try {
      await link.bind('alice', signalingAvailable: true);
      factory.peers.first.closeGate = gate.future;
      final offer = link.receiveSignal(
        '${DirectFileLink.controlPrefix}$session-offer-1',
        jsonEncode({
          'v': 1,
          't': 'offer',
          's': session,
          'd': 'v=0\na=fingerprint:sha-256 ${FakePeer.fingerprint}\n',
        }),
      );
      await Future<void>.delayed(Duration.zero);
      final ice = link.receiveSignal(
        '${DirectFileLink.controlPrefix}$session-ice-2',
        jsonEncode({
          'v': 1,
          't': 'ice',
          's': session,
          'c': 'candidate:1 1 udp 1 127.0.0.1 9 typ host',
          'm': '0',
          'l': 0,
        }),
      );
      gate.complete();
      await offer;
      await ice;
      expect(factory.peers.last.addedCandidates, hasLength(1));
    } finally {
      if (!gate.isCompleted) gate.complete();
      await link.close();
    }
  });
  testWidgets(
    'missing setup reply retries without waiting for an ICE failure',
    (tester) async {
      final factory = FakeFactory();
      final link = DirectFileLink(
        ownIdentityId: 'alice',
        sendSignal: (_, _) async {},
        peerFactory: factory,
      );
      await link.bind('bob', signalingAvailable: true);
      expect(factory.peers, hasLength(1));
      await tester.pump(const Duration(seconds: 21));
      await tester.pump(const Duration(seconds: 4));
      expect(factory.peers.first.closed, isTrue);
      expect(factory.peers, hasLength(2));
      await link.close();
    },
  );
  test(
    'group links allow either inviter and resolve simultaneous offers',
    () async {
      final aSignals = <(String, String)>[], bSignals = <(String, String)>[];
      final af = FakeFactory(), bf = FakeFactory();
      final a = DirectFileLink(
        ownIdentityId: 'alice',
        allowEitherInitiator: true,
        sendSignal: (id, text) async => aSignals.add((id, text)),
        peerFactory: af,
      );
      final b = DirectFileLink(
        ownIdentityId: 'bob',
        allowEitherInitiator: true,
        sendSignal: (id, text) async => bSignals.add((id, text)),
        peerFactory: bf,
      );
      await b.bind('alice', signalingAvailable: true);
      expect(bSignals, hasLength(1));
      await a.bind('bob', signalingAvailable: true);
      await a.receiveSignal(bSignals.first.$1, bSignals.first.$2);
      await b.receiveSignal(aSignals.first.$1, aSignals.first.$2);
      expect(bf.peers.first.closed, isTrue);
      final answer = bSignals.last;
      expect(jsonDecode(answer.$2)['t'], 'answer');
      await a.receiveSignal(answer.$1, answer.$2);
      af.peers.last.onReadyChanged?.call(true);
      bf.peers.last.onReadyChanged?.call(true);
      expect(a.ready && b.ready, isTrue);
      await a.close();
      await b.close();
    },
  );

  test('lower identity offers and authenticated answer opens a link', () async {
    final aSignals = <(String, String)>[];
    final bSignals = <(String, String)>[];
    final aFactory = FakeFactory();
    final bFactory = FakeFactory();
    final a = DirectFileLink(
      ownIdentityId: 'alice',
      sendSignal: (id, text) async => aSignals.add((id, text)),
      peerFactory: aFactory,
    );
    final b = DirectFileLink(
      ownIdentityId: 'bob',
      sendSignal: (id, text) async => bSignals.add((id, text)),
      peerFactory: bFactory,
    );
    await a.bind('bob', signalingAvailable: true);
    await b.bind('alice', signalingAvailable: true);
    expect(aSignals, hasLength(1));
    expect(bSignals, isEmpty);
    expect(aSignals.single.$1, startsWith('cht-control-direct-v1-'));
    await b.receiveSignal(aSignals.single.$1, aSignals.single.$2);
    expect(bSignals, hasLength(1));
    await a.receiveSignal(bSignals.single.$1, bSignals.single.$2);
    aFactory.peers.single.onReadyChanged?.call(true);
    bFactory.peers.single.onReadyChanged?.call(true);
    expect(a.ready, isTrue);
    expect(b.ready, isTrue);
    await a.close();
    await b.close();
  });

  test(
    'relay loss preserves direct link and explicit peer switch closes it',
    () async {
      final signals = <(String, String)>[];
      final factory = FakeFactory();
      final link = DirectFileLink(
        ownIdentityId: 'alice',
        sendSignal: (id, text) async => signals.add((id, text)),
        peerFactory: factory,
      );
      await link.bind('bob', signalingAvailable: true);
      factory.peers.single.onReadyChanged?.call(true);
      await link.bind('bob', signalingAvailable: false);
      expect(link.ready, isTrue);
      await link.send('hello');
      expect(factory.peers.single.sent, ['hello']);
      await link.bind('carol', signalingAvailable: false);
      expect(link.ready, isFalse);
      expect(factory.peers.single.closed, isTrue);
      expect(signals, hasLength(1));
      await link.close();
    },
  );

  test('old offer completion cannot signal after peer switch', () async {
    final signals = <(String, String)>[];
    final factory = FakeFactory();
    final gate = Completer<void>();
    factory.offerGate = gate.future;
    final link = DirectFileLink(
      ownIdentityId: 'alice',
      sendSignal: (id, text) async => signals.add((id, text)),
      peerFactory: factory,
    );
    final firstBind = link.bind('bob', signalingAvailable: true);
    await Future<void>.delayed(Duration.zero);
    await link.bind('carol', signalingAvailable: false);
    gate.complete();
    await firstBind;
    expect(signals, isEmpty);
    expect(factory.peers.single.closed, isTrue);
    await link.close();
  });

  test('rejects unreserved controls and relay ICE candidates', () async {
    final factory = FakeFactory();
    final signals = <(String, String)>[];
    final link = DirectFileLink(
      ownIdentityId: 'alice',
      sendSignal: (id, text) async => signals.add((id, text)),
      peerFactory: factory,
    );
    await link.bind('bob', signalingAvailable: true);
    await link.receiveSignal('other-control', '{"v":1,"t":"offer"}');
    final session =
        (jsonDecode(signals.single.$2) as Map<String, dynamic>)['s'];
    await link.receiveSignal(
      '${DirectFileLink.controlPrefix}$session-answer-1',
      jsonEncode({
        'v': 1,
        't': 'answer',
        's': session,
        'd': 'v=0\na=fingerprint:sha-256 ${FakePeer.fingerprint}\n',
      }),
    );
    await link.receiveSignal(
      '${DirectFileLink.controlPrefix}$session-ice-2',
      jsonEncode({
        'v': 1,
        't': 'ice',
        's': session,
        'c': 'candidate:1 1 udp 1 127.0.0.1 1 typ relay',
      }),
    );
    expect(factory.peers.single.addedCandidates, isEmpty);
    await link.close();
  });

  test('ICE generated during offer is sent after the offer control', () async {
    final signals = <(String, String)>[];
    final factory = FakeFactory()..candidateDuringOffer = true;
    final link = DirectFileLink(
      ownIdentityId: 'alice',
      sendSignal: (id, text) async => signals.add((id, text)),
      peerFactory: factory,
    );
    await link.bind('bob', signalingAvailable: true);
    expect(signals, hasLength(2));
    expect(signals.first.$1, contains('-offer-'));
    expect(signals.last.$1, contains('-ice-'));
    await link.close();
  });

  test(
    'answer is suppressed when peer changes during remote SDP await',
    () async {
      final signals = <(String, String)>[];
      final a = DirectFileLink(
        ownIdentityId: 'alice',
        sendSignal: (id, text) async => signals.add((id, text)),
        peerFactory: FakeFactory(),
      );
      final gate = Completer<void>();
      final bFactory = FakeFactory()..remoteGate = gate.future;
      final b = DirectFileLink(
        ownIdentityId: 'bob',
        sendSignal: (id, text) async => signals.add((id, text)),
        peerFactory: bFactory,
      );
      await a.bind('bob', signalingAvailable: true);
      await b.bind('alice', signalingAvailable: true);
      final answering = b.receiveSignal(signals.single.$1, signals.single.$2);
      await Future<void>.delayed(Duration.zero);
      await b.bind('carol', signalingAvailable: false);
      gate.complete();
      await answering;
      expect(signals, hasLength(1));
      expect(bFactory.peers.single.closed, isTrue);
      await a.close();
      await b.close();
    },
  );

  test('oversized frame is rejected before the data channel send', () async {
    final factory = FakeFactory();
    final link = DirectFileLink(
      ownIdentityId: 'alice',
      sendSignal: (id, text) async {},
      peerFactory: factory,
    );
    await link.bind('bob', signalingAvailable: true);
    factory.peers.single.onReadyChanged?.call(true);
    await expectLater(
      link.send('a' * (DirectFileLink.maxFrameBytes + 1)),
      throwsFormatException,
    );
    expect(factory.peers.single.sent, isEmpty);
    await link.close();
  });

  test('concurrent sends have a bounded pending queue', () async {
    final gate = Completer<void>();
    final factory = FakeFactory()..sendGate = gate.future;
    final link = DirectFileLink(
      ownIdentityId: 'alice',
      sendSignal: (id, text) async {},
      peerFactory: factory,
    );
    await link.bind('bob', signalingAvailable: true);
    factory.peers.single.onReadyChanged?.call(true);
    final pending = <Future<void>>[];
    for (var i = 0; i < 32; i++) {
      pending.add(link.send('$i'));
    }
    await expectLater(link.send('overflow'), throwsStateError);
    gate.complete();
    await Future.wait(pending);
    expect(factory.peers.single.sent, hasLength(32));
    await link.close();
  });

  test('failed direct link renegotiates when signaling returns', () async {
    final signals = <(String, String)>[];
    final factory = FakeFactory();
    final link = DirectFileLink(
      ownIdentityId: 'alice',
      sendSignal: (id, text) async => signals.add((id, text)),
      peerFactory: factory,
    );
    await link.bind('bob', signalingAvailable: true);
    factory.peers.single.onReadyChanged?.call(true);
    await link.bind('bob', signalingAvailable: false);
    factory.peers.single.onReadyChanged?.call(false);
    expect(link.ready, isFalse);
    await link.bind('bob', signalingAvailable: true);
    expect(factory.peers, hasLength(2));
    expect(factory.peers.first.closed, isTrue);
    expect(
      signals.where((signal) => signal.$1.contains('-offer-')),
      hasLength(2),
    );
    await link.close();
  });

  test(
    'older bind cannot overwrite newer peer after asynchronous close',
    () async {
      final factory = FakeFactory();
      final link = DirectFileLink(
        ownIdentityId: 'alice',
        sendSignal: (id, text) async {},
        peerFactory: factory,
      );
      await link.bind('bob', signalingAvailable: true);
      final closeGate = Completer<void>();
      factory.peers.single.closeGate = closeGate.future;
      final oldBind = link.bind('carol', signalingAvailable: false);
      await Future<void>.delayed(Duration.zero);
      await link.bind('dave', signalingAvailable: false);
      closeGate.complete();
      await oldBind;
      expect(link.peerId, 'dave');
      await link.close();
    },
  );
}

class FakeFactory implements DirectPeerFactory {
  final peers = <FakePeer>[];
  Future<void>? offerGate;
  Future<void>? remoteGate;
  Future<void>? sendGate;
  bool candidateDuringOffer = false;

  @override
  Future<DirectPeer> create() async {
    final peer = FakePeer()
      ..offerGate = offerGate
      ..remoteGate = remoteGate
      ..sendGate = sendGate
      ..candidateDuringOffer = candidateDuringOffer;
    peers.add(peer);
    return peer;
  }
}

class FakePeer implements DirectPeer {
  static const fingerprint =
      'AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA';
  @override
  void Function(String candidate, String? mid, int? line)? onIceCandidate;
  @override
  void Function(String frame)? onFrame;
  @override
  void Function(bool ready)? onReadyChanged;
  Future<void>? offerGate;
  Future<void>? remoteGate;
  Future<void>? sendGate;
  Future<void>? closeGate;
  bool candidateDuringOffer = false;
  bool closed = false;
  final sent = <String>[];
  final addedCandidates = <String>[];

  @override
  Future<String> createOffer() async {
    if (candidateDuringOffer) {
      onIceCandidate?.call('candidate:1 1 udp 1 127.0.0.1 9 typ host', '0', 0);
    }
    await offerGate;
    return 'v=0\na=fingerprint:sha-256 $fingerprint\n';
  }

  @override
  Future<String> createAnswer() async =>
      'v=0\na=fingerprint:sha-256 $fingerprint\n';

  @override
  Future<void> setRemoteDescription(String type, String sdp) async {
    await remoteGate;
  }

  @override
  Future<void> addIceCandidate(String candidate, String? mid, int? line) async {
    addedCandidates.add(candidate);
  }

  @override
  Future<void> send(String frame) async {
    await sendGate;
    sent.add(frame);
  }

  @override
  Future<void> close() async {
    await closeGate;
    closed = true;
  }
}
