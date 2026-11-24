// Opt-in Windows proof: actual Rust FFI identities, encrypted disk storage,
// real local WebSocket relay, and the production invitation/message controllers.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cht/groups/group_blob_bridge.dart';
import 'package:cht/groups/group_controller.dart';
import 'package:cht/groups/group_crypto_bridge.dart';
import 'package:cht/groups/group_transport.dart';
import 'package:cht/relay/relay_crypto_bridge.dart';
import 'package:cht/relay/relay_network.dart';
import 'package:flutter_test/flutter_test.dart';

import 'group_transport_test.dart' show RegisteredSeed, FailingDirectFactory;
import 'swarm_test.dart' show Attachments;

class NativeWorker
    implements GroupCryptoBridge, GroupBlobBridge, RelayCryptoBridge {
  NativeWorker(this.process)
    : lines = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
  final Process process;
  final StreamIterator<String> lines;
  Future<void> _tail = Future.value();
  Future<Object?> call(String command, [Map<String, Object?> args = const {}]) {
    final work = _tail.then((_) async {
      process.stdin.writeln(jsonEncode({'command': command, 'args': args}));
      await process.stdin.flush();
      if (!await lines.moveNext().timeout(const Duration(seconds: 10))) {
        throw StateError('Synthetic native worker stopped');
      }
      final value = jsonDecode(lines.current) as Map;
      if (value['ok'] != true) throw StateError(value['error'] as String);
      return value['value'];
    });
    _tail = work.then<void>((_) {}).catchError((Object _) {});
    return work;
  }

  @override
  Future<Map<String, Object?>> groupCall(
    String operation,
    Map<String, Object?> args,
  ) async => Map<String, Object?>.from(
    await call('groupCall', {'operation': operation, 'args': args}) as Map,
  );
  @override
  Future<String?> loadGroupBlob(String owner, String key) async =>
      await call('loadGroupBlob', {'ownerId': owner, 'key': key}) as String?;
  @override
  Future<void> saveGroupBlob(String owner, String key, String value) async {
    await call('saveGroupBlob', {'ownerId': owner, 'key': key, 'value': value});
  }

  @override
  Future<void> deleteGroupBlob(String owner, String key) async {
    await call('deleteGroupBlob', {'ownerId': owner, 'key': key});
  }

  @override
  Future<String> relayProof(String nonce, String relayId) async =>
      await call('relayProof', {'nonce': nonce, 'relayId': relayId}) as String;
  @override
  Future<String> inspectRelayRecord(
    String source,
    int now,
    bool allowLoopback,
  ) async => await call('inspectRelayRecord', {
    'source': source,
    'now': now,
    'allowLoopback': allowLoopback,
  }) as String;
  @override
  Future<String> loadRelayState() async =>
      await call('loadRelayState') as String;
  @override
  Future<void> saveRelayState(String source) async {
    await call('saveRelayState', {'source': source});
  }

  Future<void> close() async {
    await _tail;
    await process.stdin.close();
    await process.exitCode.timeout(const Duration(seconds: 5));
    await lines.cancel();
  }
}

