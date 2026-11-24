// Opt-in physical Android QA; control is USB loopback, payloads use public WSS.
import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cht/chat/attachment_transfer.dart';
import 'package:cht/chat/chat_attachment.dart';

import 'dart:io';

import 'package:cht/relay/default_relays.dart';
import 'package:cht/relay/relay_chat.dart';
import 'package:cht/relay/relay_network.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/native_account_worker.dart';
import '../groups/group_native_relay_test.dart' show until;

void main() {
  final env = Platform.environment;
  final dll = env['CHTA_GROUP_CORE_DLL'];
  final control = env['CHTA_ANDROID_QA_CONTROL_URL'];
  final token = env['CHTA_ANDROID_QA_TOKEN'];
  final adb = env['CHTA_QA_ADB'];
  final serial = env['CHTA_QA_DEVICE'];
  test(
    'real Android background delivery retains its session on Home and return',
    () async {
      final root = await Directory.systemTemp.createTemp('chta-background-qa-');
      final client = HttpClient();
      NativeAccountWorker? account;
      RelayChat? chat;
      AttachmentTransfer? transfer;
      Timer? receipts;
      Future<Map<String, dynamic>> api(String path, [Map? data]) async {
        final request = await client.openUrl(
          data == null ? 'GET' : 'POST',
          Uri.parse('$control$path'),
        );
        request.headers.set('authorization', 'Bearer $token');
        if (data != null) request.write(jsonEncode(data));
        final response = await request.close();
        final value = await utf8.decoder.bind(response).join();
        if (response.statusCode != 200) {
          throw StateError('QA API ${response.statusCode}');
        }
        return jsonDecode(value) as Map<String, dynamic>;
      }

      Future<void> device(List<String> args) async {
        final result = await Process.run(adb!, ['-s', serial!, ...args]);
        if (result.exitCode != 0) throw StateError('QA device command failed');
      }

      try {
        final process = await Process.start(
          env['PYTHON'] ?? 'python.exe',
          [
            '${Directory.current.parent.parent.path}/scripts/check_group_native.py',
            '--worker',
            dll!,
          ],
          environment: {'APPDATA': root.path, 'LOCALAPPDATA': root.path},
        );
        process.stderr.drain<void>();
        final native = account = NativeAccountWorker(process);
        final created = await native.call('createIdentity') as Map;
        await native.call('confirmRecovery', {'phrase': created['mnemonic']});
        final androidCard = (await api('/card'))['card'] as String;
        final androidId = (await native.inspectContactCard(androidCard))
            .identityId;
        await native.call('addContact', {
          'cardJson': androidCard,
          'displayName': 'Synthetic Android',
        });
        await native.call('markContactVerified', {'identityId': androidId});
        await api('/friend', {
          'card': await native.contactCard(displayName: 'Synthetic Desktop'),
        });
        final network = RelayNetwork(
          native,
          bootstrapRelays: defaultDataRelays,
        );
        await network.initialize();
        final sender = chat = RelayChat(
          native,
          network,
          ownCard: () => native.contactCard(displayName: 'Synthetic Desktop'),
        );
        sender.select(androidId);
        await until(() => sender.authenticated);
        final before = await api('/status');
        expect(before['running'], isTrue);
        await device(['shell', 'input', 'keyevent', 'KEYCODE_HOME']);
        await sender.sendMessage(
          'qa-background-1',
          'Synthetic background delivery',
          1000,
        );
        await until(
          () => sender.events.any(
            (e) => e.type == 'delivered' && e.messageId == 'qa-background-1',
          ),
        );
        final background = await api('/status');
        expect(background['received'], contains('qa-background-1'));
        expect(background['marker'], before['marker']);
        final bytes = Uint8List.fromList(List.generate(65536, (i) => i % 251));
        var progress = 0.0;
        final files = transfer = AttachmentTransfer(
          sendPacket: (id, text, time) => sender.sendMessage(id, text, time),
          onReceived: (_, _, _, _) {},
          onProgress: (_, value, incoming) {
            if (!incoming) progress = value;
          },
        );
        receipts = Timer.periodic(const Duration(milliseconds: 25), (_) {
          for (final event in sender.events) {
            if (event.type == 'delivered') {
              files.acknowledge(
                event.messageId!,
                receivedAtMilliseconds: event.receivedAtMilliseconds,
              );
            }
          }
        });
        expect(
          await files.send(
            'qa-background-file',
            ChatAttachment(
              name: 'synthetic.bin',
              mimeType: 'application/octet-stream',
              bytes: bytes,
            ),
            1500,
          ),
          isNotNull,
        );
        expect(progress, greaterThan(0));
        final receivedFiles = (await api('/status'))['files'] as List;
        expect(
          receivedFiles.single['sha256'],
          sha256.convert(bytes).toString(),
        );
        // Do not change global lifecycle settings or force-stop the owner's app.
        await device([
          'shell',
          'am',
          'start',
          '-n',
          'app.cht.cht.qa/app.cht.cht.MainActivity',
        ]);
        final returned = await api('/status');
        expect(returned['marker'], before['marker']);
        expect(returned['running'], isTrue);
        await sender.sendMessage(
          'qa-returned-2',
          'Synthetic resumed delivery',
          2000,
        );
        await until(
          () => sender.events.any(
            (e) => e.type == 'delivered' && e.messageId == 'qa-returned-2',
          ),
        );
        expect((await api('/lock'))['ok'], isTrue);
      } finally {
        receipts?.cancel();
        transfer?.dispose();
        client.close(force: true);
        await chat?.close();
        await account?.close();
        // Preserve disposable artifacts for debugging; no recursive workspace cleanup.
      }
    },
    skip:
        !Platform.isWindows ||
            [dll, control, token, adb, serial].any((v) => v == null)
        ? 'Set isolated Android QA control/native-core environment'
        : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
