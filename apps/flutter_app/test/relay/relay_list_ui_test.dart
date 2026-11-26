import 'dart:async';
import 'dart:convert';

import 'package:cht/account/account_bridge.dart';
import 'package:cht/account/account_models.dart';
import 'package:cht/p2p/connection_page.dart';
import 'package:cht/p2p/p2p_bridge.dart';
import 'package:cht/relay/relay_crypto_bridge.dart';
import 'package:cht/relay/relay_socket.dart';
import 'package:cht/relay/relay_network.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final width in [320.0, 1440.0]) {
    testWidgets('Connect relay list uses available width at $width pixels', (
      tester,
    ) async {
      await _mount(tester, width: width);
      expect(find.text('Relays'), findsOneWidget);
      expect(find.text('Saved relays'), findsNothing);
      expect(find.text('Internet connections'), findsNothing);
      expect(find.text('0 online · 0 connecting · 1 saved'), findsOneWidget);
      final row = find.byKey(const ValueKey('relay-entry-$_endpoint'));
      await tester.ensureVisible(row);
      await tester.pump();
      expect(find.text(_endpoint), findsOneWidget);
      expect(find.text('Added'), findsOneWidget);
      expect(find.text('Updated'), findsOneWidget);
      expect(find.text('Last used'), findsOneWidget);
      expect(find.text('—'), findsNWidgets(3));
      expect(find.text('Unavailable'), findsOneWidget);
      expect(find.text('Reconnecting…'), findsNothing);
      expect(tester.getSize(row).width, greaterThan(width - 64));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  }

  testWidgets('relay timestamps render as local dates', (tester) async {
    final added = DateTime(2026, 11, 10, 8, 9, 10).millisecondsSinceEpoch;
    final updated = DateTime(2026, 11, 11, 9, 10, 11).millisecondsSinceEpoch;
    final used = DateTime(2026, 11, 12, 10, 11, 12).millisecondsSinceEpoch;
    await _mount(
      tester,
      width: 1440,
      activity: {
        _endpoint: {
          'addedAtMilliseconds': added,
          'updatedAtMilliseconds': updated,
          'lastUsedAtMilliseconds': used,
        },
      },
    );
    expect(find.text('2026-11-10 08:09:10'), findsOneWidget);
    expect(find.text('2026-11-11 09:10:11'), findsOneWidget);
    expect(find.text('2026-11-12 10:11:12'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('1000 relays initially render twenty and reveal twenty more', (
    tester,
  ) async {
    await _mount(tester, width: 1200, relayCount: 1000);
    expect(find.text('0 online · 0 connecting · 1000 saved'), findsOneWidget);
    expect(find.text('Show more (980 remaining)'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('relay-entry-wss://relay19.example.com/cht')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('relay-entry-wss://relay20.example.com/cht')),
      findsNothing,
    );
    final more = find.text('Show more (980 remaining)');
    await tester.ensureVisible(more);
    await tester.pumpAndSettle();
    await tester.tap(more);
    await tester.pump();
    expect(find.text('Show more (960 remaining)'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('relay-entry-wss://relay39.example.com/cht')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('relay-entry-wss://relay40.example.com/cht')),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('only a registered relay displays Online', (tester) async {
    await _mount(
      tester,
      width: 320,
      connector: (endpoint) async => _OnlineSocket(endpoint),
    );
    expect(find.text('1 online · 0 connecting · 1 saved'), findsOneWidget);
    expect(find.text('Online'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('relay row toggles the separate automatic removal lock', (
    tester,
  ) async {
    await _mount(tester, width: 320);
    final lock = find.byKey(const ValueKey('relay-lock-$_endpoint'));
    await tester.ensureVisible(lock);
    expect(tester.widget<IconButton>(lock).tooltip, 'Keep relay');
    await tester.tap(lock);
    await tester.pump();
    expect(tester.widget<IconButton>(lock).tooltip, 'Allow automatic removal');
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets(
    'pending connections and untested endpoints have distinct statuses',
    (tester) async {
      final connection = Completer<RelaySocket>();
      await _mount(
        tester,
        width: 1440,
        relayCount: 1000,
        connector: (_) => connection.future,
      );
      expect(find.text('Connecting'), findsWidgets);
      expect(find.text('Not connected'), findsWidgets);
      expect(find.text('Unavailable'), findsNothing);
      expect(find.text('Online'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      connection.completeError(StateError('fixture cancelled'));
      await tester.pump();
    },
  );
}

const _endpoint = 'wss://relay0.example.com/cht';

Future<void> _mount(
  WidgetTester tester, {
  required double width,
  int relayCount = 1,
  Map<String, dynamic>? activity,
  RelayConnector? connector,
}) async {
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final account = _Account()
    ..state = jsonEncode({
      'version': 1,
      'seeds': [],
      'relays': [
        for (var i = 0; i < relayCount; i++)
          {
            'relayId': 'relay$i',
            'endpoint': 'wss://relay$i.example.com/cht',
            'issuedAt': 1,
            'expiresAt': DateTime.now()
                .add(const Duration(days: 1))
                .millisecondsSinceEpoch,
            'signature': 'fixture',
          },
      ],
      'activity': ?activity,
    });
  await tester.pumpWidget(
    MaterialApp(
      home: ConnectionPage(
        accountBridge: account,
        bridge: _Bridge(),
        relayHostFactory: () => null,
        relayConnector:
            connector ?? (_) async => throw StateError('fixture unavailable'),
      ),
    ),
  );
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

class _Account implements AccountBridge, RelayCryptoBridge {
  String state = '';
  @override
  Future<String> loadRelayState() async => state;
  @override
  Future<void> saveRelayState(String source) async => state = source;
  @override
  Future<String> inspectRelayRecord(
    String source,
    int now,
    bool allowLoopback,
  ) async => source;
  @override
  Future<String> relayProof(String nonce, String relayId) async => '{}';
  @override
  Future<List<ContactView>> contacts() async => [];
  @override
  Future<IdentityView> identity() async => const IdentityView(
    id: 'fixture',
    rootPublicKey: '',
    noiseStaticPublicKey: '',
    derivationVersion: 1,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _Bridge implements P2pBridge {
  @override
  bool get supportsListening => false;
  @override
  bool get supportsAutomaticContact => true;
  @override
  Future<String> profileName() async => 'Fixture';
  @override
  Future<List<PeerEvent>> drainEvents() async => [];
  @override
  Future<Map<String, Object?>> status() async => {
    'connectionState': 'new',
    'authenticated': false,
  };
  @override
  Future<void> close() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _OnlineSocket implements RelaySocket {
  _OnlineSocket(String endpoint) {
    _frames.add(
      jsonEncode({
        'type': 'challenge',
        'nonce': 'fixture',
        'relay': {
          'relayId': 'relay0',
          'endpoint': endpoint,
          'issuedAt': 1,
          'expiresAt': DateTime.now()
              .add(const Duration(days: 1))
              .millisecondsSinceEpoch,
          'signature': 'fixture',
        },
        'relays': [],
      }),
    );
  }
  final _frames = StreamController<String>();
  @override
  Stream<String> get frames => _frames.stream;
  @override
  void send(String source) {
    if (jsonDecode(source)['type'] == 'register') {
      _frames.add(jsonEncode({'type': 'registered'}));
    }
  }

  @override
  Future<void> close() async {
    unawaited(_frames.close());
  }
}
