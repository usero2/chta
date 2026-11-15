import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cht/account/account_bridge.dart';
import 'package:cht/account/account_models.dart';
import 'package:cht/p2p/p2p_bridge.dart';
import 'package:cht/p2p/connection_page.dart';
import 'package:cht/relay/relay_crypto_bridge.dart';
import 'package:cht/relay/relay_host.dart';
import 'package:cht/relay/relay_qr.dart';
import 'package:cht/relay/relay_socket.dart';
import 'package:cht/relay/relay_network.dart';
import 'package:cht/account/contact_qr_files.dart';

class Account implements AccountBridge, RelayCryptoBridge {
  String saved = '';
  Future<String>? loadResponse;
  List<ContactView> friends = [];
  int inspections = 0;
  int imports = 0;
  int verifications = 0;
  String scannedIdentity = 'friend';
  @override
  Future<IdentityView> identity() async => const IdentityView(
    id: 'me',
    rootPublicKey: '',
    noiseStaticPublicKey: '',
    derivationVersion: 1,
  );
  @override
  Future<ContactView> inspectContactCard(String source) async {
    inspections++;
    if (source != '{"signed":"card"}') throw StateError('Invalid signature');
    return ContactView(
      identityId: scannedIdentity,
      displayName: 'Friend',
      fingerprint: 'ABCD',
      verified: false,
      relayUrls: ['wss://relay.example.com/cht'],
    );
  }

  @override
  Future<String> relayProof(String nonce, String relayId) async =>
      jsonEncode({'identityId': 'me'});
  @override
  Future<String> inspectRelayRecord(
    String source,
    int now,
    bool allowLoopback,
  ) async => source;
  @override
  Future<List<ContactView>> contacts() async => friends;
  @override
  Future<List<ContactView>> addContact(String card, String name) async {
    imports++;
    friends = [
      ContactView(
        identityId: scannedIdentity,
        displayName: name,
        fingerprint: 'ABCD',
        verified: false,
        relayUrls: const ['wss://relay.example.com/cht'],
      ),
    ];
    return friends;
  }

  @override
  Future<List<ContactView>> markContactVerified(String id) async {
    verifications++;
    friends = [
      for (final c in friends)
        ContactView(
          identityId: c.identityId,
          displayName: c.displayName,
          fingerprint: c.fingerprint,
          verified: true,
          relayUrls: c.relayUrls,
        ),
    ];
    return friends;
  }

