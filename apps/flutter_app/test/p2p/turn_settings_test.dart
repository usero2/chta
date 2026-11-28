import 'dart:convert';

import 'package:cht/p2p/turn_settings.dart';
import 'package:cht/p2p/ice_route.dart';
import 'package:cht/p2p/turn_settings_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final token = 'a' * 64;
  final now = DateTime.utc(2026, 11, 27);
  final invite = 'https://turn.example.org/ice#$token';

  test('TURN invite keeps the token out of request URLs and reuses live credentials', () async {
    var requests = 0;
    final settings = TurnSettings(
      ownerId: 'owner',
      clock: () => now,
      client: MockClient((request) async {
        requests++;
        expect(request.url.toString(), 'https://turn.example.org/ice');
        expect(request.headers['authorization'], 'Bearer $token');
        expect(request.followRedirects, isFalse);
        return http.Response(
          jsonEncode({
            'version': 1,
            'urls': ['turn:turn.example.org:3478?transport=udp'],
            'username': 'temporary-user',
            'credential': 'temporary-credential',
            'ttl': 3600,
          }),
          200,
        );
      }),
    );
    addTearDown(settings.dispose);
    await settings.install(invite);
    expect(settings.host, 'turn.example.org');
    expect((await settings.iceServers()).single['username'], 'temporary-user');
    expect(requests, 1);
    await settings.remove();
    expect(await settings.iceServers(), isEmpty);
  });

  test('rejects unsafe and mismatched TURN links before enabling', () async {
    for (final url in [
      'http://turn.example.org/ice#$token',
      'https://localhost/ice#$token',
      'https://127.0.0.1/ice#$token',
      'https://user@turn.example.org/ice#$token',
      'https://turn.example.org/ice?token=bad#$token',
      'https://turn.example.org/ice#short',
    ]) {
      expect(() => TurnInvite.parse(url), throwsFormatException);
    }
    final settings = TurnSettings(
      ownerId: 'owner',
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'version': 1,
            'urls': ['turn:unrelated.example.net:3478?transport=udp'],
            'username': 'user',
            'credential': 'pass',
            'ttl': 3600,
          }),
          200,
        ),
      ),
    );
    addTearDown(settings.dispose);
    await expectLater(settings.install(invite), throwsFormatException);
    expect(settings.host, isNull);
  });

  test(
    'only the selected candidate pair can identify a TURN or direct path',
    () {
      final reports = <String, Map<Object?, Object?>>{
        'transport': {'type': 'transport', 'selectedCandidatePairId': 'pair'},
        'pair': {
          'type': 'candidate-pair',
          'localCandidateId': 'local',
          'remoteCandidateId': 'remote',
        },
        'local': {'candidateType': 'host'},
        'remote': {'candidateType': 'relay'},
        'unused': {'candidateType': 'srflx'},
      };
      expect(selectedIceRoute(reports), IceRoute.turn);
      reports['remote']!['candidateType'] = 'srflx';
      expect(selectedIceRoute(reports), IceRoute.direct);
      reports.remove('remote');
      expect(selectedIceRoute(reports), IceRoute.unknown);
      expect(
        validTurnCandidate('candidate:a 1 udp 1 93.184.216.34 49160 typ relay'),
        isTrue,
      );
      expect(
        validTurnCandidate(
          'candidate:a 1 udp 1 169.254.169.254 49160 typ relay',
        ),
        isFalse,
      );
    },
  );

  testWidgets(
    'saved TURN link shows the hostname without exposing the access token',
    (tester) async {
      final settings = TurnSettings(
        ownerId: 'owner',
        client: MockClient.streaming(
          (_, _) async => http.StreamedResponse(
            Stream.value(
              utf8.encode(
                jsonEncode({
                  'version': 1,
                  'urls': ['turn:turn.example.org:3478?transport=tcp'],
                  'username': 'user',
                  'credential': 'pass',
                  'ttl': 3600,
                }),
              ),
            ),
            200,
          ),
        ),
      );
      addTearDown(settings.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TurnSettingsTile(settings: settings)),
        ),
      );
      await tester.tap(find.byKey(const Key('turn-settings')));
      await tester.pumpAndSettle();
      final input = find.byKey(const Key('turn-invite'));
      expect(tester.widget<TextField>(input).obscureText, isTrue);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.runAsync(() => settings.install(invite));
      await tester.pumpAndSettle();
      expect(find.text('turn.example.org'), findsOneWidget);
      expect(find.text(invite), findsNothing);
    },
  );
}
