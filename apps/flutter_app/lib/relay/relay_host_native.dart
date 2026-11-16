import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'relay_host.dart';
import 'relay_executable.dart';
import 'windows_process_job.dart';
import 'relay_websocket_native.dart';

RelayHost? createHost() => Platform.isWindows ? WindowsRelayHost() : null;

class WindowsRelayHost extends RelayHost {
  WindowsRelayHost({
    this.binaryPath,
    this.stateDirectory,
    this.cloudflaredPath,
    this.diagnostic,
  });
  final String? binaryPath;
  final String? stateDirectory;
  final String? cloudflaredPath;
  final void Function(String)? diagnostic;
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
  Process? _tunnel;
  Process? _relay;
  Timer? _retry;
  int _generation = 0;
  int _attempt = 0;
  List<String> _bootstraps = [];
  bool _disposed = false;
  WindowsProcessJob? _job;
  final _subscriptions = <StreamSubscription<String>>[];

  @override
  Future<void> start(List<String> bootstrapUrls) async {
    enabled = true;
    _bootstraps = bootstrapUrls
        .where((url) => url.startsWith('wss://') && url != endpoint)
        .take(8)
        .toList();
    if (working || running) return;
    _retry?.cancel();
    final generation = ++_generation;
    working = true;
    error = null;
    notifyListeners();
    try {
      final binary = File(
        binaryPath ??
            '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}cht-relay.exe',
      );
      if (!await binary.exists()) {
        throw StateError('Relay missing. Reinstall the Desktop app.');
      }
      final reservation = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final port = reservation.port;
      await reservation.close();
      final host = Platform.environment['APPDATA'];
      if (host == null) {
        throw StateError('Windows application data directory is unavailable.');
      }
      final directory = Directory(
        stateDirectory ??
            '$host${Platform.pathSeparator}cht${Platform.pathSeparator}public-relay',
      );
      await directory.create(recursive: true);
      final tunnelConfig = File(
        '${directory.path}${Platform.pathSeparator}cloudflared.yml',
      );
      await tunnelConfig.writeAsString('{}\n', flush: true);
      final cloudflared = await findRelayTunnelExecutable(
        runtimeDirectory: binary.parent.path,
        overridePath: cloudflaredPath,
      );
      diagnostic?.call(
        cloudflared ==
                '${binary.parent.path}${Platform.pathSeparator}cloudflared.exe'
            ? 'Tunnel executable: bundled'
            : 'Tunnel executable: external',
      );
      if (generation != _generation) return;
      final tunnel = await Process.start(
        cloudflared,
        [
          'tunnel',
          '--config',
          tunnelConfig.path,
          '--no-autoupdate',
          '--protocol',
          'http2',
          '--url',
          'http://127.0.0.1:$port',
        ],
        environment: {
          'TUNNEL_TOKEN': '',
          'TUNNEL_TOKEN_FILE': '',
          'TUNNEL_CRED_FILE': '',
          'TUNNEL_ORIGIN_CERT': '',
        },
      );
      if (generation != _generation) {
        tunnel.kill();
        return;
      }
      _tunnel = tunnel;
      _job ??= WindowsProcessJob();
      _job!.add(tunnel.pid);
      final hostname = Completer<String>();
      void line(String text) {
        diagnostic?.call(text);
        final match = RegExp(r'https://([a-z0-9-]+\.trycloudflare\.com)')
            .firstMatch(text);
        if (match != null &&
            match[1] != 'api.trycloudflare.com' &&
            !hostname.isCompleted) {
          hostname.complete('wss://${match[1]}/cht');
        }
      }

      _subscriptions.add(
        tunnel.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(line),
      );
      _subscriptions.add(
        tunnel.stderr
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(line),
      );
      unawaited(
        tunnel.exitCode.then((_) {
          if (!hostname.isCompleted) {
            hostname.completeError(
              StateError(
                'Could not start TryCloudflare. Check your connection.',
              ),
            );
          }
          if (generation == _generation) {
            unawaited(
              _failed(
                generation,
                'The public tunnel stopped. Reconnecting automatically…',
              ),
            );
          }
        }),
      );
      final url = await hostname.future.timeout(const Duration(seconds: 45));
      if (generation != _generation) return;
      final config = File(
        '${directory.path}${Platform.pathSeparator}relay.json',
      );
      await config.writeAsString(
        jsonEncode({
          'tcp_enabled': false,
          'public_addresses': [],
          'state_dir': '${directory.path}${Platform.pathSeparator}data',
          'websocket': {
            'listen': '127.0.0.1:$port',
            'public_url': url,
            'bootstrap_urls': _bootstraps,
            'max_clients': 64,
          },
        }),
        flush: true,
      );
      final relay = await Process.start(binary.path, [
        '--config',
        config.path,
        '--windows-credential',
      ]);
      if (generation != _generation) {
        relay.kill();
        return;
      }
      _relay = relay;
      _job!.add(relay.pid);
      final listening = Completer<void>();
      String? expectedRelayId;
      _subscriptions.add(
        relay.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) {
              try {
                final event = jsonDecode(line) as Map;
                if (event['event'] == 'websocket_listening' &&
                    !listening.isCompleted) {
                  expectedRelayId = event['relay_id'] as String;
                  listening.complete();
                }
              } catch (_) {}
            }),
      );
      _subscriptions.add(
        relay.stderr
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) {
              try {
                final event = jsonDecode(line) as Map;
                if (event['event'] == 'error' && !listening.isCompleted) {
                  listening.completeError(StateError('${event['message']}'));
                }
              } catch (_) {}
            }),
      );
      unawaited(
        relay.exitCode.then((_) {
          if (!listening.isCompleted) {
            listening.completeError(StateError('The relay could not start.'));
          }
          if (generation == _generation) {
            unawaited(
              _failed(
                generation,
                'The relay stopped. Restarting automatically…',
              ),
            );
          }
        }),
      );
      await listening.future.timeout(const Duration(seconds: 20));
      if (generation != _generation) return;
      final deadline = DateTime.now().add(const Duration(seconds: 90));
      var reachable = false;
      while (DateTime.now().isBefore(deadline) && generation == _generation) {
        WebSocket? probe;
        try {
          probe = await connectRelayWebSocket(url);
          final challenge = jsonDecode(
            await probe.first.timeout(const Duration(seconds: 6)) as String,
          ) as Map;
          final record = challenge['relay'] as Map;
          if (challenge['type'] != 'challenge' ||
              record['endpoint'] != url ||
              record['relayId'] != expectedRelayId) {
            throw StateError('Public address reached a different relay');
          }
          reachable = true;
          break;
        } catch (caught) {
          diagnostic?.call('Public relay check: $caught');
          await Future<void>.delayed(const Duration(seconds: 2));
        } finally {
          try {
            await probe?.close().timeout(const Duration(seconds: 2));
          } catch (_) {}
        }
      }
      if (generation != _generation) return;
      if (!reachable) {
        throw StateError('Relay unreachable. Retrying…');
      }
      endpoint = url;
      running = true;
      working = false;
      _attempt = 0;
      notifyListeners();
    } catch (caught) {
      if (generation == _generation) await _failed(generation, '$caught');
    }
  }

  Future<void> _failed(int generation, String message) async {
    if (generation != _generation || _disposed) return;
    ++_generation;
    await _kill();
    running = false;
    working = false;
    error = message;
    endpoint = null;
    if (enabled) {
      final delay = min(60, 2 * (1 << min(_attempt++, 5)));
      _retry = Timer(
        Duration(seconds: delay),
        () => unawaited(start(_bootstraps)),
      );
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> _kill() async {
    _job?.close();
    _job = null;
    final processes = [_relay, _tunnel];
    _relay = null;
    _tunnel = null;
    for (final process in processes) {
      if (process != null) {
        process.kill();
        try {
          await process.exitCode.timeout(const Duration(seconds: 2));
        } catch (_) {}
      }
    }
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
  }

  @override
  Future<void> stop() async {
    enabled = false;
    _retry?.cancel();
    ++_generation;
    await _kill();
    running = false;
    working = false;
    endpoint = null;
    error = null;
    if (!_disposed) notifyListeners();
  }

  @override
  Future<void> shutdown() async {
    _disposed = true;
    await stop();
    dispose();
  }
}