  @override
  Future<String> loadRelayState() async => loadResponse ?? Future.value(saved);
  @override
  Future<void> saveRelayState(String source) async {
    saved = source;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Bridge implements P2pBridge {
  bool authenticated = false;
  int closes = 0;
  final sent = <(String, String)>[];
  final pending = <PeerEvent>[];
  @override
  bool get supportsListening => false;
  @override
  bool get supportsAutomaticContact => true;
  @override
  Future<String> profileName() async => 'Test profile';
  @override
  Future<List<PeerEvent>> drainEvents() async {
    final events = List<PeerEvent>.of(pending);
    pending.clear();
    return events;
  }

  @override
  Future<Map<String, Object?>> status() async => {
    'connectionState': 'new',
    'authenticated': authenticated,
  };
  @override
  Future<void> close() async {
    closes++;
  }

  @override
  Future<void> sendMessage(
    String id,
    String text, {
    int? sentAtMilliseconds,
  }) async {
    sent.add((id, text));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Host extends RelayHost {
  @override
  bool enabled = false;
  @override
  bool working = false;
  @override
  bool running = false;
  @override
  String? endpoint;
  @override
  String? error;
  int starts = 0;
  int stops = 0;
  @override
  Future<void> start(List<String> bootstrapUrls) async {
    starts++;
    enabled = true;
    running = true;
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    stops++;
    enabled = false;
    running = false;
    notifyListeners();
  }

  @override
  Future<void> shutdown() async {
    dispose();
  }
}

class OnlineSocket implements RelaySocket {
  OnlineSocket(String endpoint) {
    framesController.add(
      jsonEncode({
        'type': 'challenge',
        'nonce': 'test',
        'relay': {
          'relayId': 'relay-test',
          'endpoint': endpoint,
          'issuedAt': 1,
          'expiresAt': DateTime.now()
              .add(const Duration(hours: 1))
              .millisecondsSinceEpoch,
          'signature': 'test',
        },
        'relays': [],
      }),
    );
  }
  final framesController = StreamController<String>();
  @override
  Stream<String> get frames => framesController.stream;
  @override
  void send(String source) {
    if (jsonDecode(source)['type'] == 'register') {
      framesController.add(jsonEncode({'type': 'registered'}));
    }
  }

  @override
  Future<void> close() async {
    unawaited(framesController.close());
  }
}

class RelayOnlyBridge extends Bridge {
  @override
  bool get supportsAutomaticContact => false;
}

void main() {
  testWidgets(
    'relay startup completing after direct authentication preserves that session',
    (tester) async {
      final loading = Completer<String>();
      final account = Account()
        ..loadResponse = loading.future
        ..friends = [
          const ContactView(
            identityId: 'friend',
            displayName: 'Friend',
            fingerprint: 'ABCD',
            verified: true,
          ),
        ];
      final bridge = Bridge()..authenticated = true;
      await tester.pumpWidget(
        MaterialApp(
          home: ConnectionPage(
            accountBridge: account,
            bridge: bridge,
            targetContactId: 'friend',
            chatMode: true,
            relayHostFactory: () => null,
            relayConnector: (_) async => throw StateError('offline'),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      loading.complete(
        jsonEncode({
          'seeds': ['wss://loaded.example.com/cht'],
          'relays': [],
        }),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(bridge.closes, 0);
      expect(find.text('Connected securely'), findsWidgets);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
  testWidgets(
    'direct catalog sync requires capability and preserves the active chat',
    (tester) async {
      for (final capable in [false, true]) {
        final account = Account()
          ..friends = [
            ContactView(
              identityId: 'friend',
              displayName: 'Friend',
              fingerprint: 'ABCD',
              verified: true,
              capabilities: capable ? const ['relay-catalog-v1'] : const [],
            ),
          ];
        final bridge = Bridge()..authenticated = true;
        RelayNetwork? network;
        await tester.pumpWidget(
          MaterialApp(
            home: ConnectionPage(
              accountBridge: account,
              bridge: bridge,
              relayHostFactory: () => null,
              targetContactId: 'friend',
              chatMode: true,
              relayConnector: (_) async => throw StateError('offline'),
              onRelayNetworkReady: (value) => network = value,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump(const Duration(milliseconds: 600));
        expect(bridge.sent, hasLength(capable ? 1 : 0));
        if (capable) {
          network!.onFrame?.call('wss://peer.example.com/cht', {
            'from': 'friend',
            'session': 'a' * 32,
            'packet': 'b' * 32,
            'body': {'type': 'probe', 'contactCard': '{"signed":"card"}'},
          });
          await tester.pump(const Duration(milliseconds: 100));
          expect(account.inspections, 0);
          expect(bridge.sent.single.$1, startsWith('cht-control-relays-v1-'));
          bridge.pending.add(
            PeerEvent(
              type: 'message',
              messageId: 'cht-control-relays-v1-peer',
              text: jsonEncode({
                'protocol': 'cht-relays',
                'version': 1,
                'urls': ['wss://peer.example.com/cht'],
                'relays': [],
              }),
            ),
          );
          await tester.pump(const Duration(milliseconds: 500));
          expect(jsonDecode(account.saved)['seeds'], [
            'wss://peer.example.com/cht',
          ]);
          expect(bridge.closes, 0);
          expect(find.textContaining('cht-relays'), findsNothing);
          expect(find.text('Connected securely'), findsWidgets);
        }
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      }
    },
  );
  testWidgets(
    'a chat without relays offers scanning and resumes connection after import',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final account = Account()
        ..friends = [
          const ContactView(
            identityId: 'did:cht:friend',
            displayName: 'Friend',
            fingerprint: 'ABCD',
            verified: true,
          ),
        ];
      await tester.pumpWidget(
        MaterialApp(
          home: ConnectionPage(
            accountBridge: account,
            bridge: RelayOnlyBridge(),
            relayHostFactory: () => null,
            targetContactId: 'did:cht:friend',
            chatMode: true,
            relayConnector: (_) async => throw StateError('offline test'),
            scanRelayQr: () async => 'https://relay.example.com',
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      final scan = find.byKey(const Key('scan-relay-from-chat'));
      expect(scan, findsOneWidget);
      expect(find.byKey(const Key('connect-to-chat')), findsOneWidget);
      expect(
        tester.getTopLeft(scan).dy,
        tester.getTopLeft(find.byKey(const Key('connect-to-chat'))).dy,
      );
      await tester.tap(scan);
      await tester.pump(const Duration(milliseconds: 500));
      expect(jsonDecode(account.saved)['seeds'], [
        'wss://relay.example.com/cht',
      ]);
      expect(scan, findsOneWidget);
      expect(find.byKey(const Key('connect-to-chat')), findsOneWidget);
      expect(find.byKey(const Key('connection-error')), findsNothing);
      expect(find.text('Reconnecting. Keep both apps online.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
  testWidgets(
    'chat contact QR requires verification and rejects a different friend',
    (tester) async {
      for (final matching in [false, true]) {
        final account = Account()
          ..scannedIdentity = matching ? 'selected' : 'other'
          ..friends = [
            const ContactView(
              identityId: 'selected',
              displayName: 'Friend',
              fingerprint: 'ABCD',
              verified: false,
            ),
          ];
        await tester.pumpWidget(
          MaterialApp(
            home: ConnectionPage(
              accountBridge: account,
              bridge: RelayOnlyBridge(),
              relayHostFactory: () => null,
              targetContactId: 'selected',
              chatMode: true,
              relayConnector: (_) async => throw StateError('offline'),
              scanRelayQr: () async => '{"signed":"card"}',
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
        await tester.tap(find.byKey(const Key('scan-relay-from-chat')));
        await tester.pump(const Duration(milliseconds: 500));
        expect(account.verifications, 0);
        if (matching) {
          expect(
            find.byKey(const Key('trust-peer-fingerprint')),
            findsOneWidget,
          );
          await tester.tap(find.byKey(const Key('trust-peer-fingerprint')));
          await tester.pump(const Duration(milliseconds: 500));
          expect(account.verifications, 1);
          expect(jsonDecode(account.saved)['seeds'], [
            'wss://relay.example.com/cht',
          ]);
        } else {
          expect(find.byKey(const Key('trust-peer-fingerprint')), findsNothing);
          expect(account.imports, 0);
          expect(account.saved, isEmpty);
        }
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      }
    },
  );
  test('QR accepts a public URL or a verified signed card without trusting its owner', () async {
    final account = Account();
    expect(await relayRoutesFromQr('https://relay.example.com', account), [
      'wss://relay.example.com/cht',
    ]);
    expect(await relayRoutesFromQr('{"signed":"card"}', account), [
      'wss://relay.example.com/cht',
    ]);
    expect(account.inspections, 1);
    expect(account.friends, isEmpty);
    for (final invalid in [
      'not a relay',
      'ws://127.0.0.1:1234/cht',
      'wss://localhost/cht',
      'wss://relay.example.com/cht?secret=x',
      '{"forged":"card"}',
    ]) {
      await expectLater(
        relayRoutesFromQr(invalid, account),
        throwsA(anyOf(isA<FormatException>(), isA<StateError>())),
      );
    }
  });

  testWidgets(
    'scanning or importing a relay QR saves its route without manual paste',
    (tester) async {
      for (final image in [false, true]) {
        final account = Account();
        await tester.pumpWidget(
          MaterialApp(
            home: ConnectionPage(
              accountBridge: account,
              bridge: Bridge(),
              relayHostFactory: () => null,
              relayConnector: (_) async => throw StateError('offline test'),
              scanRelayQr: () async => 'https://relay.example.com',
              readRelayQrImage: () async => 'wss://relay.example.com/cht',
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        final scan = find.byKey(
          Key(image ? 'import-relay-qr' : 'scan-relay-qr'),
        );
        await tester.ensureVisible(scan);
        await tester.pumpAndSettle();
        await tester.tap(scan);
        await tester.pump(const Duration(milliseconds: 100));
        expect(jsonDecode(account.saved)['seeds'], [
          'wss://relay.example.com/cht',
        ]);
        expect(account.friends, isEmpty);
        expect(find.text('Relay added. Connecting…'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      }
    },
  );

  testWidgets('invalid or cancelled scans do not save a relay', (tester) async {
    for (final source in <String?>[null, 'not a relay']) {
      final account = Account();
      await tester.pumpWidget(
        MaterialApp(
          home: ConnectionPage(
            accountBridge: account,
            bridge: Bridge(),
            relayHostFactory: () => null,
            scanRelayQr: () async => source,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byKey(const Key('scan-relay-qr')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(account.saved, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }
  });

  testWidgets(
    'shared QR contains the current public URL and updates after a tunnel restart',
    (tester) async {
      final host = Host()
        ..enabled = true
        ..running = true
        ..endpoint = 'wss://first.example.com/cht';
      await tester.pumpWidget(
        MaterialApp(
          home: ConnectionPage(
            accountBridge: Account(),
            bridge: Bridge(),
            relayHostFactory: () => host,
            relayConnector: (_) async => throw StateError('offline test'),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('share-relay-qr')), findsNothing);
      expect(find.text('Share relay QR'), findsNothing);
      final qr = find.byKey(const Key('relay-share-qr'));
      expect(tester.widget<ContactQrView>(qr).card, host.endpoint);
      host.endpoint = 'wss://second.example.com/cht';
      host.notifyListeners();
      await tester.pump();
      expect(tester.widget<ContactQrView>(qr).card, host.endpoint);
      host.running = false;
      host.endpoint = null;
      host.notifyListeners();
      await tester.pump();
      expect(qr, findsNothing);
      expect(find.byKey(const Key('relay-copy-url')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets('inline relay QR copies URL and saves the current endpoint', (
    tester,
  ) async {
    var saved = 0;
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    const endpoint = 'wss://relay.example.com/cht';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RelayQrRow(
            endpoint: endpoint,
            onSave: () async {
              saved++;
            },
          ),
        ),
      ),
    );
    expect(
      tester
          .widget<ContactQrView>(find.byKey(const Key('relay-share-qr')))
          .card,
      endpoint,
    );
    await tester.tap(find.byKey(const Key('relay-copy-url')));
    await tester.pump();
    expect(copied, endpoint);
    await tester.tap(find.byKey(const Key('relay-save-qr')));
    await tester.pump();
    expect(saved, 1);
  });

  testWidgets('save failure displays a concise message', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RelayQrRow(
            endpoint: 'wss://relay.example.com/cht',
            onSave: () async => throw StateError('disk failure'),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('relay-save-qr')));
    await tester.pump();
    expect(find.text('Could not save QR.'), findsOneWidget);
  });
  testWidgets('inline relay QR fits 320 pixel screen', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RelayQrRow(
            endpoint: 'wss://a-very-long-relay-name.example.com/cht',
            onSave: () async {},
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('relay-share-qr')), findsOneWidget);
    expect(find.byKey(const Key('relay-copy-url')), findsOneWidget);
    expect(find.byKey(const Key('relay-save-qr')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('online non-host relay displays its shareable QR', (
    tester,
  ) async {
    const endpoint = 'wss://relay.example.com/cht';
    final account = Account()
      ..saved = jsonEncode({
        'version': 1,
        'seeds': [endpoint],
        'pins': {},
        'relays': [],
      });
    await tester.pumpWidget(
      MaterialApp(
        home: ConnectionPage(
          accountBridge: account,
          bridge: Bridge(),
          relayHostFactory: () => null,
          relayConnector: (url) async => OnlineSocket(url),
          scanRelayQr: () async => null,
        ),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final qr = find.byKey(const Key('relay-share-qr'));
    expect(qr, findsOneWidget);
    expect(tester.widget<ContactQrView>(qr).card, endpoint);
    expect(find.byKey(const Key('share-relay-qr')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
  testWidgets('relay target accepts 50–1000 and saves the value', (
    tester,
  ) async {
    final account = Account();
    await tester.pumpWidget(
      MaterialApp(
        home: ConnectionPage(
          accountBridge: account,
          bridge: Bridge(),
          relayHostFactory: () => null,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    final field = find.byKey(const Key('relay-connection-limit'));
    await tester.ensureVisible(field);
    await tester.enterText(field, '1000');
    final apply = find.byKey(const Key('apply-relay-limit'));
    await tester.ensureVisible(apply);
    await tester.tap(apply);
    await tester.pump(const Duration(milliseconds: 100));
    expect(jsonDecode(account.saved)['connectionLimit'], 1000);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
  testWidgets(
    'enabled public relay starts again when the unlocked app is reopened',
    (tester) async {
      final account = Account()
        ..saved = jsonEncode({
          'version': 1,
          'seeds': [],
          'pins': {},
          'relays': [],
          'hostEnabled': true,
        });
      final host = Host();
      await tester.pumpWidget(
        MaterialApp(
          home: ConnectionPage(
            accountBridge: account,
            bridge: Bridge(),
            relayHostFactory: () => host,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(host.starts, 1);
      expect(host.enabled, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
  testWidgets(
    'Desktop public relay switch starts/stops host and remembers the preference',
    (tester) async {
      final account = Account();
      final host = Host();
      await tester.pumpWidget(
        MaterialApp(
          home: ConnectionPage(
            accountBridge: account,
            bridge: Bridge(),
            relayHostFactory: () => host,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      final toggle = find.byKey(const Key('enable-public-relay'));
      expect(toggle, findsOneWidget);
      await tester.tap(toggle);
      await tester.pump(const Duration(milliseconds: 100));
      expect(host.starts, 1);
      expect(host.running, isTrue);
      expect(jsonDecode(account.saved)['hostEnabled'], isTrue);
      await tester.tap(toggle);
      await tester.pump(const Duration(milliseconds: 100));
      expect(host.stops, 1);
      expect(host.running, isFalse);
      expect(jsonDecode(account.saved)['hostEnabled'], isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}
