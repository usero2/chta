// Opt in: flutter test test/relay/trycloudflare_integration_test.dart --dart-define=CHT_TEST_PUBLIC_RELAY=true
import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:cht/relay/relay_host_native.dart';
import 'package:cht/relay/relay_websocket_native.dart';

void main() {
  test(
    'Desktop creates a real TryCloudflare tunnel and stops its relay',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'cht-relay-integration-',
      );
      final binary = (await File(
        '../../target/relay-server/release/cht-relay.exe',
      ).copy('${directory.path}${Platform.pathSeparator}cht-relay.exe')).path;
      final host = WindowsRelayHost(
        binaryPath: binary,
        stateDirectory: directory.path,
        diagnostic: print,
      );
      WebSocket? socket;
      try {
        await host.start([]);
        expect(host.running, isTrue, reason: host.error);
        expect(host.endpoint, startsWith('wss://'));
        // DNS propagation may lag the cloudflared announcement briefly.
        Object? failure;
        for (var attempt = 0; attempt < 10; attempt++) {
          try {
            socket = await connectRelayWebSocket(host.endpoint!);
            break;
          } catch (error) {
            failure = error;
            await Future<void>.delayed(const Duration(seconds: 2));
          }
        }
        expect(socket, isNotNull, reason: '$failure');
        final frame = jsonDecode(
          await socket!.first.timeout(const Duration(seconds: 10)) as String,
        ) as Map;
        expect(frame['type'], 'challenge');
        expect((frame['relay'] as Map)['endpoint'], host.endpoint);
        expect((frame['relay'] as Map)['signature'], isNotEmpty);
        await host.stop();
        expect(host.enabled, isFalse);
        expect(host.running, isFalse);
        expect(host.endpoint, isNull);
      } finally {
        await socket?.close();
        await host.shutdown();
        await directory.delete(recursive: true);
      }
    },
    skip:
        !Platform.isWindows ||
        !const bool.fromEnvironment('CHT_TEST_PUBLIC_RELAY'),
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
