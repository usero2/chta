import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cht/account/account_models.dart';
import 'package:cht/account/desktop_identity_bridge.dart';
import 'package:cht/core/core_bridge.dart';
import 'package:cht/p2p/p2p_bridge_android.dart';
import 'package:cht/profile/profile_store.dart';
import 'package:flutter_test/flutter_test.dart';

class _Account implements AppBridge, DesktopIdentityBridge {
  final prepared = <String>[];
  int? encryptedSentAt;

  @override
  Future<ContactView> inspectContactCard(String card) async => ContactView(
    identityId: card,
    displayName: 'Desktop',
    fingerprint: 'fixture',
    verified: true,
  );
  @override
  Future<String> preparePeer(String card, bool initiator) async {
    expect(initiator, isTrue);
    prepared.add(card);
    return 'fixture-fingerprint';
  }

  @override
  Future<StoredProfile> loadDesktopProfile() async =>
      const StoredProfile(name: 'Phone');
  @override
  Future<String> contactCard({
    String displayName = '',
    String avatar = '',
  }) async => 'signed-phone-card';
  @override
  Future<String> startPeerHandshake() async => 'noise-start';
  @override
  Future<Map<String, Object?>> receivePeerHandshake(String payload) async => {
    'established': true,
  };
  @override
  Future<String> encryptPeerMessage(
    String id,
    String text, {
    int? sentAtMilliseconds,
  }) async {
    encryptedSentAt = sentAtMilliseconds;
    return 'encrypted-fixture';
  }

  @override
  Future<Map<String, Object?>> decryptPeerMessage(String payload) async => {
    'messageId': 'received-1',
    'text': 'hello',
    'sentAtMilliseconds': 1234,
  };
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _waitFor(Future<bool> Function() predicate) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (await predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Companion state did not arrive');
}

void main() {
  test(
    'a stalled secure handshake times out, closes, and can be retried',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var attempt = 0;
      final sockets = <WebSocket>[];
      final listener = server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        final reply = ++attempt > 1;
        socket.listen((data) {
          if (reply && (jsonDecode(data as String) as Map)['type'] == 'noise') {
            socket.add(jsonEncode({'type': 'noise', 'payload': 'noise-reply'}));
          }
        });
        socket.add(
          jsonEncode({'type': 'desktopHello', 'contactCard': 'desktop-id'}),
        );
      });
      final bridge = AndroidP2pBridge(
        account: _Account(),
        companionUrl: 'ws://127.0.0.1:${server.port}',
        handshakeTimeout: const Duration(milliseconds: 250),
      );
      addTearDown(() async {
        await bridge.close();
        for (final socket in sockets) {
          await socket.close();
        }
        await listener.cancel();
        await server.close(force: true);
      });
      await expectLater(
        bridge.connectContact('desktop-id', 'Phone'),
        throwsA(isA<TimeoutException>()),
      );
      expect(bridge.socket, isNull);
      expect((await bridge.status())['connectionState'], 'failed');
      await bridge.connectContact('desktop-id', 'Phone');
      expect((await bridge.status())['authenticated'], isTrue);
      expect(attempt, 2);
    },
  );

  test('Android companion checks the DID and carries encrypted messages and receipt times', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final connected = Completer<WebSocket>();
    final incoming = <Map<String, dynamic>>[];
    final listener = server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen(
        (frame) =>
            incoming.add(jsonDecode(frame as String) as Map<String, dynamic>),
      );
      connected.complete(socket);
      socket.add(
        jsonEncode({'type': 'desktopHello', 'contactCard': 'desktop-id'}),
      );
    });
    final account = _Account();
    final bridge = AndroidP2pBridge(
      account: account,
      companionUrl: 'ws://127.0.0.1:${server.port}',
    );
    addTearDown(() async {
      await bridge.close();
      await (await connected.future).close();
      await listener.cancel();
      await server.close(force: true);
    });
    final connecting = bridge.connectContact('desktop-id', 'Phone');
    await _waitFor(() async => incoming.length == 2);
    expect(account.prepared, ['desktop-id']);
    expect(incoming.first['targetIdentityId'], 'desktop-id');
    expect(incoming.last['payload'], 'noise-start');
    final socket = await connected.future;
    socket.add(jsonEncode({'type': 'noise', 'payload': 'noise-reply'}));
    await connecting;
    await _waitFor(
      () async => (await bridge.status())['authenticated'] == true,
    );
    await bridge.sendMessage('outgoing-1', 'hello', sentAtMilliseconds: 4567);
    await _waitFor(() async => incoming.length == 3);
    expect(account.encryptedSentAt, 4567);
    expect(incoming.last, {
      'type': 'ciphertext',
      'payload': 'encrypted-fixture',
    });
    socket.add(
      jsonEncode({'type': 'ciphertext', 'payload': 'incoming-fixture'}),
    );
    await _waitFor(
      () async => bridge.events.any((event) => event.type == 'message'),
    );
    final received = (await bridge.drainEvents()).singleWhere(
      (event) => event.type == 'message',
    );
    expect(received.sentAtMilliseconds, 1234);
    expect(received.receivedAtMilliseconds, isNotNull);
    await bridge.acknowledgeMessage(
      'received-1',
      received.receivedAtMilliseconds!,
    );
    await _waitFor(() async => incoming.length == 4);
    expect(
      incoming.last['receivedAtMilliseconds'],
      received.receivedAtMilliseconds,
    );
    socket.add(
      jsonEncode({
        'type': 'ack',
        'messageId': 'outgoing-1',
        'receivedAtMilliseconds': 5678,
      }),
    );
    await _waitFor(
      () async => bridge.events.any((event) => event.type == 'delivered'),
    );
    expect((await bridge.drainEvents()).single.receivedAtMilliseconds, 5678);
  });

  test('Android refuses a Desktop whose signed DID differs from the selected contact', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    WebSocket? connection;
    final listener = server.listen((request) async {
      connection = await WebSocketTransformer.upgrade(request);
      connection!.listen((_) {});
      connection!.add(
        jsonEncode({'type': 'desktopHello', 'contactCard': 'different-id'}),
      );
    });
    final account = _Account();
    final bridge = AndroidP2pBridge(
      account: account,
      companionUrl: 'ws://127.0.0.1:${server.port}',
    );
    addTearDown(() async {
      await bridge.close();
      await connection?.close();
      await listener.cancel();
      await server.close(force: true);
    });
    await expectLater(
      bridge.connectContact('selected-id', 'Phone'),
      throwsStateError,
    );
    expect(account.prepared, isEmpty);
    expect((await bridge.status())['authenticated'], isFalse);
    expect((await bridge.status())['connectionState'], 'failed');
    expect(bridge.socket, isNull);
  });
}