Future<void> until(
  bool Function() condition, {
  String Function()? describe,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail(describe?.call() ?? 'Timed out waiting for synthetic group state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

void main() {
  final dll = Platform.environment['CHTA_GROUP_CORE_DLL'],
      relayExe = Platform.environment['CHTA_GROUP_RELAY_EXE'];
  test(
    'native invitation accept and bidirectional group chat survive Direct failure',
    () async {
      final root = await Directory.systemTemp.createTemp('chta-group-qa-');
      final originalRoot = await root.resolveSymbolicLinks();
      final repo = Directory.current.parent.parent.path;
      final workers = <NativeWorker>[],
          networks = <RelayNetwork>[],
          controllers = <GroupController>[];
      Process? relay;
      try {
        final reservation = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final port = reservation.port;
        await reservation.close();
        final endpoint = 'ws://127.0.0.1:$port/cht';
        final config = File('${root.path}/relay.json');
        await config.writeAsString(
          jsonEncode({
            'listen_ip': '127.0.0.1',
            'port': port,
            'tcp_enabled': false,
            'state_dir': '${root.path}/relay-state',
            'websocket': {
              'listen': '127.0.0.1:$port',
              'public_url': endpoint,
              'bootstrap_urls': [],
              'max_clients': 16,
              'allow_loopback': true,
            },
          }),
        );
        relay = await Process.start(relayExe!, [
          '--config',
          config.path,
          '--windows-credential',
        ]);
        relay.stdout.drain<void>();
        relay.stderr.drain<void>();
        var listening = false;
        for (var n = 0; n < 200 && !listening; n++) {
          try {
            final socket = await Socket.connect(
              '127.0.0.1',
              port,
              timeout: const Duration(milliseconds: 100),
            );
            socket.destroy();
            listening = true;
          } catch (_) {
            await Future<void>.delayed(const Duration(milliseconds: 25));
          }
        }
        expect(listening, isTrue, reason: 'Synthetic relay must start');
        final identities = <String>[];
        for (final name in ['owner', 'friend']) {
          final folder = Directory('${root.path}/$name');
          await folder.create();
          final process = await Process.start(
            Platform.environment['PYTHON'] ?? 'python.exe',
            ['$repo/scripts/check_group_native.py', '--worker', dll!],
            environment: {'APPDATA': folder.path, 'LOCALAPPDATA': folder.path},
          );
          process.stderr.drain<void>();
          final worker = NativeWorker(process);
          workers.add(worker);
          final pending = await worker.call('createIdentity') as Map;
          final identity = await worker.call('confirmRecovery', {
            'phrase': pending['mnemonic'],
          }) as Map;
          identities.add(identity['id'] as String);
        }
        final cards = [
          for (final w in workers)
            await w.call('contactCard', {'displayName': 'Synthetic peer'}),
        ];
        for (var n = 0; n < 2; n++) {
          await workers[n].call('addContact', {
            'cardJson': cards[1 - n],
            'displayName': 'Synthetic peer',
          });
          await workers[n].call('markContactVerified', {
            'identityId': identities[1 - n],
          });
          final network = RelayNetwork(workers[n]);
          networks.add(network);
          await network.addSeed(endpoint);
          final controller = GroupController(
            ownerId: identities[n],
            crypto: workers[n],
            blobs: workers[n],
            attachments: Attachments(),
            displayName: () => n == 0 ? 'Owner' : 'Friend',
          );
          controllers.add(controller);
          await controller.initialize();
          await controller.attachTransport(
            GroupTransport(
              ownerId: identities[n],
              crypto: workers[n],
              network: network,
              signaling: RegisteredSeed(),
              peerFactory: FailingDirectFactory(),
            ),
          );
        }
        final gid = await controllers[0].createGroup('Synthetic group', [
          identities[1],
        ]);
        await until(() => controllers[1].invitations.isNotEmpty);
        await controllers[1].acceptInvitation(
          controllers[1].invitations.single.id,
        );
        await until(
          () => controllers.every((c) => c.group(gid)?.members.length == 2),
        );
        expect(
          await controllers[0].sendText(gid, 'synthetic owner message'),
          isTrue,
        );
        await until(
          () => controllers[1]
              .messagesFor(gid)
              .any((m) => m.text == 'synthetic owner message'),
        );
        expect(
          await controllers[1].sendText(gid, 'synthetic friend reply'),
          isTrue,
        );
        await until(
          () => controllers[0]
              .messagesFor(gid)
              .any((m) => m.text == 'synthetic friend reply'),
        );
        expect(controllers.every((c) => c.onlineCount(gid) == 1), isTrue);
        final longMarkdown = '# ข้อความยาว\n${'**เนื้อหา** 😀 \\\n' * 1200}';
        expect(await controllers[0].sendText(gid, longMarkdown), isTrue);
        final source = controllers[0]
            .messagesFor(gid)
            .singleWhere((m) => m.manifest != null)
            .manifest!;
        await until(
          () => controllers[1].progressFor(source.fileId)?.complete == true,
          describe: () => 'Long Markdown was not reconstructed via relay',
        );
        final received = controllers[1]
            .messagesFor(gid)
            .singleWhere((m) => m.manifest?.fileId == source.fileId);
        final document = await controllers[1].openFile(received.manifest!);
        expect(
          await utf8.decoder.bind(document.openRead()).join(),
          longMarkdown,
        );
        await until(
          () => controllers[0]
              .messagesFor(gid)
              .first
              .receipts
              .containsKey(identities[1]),
          describe: () => 'Initial recipient receipt stayed pending',
        );
        final original = controllers[0].messagesFor(gid).first;
        for (final c in controllers) {
          await c.flush();
          await c.close();
        }
        for (final n in networks) {
          await n.close();
        }
        controllers.clear();
        networks.clear();
        // Simulate a second installation with the roster but missing history.
        const index = 'groups-index-v1';
        final saved = jsonDecode(
          (await workers[1].loadGroupBlob(identities[1], index))!,
        ) as Map;
        saved['rooms'] = <String, Object?>{};
        saved['jobs'] = <String>[];
        await workers[1].saveGroupBlob(identities[1], index, jsonEncode(saved));
        final senderSaved = jsonDecode(
          (await workers[0].loadGroupBlob(identities[0], index))!,
        ) as Map;
        senderSaved['jobs'] = <String>[];
        await workers[0].saveGroupBlob(
          identities[0],
          index,
          jsonEncode(senderSaved),
        );
        for (var n = 0; n < 2; n++) {
          final network = RelayNetwork(workers[n]);
          networks.add(network);
          await network.addSeed(endpoint);
          final controller = GroupController(
            ownerId: identities[n],
            crypto: workers[n],
            blobs: workers[n],
            attachments: Attachments(),
            displayName: () => 'Synthetic member',
          );
          controllers.add(controller);
          await controller.initialize();
          controller.setCourierEnabled(true);
          await controller.attachTransport(
            GroupTransport(
              ownerId: identities[n],
              crypto: workers[n],
              network: network,
              signaling: RegisteredSeed(),
              peerFactory: FailingDirectFactory(),
            ),
          );
        }
        await until(
          () => controllers[1].messagesFor(gid).any((m) => m.id == original.id),
          describe: () =>
              'Missing history did not repair. Online ${controllers.map((c) => c.onlineCount(gid)).toList()}, capability ${controllers[0].supportsCourier(identities[1])}/${controllers[1].supportsCourier(identities[0])}, room counts ${controllers.map((c) => c.messagesFor(gid).length).toList()}',
        );
        final repaired = controllers[1]
            .messagesFor(gid)
            .singleWhere((m) => m.id == original.id);
        expect(repaired.repaired, isTrue);
        expect(repaired.sentAt, original.sentAt);
        expect(repaired.receivedAt, isNull);
      } finally {
        for (final c in controllers) {
          await c.close();
        }
        for (final n in networks) {
          await n.close();
        }
        for (final w in workers) {
          await w.close();
        }
        relay?.kill();
        if (relay != null) {
          await relay.exitCode.timeout(const Duration(seconds: 5));
        }
        // Only this test's own temporary directory, with no redirected root.
        if (await root.exists() &&
            await root.resolveSymbolicLinks() == originalRoot &&
            root.parent.absolute.path == Directory.systemTemp.absolute.path &&
            root.path.contains('chta-group-qa-')) {
          await root.delete(recursive: true);
        }
      }
    },
    skip: !Platform.isWindows || dll == null || relayExe == null
        ? 'Set CHTA_GROUP_CORE_DLL and CHTA_GROUP_RELAY_EXE for native proof'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
