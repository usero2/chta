import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cht/chat/attachment_transfer.dart';
import 'package:cht/chat/chat_attachment.dart';
import 'package:cht/chat/peer_history.dart';
import 'package:cht/chat/peer_history_store.dart';
import 'package:cht/chat/attachment_store.dart';
import 'package:cht/chat/attachment_ref.dart';
import 'package:cht/chat/attachment_source.dart';
import 'package:cht/chat/chunked_attachment_bridge.dart';
import 'package:cht/chat/widgets/message_composer.dart';

import 'package:cht/account/account_bridge.dart';
import 'package:cht/account/account_models.dart';
import 'package:cht/p2p/connection_page.dart';
import 'package:cht/p2p/p2p_bridge.dart';
import 'package:cht/p2p/direct_file_link.dart';
import 'package:cht/relay/relay_crypto_bridge.dart';
import 'package:cht/seed/seed_crypto_bridge.dart';
import 'package:cht/seed/seed_client.dart';

import '../seed/seed_client_test.dart' as seed_test;
import '../contact_requests/contact_request_controller_test.dart'
    as request_test;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'incoming text is acknowledged only after durable history succeeds, including retry',
    (tester) async {
      final store = _GatedHistoryStore();
      final savedHistory = PeerHistory(store: store);
      await savedHistory.load('me');
      final bridge = _FakeP2pBridge(authenticated: true);
      final account = _FakeAccountBridge()
        ..savedContacts.add(
          const ContactView(
            identityId: 'did:cht:peer',
            displayName: 'Alice',
            fingerprint: 'test',
            verified: true,
          ),
        );
      await tester.pumpWidget(
        MaterialApp(
          home: ConnectionPage(
            accountBridge: account,
            bridge: bridge,
            targetContactId: 'did:cht:peer',
            chatMode: true,
            peerHistory: savedHistory,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      const event = PeerEvent(
        type: 'message',
        messageId: 'durable-text',
        text: 'Synthetic receive',
        sentAtMilliseconds: 1000,
        receivedAtMilliseconds: 2000,
      );
      store.gate = Completer<void>();
      store.fail = true;
      bridge.pendingEvents.add(event);
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        bridge.receipts,
        isEmpty,
        reason: 'Queued writes are not durable delivery',
      );
      store.gate!.complete();
      await tester.pump();
      await tester.pump();
      expect(
        bridge.receipts,
        isEmpty,
        reason: 'A failed disk write must not acknowledge delivery',
      );
      store.gate = null;
      store.fail = false;
      bridge.pendingEvents.add(event);
      await tester.pump(const Duration(milliseconds: 500));
      expect(bridge.receipts, [('durable-text', 2000)]);
      expect(savedHistory.messagesFor('did:cht:peer'), hasLength(1));
      expect(store.values['me'], contains('Synthetic receive'));
      await tester.pumpWidget(const SizedBox());
      savedHistory.dispose();
    },
  );
  testWidgets(
    'scanning a saved contact QR queues the reciprocal Review request',
    (tester) async {
      final account = request_test.Account(request_test.alice),
          store = request_test.Blobs();
      await account.addContact(request_test.card(request_test.bob), '');
      await account.markContactVerified(request_test.bob);
      final requests = request_test.controller(account, store);
      await requests.initialize();
      await tester.pumpWidget(
        MaterialApp(
          home: ConnectionPage(
            accountBridge: account,
            bridge: _FakeP2pBridge(),
            requests: requests,
            targetContactId: request_test.bob,
            chatMode: true,
            scanRelayQr: () async => request_test.card(request_test.bob),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('Scan QR'));
      await tester.pumpAndSettle();
      expect(requests.statusFor(request_test.bob), isNotNull);
      await tester.pumpWidget(const SizedBox());
      unawaited(requests.close());
      await tester.pump();
    },
  );
  testWidgets('automatic chat setup works with a default unnamed identity', (
    tester,
  ) async {
    final bridge = _FakeP2pBridge(automaticSupported: true);
    final account = _FakeAccountBridge()
      ..savedContacts.add(
        const ContactView(
          identityId: 'did:cht:peer',
          displayName: 'Friend',
          fingerprint: 'test',
          verified: true,
        ),
      );
    await tester.pumpWidget(
      MaterialApp(
        home: ConnectionPage(
          accountBridge: account,
          bridge: bridge,
          targetContactId: 'did:cht:peer',
          chatMode: true,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(bridge.connectCount, greaterThan(0));
    expect(bridge.connectedDisplayName, startsWith('Identity '));
    expect(find.text('Set your Profile name before connecting.'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'existing friend can request Review and pending setup is not labelled offline',
    (tester) async {
      final account = request_test.Account(request_test.alice),
          store = request_test.Blobs();
      await account.addContact(request_test.card(request_test.bob), '');
      await account.markContactVerified(request_test.bob);
      final requests = request_test.controller(account, store);
      await requests.initialize();
      await tester.pumpWidget(
        MaterialApp(
          home: ConnectionPage(
            accountBridge: account,
            bridge: _FakeP2pBridge(),
            targetContactId: request_test.bob,
            chatMode: true,
            requests: requests,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Send request'), findsOneWidget);
      await tester.tap(find.text('Send request'));
      await tester.pumpAndSettle();
      expect(requests.statusFor(request_test.bob), isNotNull);
      expect(find.text('Bob is offline'), findsNothing);
      expect(find.text('Request pending'), findsWidgets);
      await tester.pumpWidget(const SizedBox());
      unawaited(requests.close());
      await tester.pump();
    },
  );
  for (final connected in [false, true]) {
    testWidgets(
      'mobile peer chat opens at latest message (connected=$connected)',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final history = PeerHistory();
        final account = _FakeAccountBridge()
          ..savedContacts.add(
            const ContactView(
              identityId: 'did:cht:peer',
              displayName: 'Alice',
              fingerprint: 'AA11',
              verified: true,
            ),
          );
        await tester.pumpWidget(
          MaterialApp(
            home: ConnectionPage(
              accountBridge: account,
              bridge: _FakeP2pBridge(authenticated: connected),
              targetContactId: 'did:cht:peer',
              chatMode: true,
              peerHistory: history,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
        // History may finish loading after the room has already opened.
        for (var i = 0; i < 40; i++) {
          history.add(
            'did:cht:peer',
            PeerMessage(
              id: 'history-$i',
              text: 'History message $i',
              incoming: true,
              status: DeliveryStatus.delivered,
            ),
          );
        }
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('peer-message-history-39')).hitTestable(),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('peer-message-history-0')).hitTestable(),
          findsNothing,
        );
        history.add(
          'did:cht:peer',
          PeerMessage(
            id: 'newest',
            text: 'New incoming message',
            incoming: true,
            status: DeliveryStatus.delivered,
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('peer-message-newest')).hitTestable(),
          findsOneWidget,
        );
        final list = find.ancestor(
          of: find.byKey(const Key('peer-message-newest')),
          matching: find.byType(ListView),
        );
        final scroll = tester.state<ScrollableState>(
          find.descendant(of: list, matching: find.byType(Scrollable)).first,
        );
        await tester.drag(list, const Offset(0, 1100));
        await tester.pumpAndSettle();
        final before = scroll.position.pixels;
        history.add(
          'did:cht:peer',
          PeerMessage(
            id: 'while-reading',
            text: 'Another incoming message',
            incoming: true,
            status: DeliveryStatus.delivered,
          ),
        );
        await tester.pumpAndSettle();
        expect(
          scroll.position.pixels,
          before,
          reason: 'Do not interrupt reading older messages',
        );
        expect(
          find.byKey(const Key('peer-message-while-reading')).hitTestable(),
          findsNothing,
        );
        await tester.pumpWidget(const SizedBox());
        history.dispose();
      },
    );
  }
  testWidgets(
    'idle node accepts verified WebRTC offer without opening a chat page',
    (tester) async {
      final account = _SeedAccount()
        ..savedContacts.add(seed_test.contact(seed_test.peer));
      final socket = seed_test.Socket(), factory = _QuietDirectFactory();
      final key = GlobalKey<ConnectionPageState>();
      await tester.pumpWidget(
        MaterialApp(
          home: ConnectionPage(
            key: key,
            accountBridge: account,
            bridge: _FakeP2pBridge(authenticated: false),
            directPeerFactory: factory,
            relayHostFactory: () => null,
            relayConnector: (_) async => socket,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      socket.receive({
        'type': 'challenge',
        'protocol': 'chta-seed',
        'version': 1,
        'seedId': seedId,
        'nonce': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      });
      await tester.pump();
      await tester.pump();
      socket.receive({
        'type': 'registered',
        'protocol': 'chta-seed',
        'version': 1,
      });
      await tester.pump();
      await tester.pump();
      final session = 'e' * 32;
      socket.receive({
        'type': 'signal',
        'envelope': {
          'from': seed_test.peer,
          'to': seed_test.owner,
          'id': 'cht-control-direct-v1-$session-offer-1',
          'payload': jsonEncode({
            'v': 1,
            't': 'offer',
            's': session,
            'd':
                'v=0\na=fingerprint:sha-256 ${List.filled(32, 'AA').join(':')}\n',
          }),
          'signature': 'valid',
          'expiresAt': DateTime.now().millisecondsSinceEpoch + 1000,
        },
      });
      for (var i = 0; i < 10; i++) {
        await tester.pump();
      }
      expect(key.currentState!.fileController?.peerId, seed_test.peer);
      expect(socket.sent.where((p) => p['type'] == 'signal'), isNotEmpty);
      expect((key.currentWidget as ConnectionPage).chatMode, isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'unlocked chat automatically negotiates seed Direct with an older verified friend',
    (tester) async {
      final account = _SeedAccount()
        ..savedContacts.add(seed_test.contact(seed_test.peer));
      final socket = seed_test.Socket();
      final factory = _QuietDirectFactory();
      await tester.pumpWidget(
        MaterialApp(
          home: ConnectionPage(
            accountBridge: account,
            bridge: _FakeP2pBridge(authenticated: false),
            targetContactId: seed_test.peer,
            chatMode: true,
            directPeerFactory: factory,
            relayHostFactory: () => null,
            relayConnector: (_) async => socket,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      socket.receive({
        'type': 'challenge',
        'protocol': 'chta-seed',
        'version': 1,
        'seedId': seedId,
        'nonce': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      });
      await tester.pump();
      await tester.pump();
      socket.receive({
        'type': 'registered',
        'protocol': 'chta-seed',
        'version': 1,
      });
      await tester.pump();
      await tester.pump();
      final offers = socket.sent.where((f) => f['type'] == 'signal').toList();
      expect(offers, hasLength(1));
      final sent = offers.single['envelope'] as Map;
      final payload = jsonDecode(sent['payload'] as String) as Map;
      final session = payload['s'];
      socket.receive({
        'type': 'signal',
        'envelope': {
          'from': seed_test.peer,
          'to': seed_test.owner,
          'id': 'cht-control-direct-v1-$session-answer-1',
          'payload': jsonEncode({
            'v': 1,
            't': 'answer',
            's': session,
            'd': payload['d'],
          }),
          'signature': 'valid',
          'expiresAt': DateTime.now().millisecondsSinceEpoch + 1000,
        },
      });
      await tester.pump();
      await tester.pump();
      factory.peer!.onReadyChanged?.call(true);
      await tester.pump();
      expect(find.text('Direct · connected securely'), findsOneWidget);
      expect(
        find.text('Connected securely'),
        findsOneWidget,
        reason: 'The room list must not label a live Direct peer Offline',
      );
      expect(find.byType(MessageComposer), findsOneWidget);
      expect(
        socket.sent.where(
          (f) => ['route', 'message', 'packet', 'file'].contains(f['type']),
        ),
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'signed files-v2 enables streamed picker limit and durable spool',
    (tester) async {
      final account = _ChunkedAccount()
        ..savedContacts.add(
          const ContactView(
            identityId: 'did:cht:peer',
            displayName: 'Alice',
            fingerprint: 'AA',
            verified: true,
            capabilities: ['files-v2'],
          ),
        );
      final history = PeerHistory(
        store: _MemoryHistoryStore(),
        attachments: createAttachmentStore(bridge: account),
      );
      await history.load('did:cht:local');
      final bridge = _FakeP2pBridge(authenticated: true);
      final source = _TinySource();
      await tester.pumpWidget(
        MaterialApp(
          home: ConnectionPage(
            bridge: bridge,
            accountBridge: account,
            targetContactId: 'did:cht:peer',
            chatMode: true,
            peerHistory: history,
            directPeerFactory: _QuietDirectFactory(),
            pickAttachments: (_) async => [
              ChatAttachment.fromSource(
                name: 'large.txt',
                mimeType: 'text/plain',
                source: source,
              ),
            ],
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        tester
            .widget<MessageComposer>(find.byType(MessageComposer))
            .maxAttachmentBytes,
        ChatAttachment.maxStreamedBytes,
      );
      await tester.tap(find.byKey(const Key('attach-message')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Files'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('send-peer-message')));
      await tester.pump(const Duration(milliseconds: 200));
      final message = history.messagesFor('did:cht:peer').single;
      expect(source.reads, 1);
      expect(message.attachmentRef?.isChunked, isTrue);
      expect(message.status, DeliveryStatus.pending);
      expect(
        bridge.sentFilePackets.any(
          (packet) => packet.$1.startsWith('chtfile2_'),
        ),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
      history.dispose();
    },
  );

  testWidgets(
    'reserved direct controls stay hidden and unsigned capability keeps legacy limit',
    (tester) async {
      final account = _ChunkedAccount()
        ..savedContacts.add(
          const ContactView(
            identityId: 'did:cht:peer',
            displayName: 'Alice',
            fingerprint: 'AA',
            verified: true,
          ),
        );
      final bridge = _FakeP2pBridge(authenticated: true)
        ..pendingEvents.add(
          const PeerEvent(
            type: 'message',
            messageId: 'cht-control-direct-v1-hidden',
            text: 'secret',
            receivedAtMilliseconds: 10,
          ),
        );
      final history = PeerHistory();
      await tester.pumpWidget(
        MaterialApp(
          home: ConnectionPage(
            bridge: bridge,
            accountBridge: account,
            targetContactId: 'did:cht:peer',
            chatMode: true,
            peerHistory: history,
            directPeerFactory: _QuietDirectFactory(),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(history.messagesFor('did:cht:peer'), isEmpty);
      expect(find.text('secret'), findsNothing);
      expect(
        tester
            .widget<MessageComposer>(find.byType(MessageComposer))
            .maxAttachmentBytes,
        ChatAttachment.maxBytes,
      );
      await tester.pumpWidget(const SizedBox());
      history.dispose();
    },
  );

  testWidgets('ready direct link carries text and survives relay loss', (
    tester,
  ) async {
    final account = _ChunkedAccount()
      ..savedContacts.add(
        const ContactView(
          identityId: 'did:cht:peer',
          displayName: 'Alice',
          fingerprint: 'AA',
          verified: true,
          capabilities: ['files-v2'],
        ),
      );
    final factory = _QuietDirectFactory();
    final bridge = _FakeP2pBridge(authenticated: true);
    final history = PeerHistory();
    await tester.pumpWidget(
      MaterialApp(
        home: ConnectionPage(
          bridge: bridge,
          accountBridge: account,
          targetContactId: 'did:cht:peer',
          chatMode: true,
          peerHistory: history,
          directPeerFactory: factory,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(factory.peer, isNotNull);
    factory.peer!.onReadyChanged?.call(true);
    await tester.pump();
    expect(find.text('Direct · connected securely'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('peer-message-input')),
      'hello',
    );
    await tester.tap(find.byKey(const Key('send-peer-message')));
    await tester.pump();
    final message = history.messagesFor('did:cht:peer').single;
    expect(message.status, DeliveryStatus.sent);
    expect(factory.peer!.sent.single, contains('hello'));
    factory.peer!.onFrame?.call(
      jsonEncode({
        'v': 1,
        'type': 'receipt',
        'id': message.id,
        'receivedAt': 1234,
      }),
    );
    await tester.pump();
    expect(message.status, DeliveryStatus.delivered);
    bridge.authenticated = false;
    bridge.connectionState = 'closed';
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Direct · connected securely'), findsOneWidget);
    expect(find.byKey(const Key('peer-message-input')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    history.dispose();
  });
  for (final retry in [false, true]) {
    testWidgets(
      'switch contact during delayed ${retry ? 'retry read' : 'batch cache'} never sends to new peer',
      (tester) async {
        final cache = _DelayedCache();
        final history = PeerHistory(
          store: _MemoryHistoryStore(),
          attachments: cache,
        );
        await history.load('me');
        final file = ChatAttachment(
          name: 'private.txt',
          mimeType: 'text/plain',
          bytes: Uint8List(4),
        );
        if (retry) {
          await history.addAttachment(
            'did:cht:peer',
            PeerMessage(
              id: 'private',
              text: file.previewLabel,
              incoming: false,
              status: DeliveryStatus.failed,
              attachment: file,
            ),
          );
          cache.readGate = Completer<void>();
        } else {
          cache.writeGate = Completer<void>();
        }
        final bridge = _FakeP2pBridge(authenticated: true)
          ..autoAckAttachments = true;
        final account = _FakeAccountBridge()
          ..savedContacts.addAll([
            const ContactView(
              identityId: 'did:cht:peer',
              displayName: 'Alice',
              fingerprint: 'AA',
              verified: true,
            ),
            const ContactView(
              identityId: 'did:cht:bob',
              displayName: 'Bob',
              fingerprint: 'BB',
              verified: true,
            ),
          ]);
        Widget screen(String target) => MaterialApp(
          home: ConnectionPage(
            key: const ValueKey('same-session'),
            bridge: bridge,
            accountBridge: account,
            targetContactId: target,
            chatMode: true,
            peerHistory: history,
            pickAttachments: (_) async => [file],
          ),
        );
        await tester.pumpWidget(screen('did:cht:peer'));
        await tester.pump(const Duration(milliseconds: 500));
        if (retry) {
          await tester.tap(find.byTooltip('Retry'));
        } else {
          await tester.tap(find.byKey(const Key('attach-message')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Files'));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('send-peer-message')));
        }
        await tester.pump();
        await tester.pumpWidget(screen('did:cht:bob'));
        await tester.pump(const Duration(milliseconds: 500));
        if (retry) {
          cache.readGate!.complete();
        } else {
          cache.writeGate!.complete();
        }
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 500));
        }
        expect(bridge.sentPackets, isEmpty);
        expect(history.messagesFor('did:cht:bob'), isEmpty);
        expect(
          history.messagesFor('did:cht:peer').single.status,
          DeliveryStatus.failed,
        );
        await tester.pumpWidget(const SizedBox());
        history.dispose();
      },
    );
  }
  testWidgets('startup reuses an already running listener', (tester) async {
    final bridge = _FakeP2pBridge(listenerSupported: true)
      ..currentListener = const ListenerStatus(
        listening: true,
        peerId: 'running',
        addresses: [],
        discoveredNodes: [],
        pinRequired: false,
        relayEnabled: true,
      );
    await tester.pumpWidget(
      MaterialApp(
        home: ConnectionPage(
          bridge: bridge,
          accountBridge: _FakeAccountBridge(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(bridge.startCount, 0);
    expect(find.text('Listening'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('leaving the unlocked session cancels a pending relay startup', (
    tester,
  ) async {
    final bridge = _FakeP2pBridge(listenerSupported: true);
    final card = Completer<String>();
    final account = _FakeAccountBridge()..cardResponse = card.future;
    await tester.pumpWidget(
      MaterialApp(
        home: ConnectionPage(bridge: bridge, accountBridge: account),
      ),
    );
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    card.complete('signed-card');
    await tester.pump();
    expect(bridge.startCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Desktop automatically starts one relay and respects Stop listening',
    (tester) async {
      final bridge = _FakeP2pBridge(listenerSupported: true);
      await tester.pumpWidget(
        MaterialApp(
          home: ConnectionPage(
            bridge: bridge,
            accountBridge: _FakeAccountBridge(),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(bridge.startCount, 1);
      expect(bridge.listenerPin, '');
      expect(bridge.listenerAllowRelay, isTrue);
      expect(find.text('Listening'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('stop-listening')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('stop-listening')));
      await tester.pump(const Duration(seconds: 2));
      expect(bridge.currentListener.listening, isFalse);
      expect(bridge.startCount, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'phone retry shows failures and prevents overlapping connection attempts',
    (tester) async {
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = _FakeP2pBridge(automaticSupported: true)
        ..savedProfileName = 'Phone';
      bridge.onConnect = () async => throw StateError('companion unavailable');
      final account = _FakeAccountBridge()
        ..savedContacts.add(
          const ContactView(
            identityId: 'did:cht:peer',
            displayName: 'ton',
            fingerprint: 'AA11',
            verified: true,
          ),
        );
      await tester.pumpWidget(
        MaterialApp(
          home: ConnectionPage(
            bridge: bridge,
            accountBridge: account,
            targetContactId: 'did:cht:peer',
            chatMode: true,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(bridge.connectCount, 1);
      expect(find.byKey(const Key('connection-error')), findsOneWidget);
      final retry = Completer<void>();
      bridge.onConnect = () => retry.future;
      await tester.tap(find.byKey(const Key('connect-to-chat')));
      await tester.pump();
      expect(bridge.connectCount, 2);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('connect-to-chat')))
            .onPressed,
        isNull,
      );
      retry.completeError(StateError('still unavailable'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('connect-to-chat')))
            .onPressed,
        isNotNull,
      );
      expect(find.byKey(const Key('connection-error')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('inviter only shares a short room code', (tester) async {
    final bridge = _FakeP2pBridge();
    await tester.pumpWidget(
      MaterialApp(
        home: ConnectionPage(
          bridge: bridge,
          accountBridge: _FakeAccountBridge(),
        ),
      ),
    );

    await tester.enterText(find.byKey(const Key('profile-name')), 'Alice');
    await tester.tap(find.byKey(const Key('invite-friend')));
    await tester.pump();

    expect(bridge.offerStunUrl, defaultStunUrl);
    expect(bridge.offerDisplayName, 'Alice');
    expect(bridge.savedProfileName, 'Alice');
    expect(bridge.publishedOffer, 'offer-json');
    expect(find.text('1 2 3 4 5 6'), findsOne);
    expect(find.byKey(const Key('copy-room-code')), findsOne);
    expect(find.textContaining('offer'), findsNothing);
    expect(find.byKey(const Key('connection-code-input')), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('joiner enters room code and publishes reply automatically', (
    tester,
  ) async {
    final bridge = _FakeP2pBridge();
    final accountBridge = _FakeAccountBridge();
    await tester.pumpWidget(
      MaterialApp(
        home: ConnectionPage(bridge: bridge, accountBridge: accountBridge),
      ),
    );

    await tester.enterText(find.byKey(const Key('profile-name')), 'Bob');
    await tester.tap(find.byKey(const Key('join-invitation')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('room-code-input')), '123456');
    await tester.tap(find.byKey(const Key('join-room')));
    await tester.pump();

    expect(find.text('Verify Alice'), findsOne);
    expect(find.text('Claimed name: Alice'), findsOne);
    expect(find.text('AA11-BB22'), findsOne);
    await tester.tap(find.byKey(const Key('trust-peer-fingerprint')));
    await tester.pumpAndSettle();

    expect(bridge.loadedRoomCode, '123456');
    expect(bridge.acceptedSignal, _offer);
    expect(bridge.answerDisplayName, 'Bob');
    expect(bridge.savedProfileName, 'Bob');
    expect(bridge.publishedAnswer, 'answer-json');
    expect(accountBridge.addedCard, 'signed-card');
    expect(accountBridge.verifiedIdentityId, 'did:cht:peer');
    expect(find.text('Reply sent'), findsOne);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('connected peer uses the main chat layout and encrypted send', (
    tester,
  ) async {
    final bridge = _FakeP2pBridge(authenticated: true);
    final accountBridge = _FakeAccountBridge();
    accountBridge.savedContacts.add(
      const ContactView(
        identityId: 'did:cht:peer',
        displayName: 'Alice',
        signedName: 'Alice',
        fingerprint: 'AA11-BB22',
        verified: true,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ConnectionPage(
          bridge: bridge,
          accountBridge: accountBridge,
          targetContactId: 'did:cht:peer',
          chatMode: true,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byKey(const Key('secure-chat-shell')), findsOneWidget);
    expect(find.text('Alice'), findsWidgets);
    expect(find.text('Connected securely'), findsWidgets);
    expect(find.byKey(const Key('peer-message-input')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('peer-message-input')),
      'hello securely',
    );
    await tester.tap(find.byKey(const Key('send-peer-message')));
    await tester.pump();

    expect(bridge.sentText, 'hello securely');
    expect(find.text('hello securely'), findsWidgets);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Tooltip &&
            (widget.message?.startsWith('เวลาส่ง: ') ?? false),
      ),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Tooltip &&
            (widget.message?.startsWith('เวลารับ: ') ?? false),
      ),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.north_rounded), findsOneWidget);
    expect(find.byIcon(Icons.south_rounded), findsOneWidget);
    expect(find.textContaining('ส่ง:'), findsNothing);
    expect(find.textContaining('รับ:'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'incoming chunks are acknowledged, assembled once and persisted',
    (tester) async {
      final bytes = Uint8List.fromList(List.generate(8200, (i) => i % 251));
      final hash = sha256.convert(bytes).toString();
      PeerEvent packet(int index) {
        final start = index * AttachmentTransfer.chunkSize;
        final end = (start + AttachmentTransfer.chunkSize).clamp(
          0,
          bytes.length,
        );
        return PeerEvent(
          type: 'message',
          messageId: 'chtatt1_transfer_$index',
          sentAtMilliseconds: 1000,
          receivedAtMilliseconds: 2000 + index,
          text:
              AttachmentTransfer.marker +
              jsonEncode({
                'id': 'transfer',
                'i': index,
                'n': 2,
                'size': bytes.length,
                'name': 'notes.txt',
                'mime': 'text/plain',
                'sha256': hash,
                'data': base64Encode(bytes.sublist(start, end)),
              }),
        );
      }

      final store = _MemoryHistoryStore();
      final history = PeerHistory(store: store);
      await history.load('me');
      final bridge = _FakeP2pBridge(authenticated: true);
      final account = _FakeAccountBridge()
        ..savedContacts.add(
          const ContactView(
            identityId: 'did:cht:peer',
            displayName: 'Alice',
            fingerprint: 'AA11',
            verified: true,
          ),
        );
      await tester.pumpWidget(
        MaterialApp(
          home: ConnectionPage(
            bridge: bridge,
            accountBridge: account,
            targetContactId: 'did:cht:peer',
            chatMode: true,
            peerHistory: history,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      bridge.pendingEvents.add(packet(1));
      await tester.pump(const Duration(milliseconds: 500));
      expect(history.messagesFor('did:cht:peer'), isEmpty);
      expect(bridge.receipts, [('chtatt1_transfer_1', 2001)]);
      expect(find.textContaining(AttachmentTransfer.marker), findsNothing);
      bridge.pendingEvents.add(packet(0));
      await tester.pump(const Duration(milliseconds: 500));
      expect(bridge.receipts, [
        ('chtatt1_transfer_1', 2001),
        ('chtatt1_transfer_0', 2000),
      ]);
      expect(find.text('notes.txt'), findsOneWidget);
      expect(find.textContaining(AttachmentTransfer.marker), findsNothing);
      expect(
        history.messagesFor('did:cht:peer').single.attachment!.bytes,
        bytes,
      );
      bridge.pendingEvents.add(packet(0));
      await tester.pump(const Duration(milliseconds: 500));
      expect(bridge.receipts.last, ('chtatt1_transfer_0', 2000));
      expect(bridge.receipts.length, 3);
      expect(history.messagesFor('did:cht:peer'), hasLength(1));
      await history.flush();
      final reopened = PeerHistory(store: store);
      await reopened.load('me');
      final saved = reopened.messagesFor('did:cht:peer').single;
      expect(saved.attachment!.name, 'notes.txt');
      expect(saved.attachment!.bytes, bytes);
      reopened.dispose();
      await tester.pumpWidget(const SizedBox());
      history.dispose();
    },
  );
  testWidgets('outgoing picked file is sent as acknowledged chunks', (
    tester,
  ) async {
    final bytes = Uint8List.fromList(List.generate(8200, (i) => i % 251));
    final bridge = _FakeP2pBridge(authenticated: true)
      ..autoAckAttachments = true;
    final history = PeerHistory();
    final account = _FakeAccountBridge()
      ..savedContacts.add(
        const ContactView(
          identityId: 'did:cht:peer',
          displayName: 'Alice',
          fingerprint: 'AA11',
          verified: true,
        ),
      );
    await tester.pumpWidget(
      MaterialApp(
        home: ConnectionPage(
          bridge: bridge,
          accountBridge: account,
          targetContactId: 'did:cht:peer',
          chatMode: true,
          peerHistory: history,
          pickAttachments: (_) async => [
            ChatAttachment(
              name: 'out.txt',
              mimeType: 'text/plain',
              bytes: bytes,
            ),
          ],
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const Key('attach-message')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Files'));
    await tester.pumpAndSettle();
    expect(find.text('out.txt'), findsOneWidget);
    await tester.tap(find.byKey(const Key('send-peer-message')));
    await tester.pump();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(bridge.sentPackets, hasLength(2));
    expect(
      bridge.sentPackets.every(
        (packet) =>
            AttachmentTransfer.isPacketId(packet.$1) &&
            packet.$2.startsWith(AttachmentTransfer.marker),
      ),
      isTrue,
    );
    final message = history.messagesFor('did:cht:peer').single;
    expect(message.attachment!.bytes, bytes);
    expect(message.status, DeliveryStatus.delivered);
    expect(find.textContaining(AttachmentTransfer.marker), findsNothing);
    await tester.pumpWidget(const SizedBox());
    history.dispose();
  });
  testWidgets('desktop node starts a PIN-protected Rust listener', (
    tester,
  ) async {
    final bridge = _FakeP2pBridge(listenerSupported: true);
    await tester.pumpWidget(
      MaterialApp(
        home: ConnectionPage(
          bridge: bridge,
          autoStartListener: false,
          accountBridge: _FakeAccountBridge(),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Not listening'), findsOneWidget);
    await tester.tap(find.byKey(const Key('listener-use-pin')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('listener-pin')), '2468');
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pump();
    await tester.tap(find.byKey(const Key('start-listening')));
    await tester.pump();

    expect(bridge.listenerPin, '2468');
    expect(bridge.listenerAllowRelay, isFalse);
    expect(find.text('Listening'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('node-details')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('node-details')));
    await tester.pumpAndSettle();
    expect(find.text('PIN-protected mode'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('verified friend connects to the local Desktop automatically', (
    tester,
  ) async {
    final bridge = _FakeP2pBridge(automaticSupported: true)
      ..savedProfileName = 'Browser user';
    final accountBridge = _FakeAccountBridge();
    accountBridge.savedContacts.add(
      const ContactView(
        identityId: 'did:cht:peer',
        displayName: 'ton',
        signedName: 'ton',
        fingerprint: 'AA11-BB22',
        verified: true,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ConnectionPage(
          bridge: bridge,
          accountBridge: accountBridge,
          targetContactId: 'did:cht:peer',
          chatMode: true,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    expect(bridge.connectedIdentityId, 'did:cht:peer');
    expect(bridge.connectedDisplayName, 'Browser user');
    expect(find.byKey(const Key('invite-friend')), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'a frame error does not claim an authenticated socket was interrupted',
    (tester) async {
      final bridge = _FakeP2pBridge(authenticated: true)
        ..pendingEvents.add(
          const PeerEvent(type: 'failed', reason: 'stale encrypted frame'),
        );
      final accountBridge = _FakeAccountBridge();
      accountBridge.savedContacts.add(
        const ContactView(
          identityId: 'did:cht:peer',
          displayName: 'Alice',
          signedName: 'Alice',
          fingerprint: 'AA11-BB22',
          verified: true,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ConnectionPage(
            bridge: bridge,
            accountBridge: accountBridge,
            targetContactId: 'did:cht:peer',
            chatMode: true,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('Connected securely'), findsWidgets);
      expect(find.text('Connection interrupted. Try again.'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'reconnecting clears the old interruption without sending a message',
    (tester) async {
      final bridge = _FakeP2pBridge(authenticated: true);
      final account = _FakeAccountBridge()
        ..savedContacts.add(
          const ContactView(
            identityId: 'did:cht:peer',
            displayName: 'ton',
            fingerprint: 'AA11-BB22',
            verified: true,
          ),
        );
      await tester.pumpWidget(
        MaterialApp(
          home: ConnectionPage(
            bridge: bridge,
            accountBridge: account,
            targetContactId: 'did:cht:peer',
            chatMode: true,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Connected securely'), findsWidgets);

      bridge.authenticated = false;
      bridge.connectionState = 'closed';
      bridge.pendingEvents.add(
        const PeerEvent(type: 'connection', state: 'closed'),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const Key('peer-message-input')), findsNothing);

      bridge.authenticated = true;
      bridge.connectionState = 'connected';
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Connected securely'), findsWidgets);
      expect(find.text('Connection interrupted. Try again.'), findsNothing);
      expect(find.byKey(const Key('peer-message-input')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'an old close event does not override the current authenticated connection',
    (tester) async {
      final bridge = _FakeP2pBridge(authenticated: true)
        ..connectionState = 'connected'
        ..pendingEvents.add(
          const PeerEvent(type: 'connection', state: 'closed'),
        );
      final account = _FakeAccountBridge()
        ..savedContacts.add(
          const ContactView(
            identityId: 'did:cht:peer',
            displayName: 'ton',
            fingerprint: 'AA11-BB22',
            verified: true,
          ),
        );
      await tester.pumpWidget(
        MaterialApp(
          home: ConnectionPage(
            bridge: bridge,
            accountBridge: account,
            targetContactId: 'did:cht:peer',
            chatMode: true,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Connected securely'), findsWidgets);
      expect(find.text('Connection interrupted. Try again.'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

const _offer = '{"contactCard":"signed-card"}';

class _FakeAccountBridge implements AccountBridge {
  Future<String>? cardResponse;
  String? addedCard;
  String? verifiedIdentityId;
  final savedContacts = <ContactView>[];

  @override
  Future<ContactView> inspectContactCard(String cardJson) async =>
      const ContactView(
        identityId: 'did:cht:peer',
        displayName: 'Alice',
        fingerprint: 'AA11-BB22',
        verified: false,
      );

  @override
  Future<IdentityView> identity() async => const IdentityView(
    id: 'did:cht:local',
    rootPublicKey: 'local-root',
    noiseStaticPublicKey: 'local-noise',
    derivationVersion: 1,
  );

  @override
  Future<List<ContactView>> contacts() async => savedContacts;

  @override
  Future<List<ContactView>> addContact(
    String cardJson,
    String displayName,
  ) async {
    addedCard = cardJson;
    savedContacts.add(
      ContactView(
        identityId: 'did:cht:peer',
        displayName: displayName,
        fingerprint: 'AA11-BB22',
        verified: false,
      ),
    );
    return savedContacts;
  }

  @override
  Future<List<ContactView>> markContactVerified(String identityId) async {
    verifiedIdentityId = identityId;
    return savedContacts;
  }

  @override
  Future<List<ContactView>> setContactAlias(
    String identityId,
    String alias,
  ) async => savedContacts;

  @override
  Future<bool> hasIdentity() async => true;
  @override
  Future<CreatedIdentityView> createIdentity() => throw UnimplementedError();
  @override
  Future<void> discardPendingIdentity() async {}
  @override
  Future<IdentityView> confirmRecovery(String phrase) =>
      throw UnimplementedError();
  @override
  Future<IdentityView> restoreIdentity(String phrase) =>
      throw UnimplementedError();
  @override
  Future<String> contactCard({
    String displayName = '',
    String avatar = '',
  }) async => cardResponse ?? Future.value('signed-card');
  @override
  Future<List<ContactView>> removeContact(String identityId) async =>
      savedContacts;
  @override
  Future<String> preparePeer(String cardJson, bool initiator) =>
      throw UnimplementedError();
  @override
  Future<String> startPeerHandshake() => throw UnimplementedError();
  @override
  Future<Map<String, Object?>> receivePeerHandshake(String frame) =>
      throw UnimplementedError();
  @override
  Future<String> encryptPeerMessage(
    String messageId,
    String text, {
    int? sentAtMilliseconds,
  }) => throw UnimplementedError();
  @override
  Future<Map<String, Object?>> decryptPeerMessage(String frame) =>
      throw UnimplementedError();
}

class _FakeP2pBridge implements P2pBridge {
  _FakeP2pBridge({
    this.authenticated = false,
    this.listenerSupported = false,
    this.automaticSupported = false,
  });

  bool authenticated;
  String connectionState = 'new';
  final bool listenerSupported;
  final bool automaticSupported;
  String? offerStunUrl;
  String? offerDisplayName;
  String? publishedOffer;
  String? loadedRoomCode;
  String? acceptedSignal;
  String? answerStunUrl;
  String? answerDisplayName;
  String? publishedAnswer;
  String savedProfileName = '';
  String? sentText;
  String? listenerPin;
  bool? listenerAllowRelay;
  String? connectedIdentityId;
  String? connectedDisplayName;
  int startCount = 0;
  int connectCount = 0;
  Future<void> Function()? onConnect;
  final pendingEvents = <PeerEvent>[];
  final receipts = <(String, int)>[];
  final sentPackets = <(String, String)>[];
  final sentFilePackets = <(String, String)>[];
  bool autoAckAttachments = false;
  ListenerStatus currentListener = const ListenerStatus(
    listening: false,
    peerId: '',
    addresses: [],
    discoveredNodes: [],
    pinRequired: false,
    relayEnabled: false,
  );

  @override
  bool get supportsListening => listenerSupported;
  @override
  bool get supportsAutomaticContact => automaticSupported;

  @override
  Future<ListenerStatus> startListening(
    int port,
    String pin,
    bool allowRelay,
    String contactCard,
  ) async {
    startCount++;
    listenerPin = pin;
    listenerAllowRelay = allowRelay;
    currentListener = ListenerStatus(
      listening: true,
      peerId: 'peer-desktop',
      addresses: const ['/ip4/0.0.0.0/tcp/7358/p2p/peer-desktop'],
      discoveredNodes: const [],
      pinRequired: pin.isNotEmpty,
      relayEnabled: allowRelay && pin.isEmpty,
    );
    return currentListener;
  }

  @override
  Future<ListenerStatus> stopListening() async {
    currentListener = const ListenerStatus(
      listening: false,
      peerId: '',
      addresses: [],
      discoveredNodes: [],
      pinRequired: false,
      relayEnabled: false,
    );
    return currentListener;
  }

  @override
  Future<ListenerStatus> listenerStatus() async => currentListener;

  @override
  Future<void> updateListenerContactCard(String contactCard) async {}

  @override
  Future<String> createOffer(String stunUrl, String displayName) async {
    offerStunUrl = stunUrl;
    offerDisplayName = displayName;
    return 'offer-json';
  }

  @override
  Future<String> createRoom(String offer) async {
    publishedOffer = offer;
    return '123456';
  }

  @override
  Future<String> loadRoomOffer(String code) async {
    loadedRoomCode = code;
    return _offer;
  }

  @override
  Future<void> publishRoomAnswer(String code, String answer) async {
    publishedAnswer = answer;
  }

  @override
  Future<String?> loadRoomAnswer(String code) async => null;

  @override
  Future<String> acceptOffer(
    String signal,
    String stunUrl,
    String displayName,
  ) async {
    acceptedSignal = signal;
    answerStunUrl = stunUrl;
    answerDisplayName = displayName;
    return 'answer-json';
  }

  @override
  Future<void> acceptAnswer(String signal) async {}

  @override
  Future<Map<String, Object?>> status() async => {
    'connectionState': connectionState,
    'authenticated': authenticated,
  };

  @override
  Future<List<PeerEvent>> drainEvents() async {
    final events = List<PeerEvent>.of(pendingEvents);
    pendingEvents.clear();
    return events;
  }

  @override
  Future<void> sendMessage(
    String messageId,
    String text, {
    int? sentAtMilliseconds,
  }) async {
    sentText = text;
    if (messageId.startsWith('chtfile2_')) {
      sentFilePackets.add((messageId, text));
    }
    if (AttachmentTransfer.isPacketId(messageId)) {
      sentPackets.add((messageId, text));
      if (autoAckAttachments) {
        pendingEvents.add(
          PeerEvent(
            type: 'delivered',
            messageId: messageId,
            receivedAtMilliseconds: 5000,
          ),
        );
      }
    }
  }

  @override
  Future<void> acknowledgeMessage(
    String messageId,
    int receivedAtMilliseconds,
  ) async {
    receipts.add((messageId, receivedAtMilliseconds));
  }

  @override
  Future<String> profileName() async => savedProfileName;

  @override
  Future<void> setProfileName(String name) async {
    savedProfileName = name;
  }

  @override
  Future<void> close() async {}
  @override
  Future<void> connectContact(String identityId, String displayName) async {
    connectCount++;
    connectedIdentityId = identityId;
    connectedDisplayName = displayName;
    await onConnect?.call();
  }

  @override
  Future<void> sendTransportFrame(String frame) async {}
}

class _MemoryHistoryStore implements PeerHistoryStore {
  final values = <String, String>{};
  @override
  Future<String?> load(String ownerId) async => values[ownerId];
  @override
  Future<void> save(String ownerId, String source) async {
    values[ownerId] = source;
  }
}

class _GatedHistoryStore extends _MemoryHistoryStore {
  Completer<void>? gate;
  bool fail = false;
  @override
  Future<void> save(String ownerId, String source) async {
    await gate?.future;
    if (fail) throw StateError('Synthetic storage failure');
    await super.save(ownerId, source);
  }
}

class _DelayedCache implements AttachmentStore {
  Completer<void>? writeGate, readGate;
  final files = <String, ChatAttachment>{};
  @override
  Future<AttachmentRef> put(String ownerId, ChatAttachment file) async {
    await writeGate?.future;
    final digest = sha256.convert(file.bytes).toString();
    files[digest] = file;
    return AttachmentRef(
      name: file.name,
      mimeType: file.mimeType,
      size: file.bytes.length,
      digest: digest,
    );
  }

  @override
  Future<ChatAttachment> read(String ownerId, AttachmentRef ref) async {
    await readGate?.future;
    return files[ref.digest]!;
  }
}

class _TinySource implements AttachmentSource {
  int reads = 0;
  @override
  int get length => 6;
  @override
  String get key => 'synthetic-source';
  @override
  Stream<List<int>> openRead({int start = 0, int? end}) {
    reads++;
    return Stream.value([1, 2, 3, 4, 5, 6].sublist(start, end));
  }
}

class _ChunkedAccount extends _FakeAccountBridge
    implements ChunkedAttachmentBridge, AttachmentBridge {
  @override
  Future<void> savePeerAttachment(
    String ownerId,
    String digest,
    String data,
  ) async {}
  @override
  Future<String?> loadPeerAttachment(String ownerId, String digest) async =>
      null;
  String? owner, chunkId, digest;
  int? size, chunkSize;
  final chunks = <int, Uint8List>{};
  ChunkedAttachmentState get _state => ChunkedAttachmentState(
    id: chunkId!,
    size: size!,
    chunkSize: chunkSize!,
    contiguousChunks: chunks.length,
    completed: digest != null,
    digest: digest,
  );
  @override
  Future<ChunkedAttachmentState> beginChunkedAttachment(
    String ownerId,
    String id,
    int size,
    int chunkSize, {
    String? digest,
  }) async {
    owner = ownerId;
    chunkId = id;
    this.size = size;
    this.chunkSize = chunkSize;
    return _state;
  }

  @override
  Future<ChunkedAttachmentState> chunkedAttachmentStatus(
    String ownerId,
    String id,
  ) async {
    if (ownerId != owner || id != chunkId) throw StateError('wrong owner');
    return _state;
  }

  @override
  Future<void> writeChunkedAttachment(
    String ownerId,
    String id,
    int index,
    Uint8List bytes,
  ) async {
    await chunkedAttachmentStatus(ownerId, id);
    chunks[index] = bytes;
  }

  @override
  Future<Uint8List> readChunkedAttachment(
    String ownerId,
    String id,
    int index,
  ) async {
    await chunkedAttachmentStatus(ownerId, id);
    return chunks[index]!;
  }

  @override
  Future<ChunkedAttachmentState> finishChunkedAttachment(
    String ownerId,
    String id, {
    String? expectedDigest,
  }) async {
    await chunkedAttachmentStatus(ownerId, id);
    digest = expectedDigest;
    return _state;
  }

  @override
  Future<void> deleteChunkedAttachment(String ownerId, String id) async {
    await chunkedAttachmentStatus(ownerId, id);
    chunks.clear();
  }
}

class _SeedAccount extends _ChunkedAccount
    implements RelayCryptoBridge, SeedCryptoBridge {
  final crypto = seed_test.Crypto();
  @override
  Future<IdentityView> identity() async => const IdentityView(
    id: seed_test.owner,
    rootPublicKey: 'test',
    noiseStaticPublicKey: 'test',
    derivationVersion: 1,
  );
  @override
  Future<String> relayProof(String nonce, String relayId) =>
      crypto.relayProof(nonce, relayId);
  @override
  Future<String> inspectRelayRecord(String source, int now, bool loopback) =>
      crypto.inspectRelayRecord(source, now, loopback);
  @override
  Future<String> loadRelayState() async => '';
  @override
  Future<void> saveRelayState(String source) async {}
  @override
  Future<String> signSeedSignal(String peer, String id, String text, int now) =>
      crypto.signSeedSignal(peer, id, text, now);
  @override
  Future<String> inspectSeedSignal(String source, String peer, int now) =>
      crypto.inspectSeedSignal(source, peer, now);
}

class _QuietDirectFactory implements DirectPeerFactory {
  _QuietDirectPeer? peer;
  @override
  Future<DirectPeer> create() async => peer = _QuietDirectPeer();
}

class _QuietDirectPeer implements DirectPeer {
  final sent = <String>[];
  @override
  void Function(String, String?, int?)? onIceCandidate;
  @override
  void Function(String)? onFrame;
  @override
  void Function(bool)? onReadyChanged;
  @override
  Future<String> createOffer() async =>
      'v=0\na=fingerprint:sha-256 ${List.filled(32, 'AA').join(':')}\n';
  @override
  Future<String> createAnswer() => createOffer();
  @override
  Future<void> setRemoteDescription(String type, String sdp) async {}
  @override
  Future<void> addIceCandidate(
    String candidate,
    String? mid,
    int? line,
  ) async {}
  @override
  Future<void> send(String frame) async {
    sent.add(frame);
  }

  @override
  Future<void> close() async {}
}
