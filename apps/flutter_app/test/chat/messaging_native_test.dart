import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cht/chat/attachment_ref.dart';
import 'package:cht/chat/attachment_store.dart';
import 'package:cht/chat/chat_attachment.dart';
import 'package:cht/chat/messaging_service.dart';
import 'package:cht/chat/peer_history.dart';
import 'package:cht/chat/peer_history_store.dart';
import 'package:cht/chat/room_history_store.dart';
import 'package:cht/relay/default_relays.dart';
import 'package:cht/relay/relay_network.dart';
import 'package:cht/relay/relay_socket.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/native_account_worker.dart';

class _History implements PeerHistoryStore {
  _History(this.account);
  final NativeAccountWorker account;
  @override
  Future<String?> load(String owner) =>
      account.loadGroupBlob(owner, 'qa-dm-history');
  @override
  Future<void> save(String owner, String source) =>
      account.saveGroupBlob(owner, 'qa-dm-history', source);
}

class _Attachments implements AttachmentStore {
  _Attachments(this.account);
  final NativeAccountWorker account;
  @override
  Future<AttachmentRef> put(String owner, ChatAttachment f) async {
    final digest = sha256.convert(f.bytes).toString();
    await account.saveGroupBlob(
      owner,
      'qa-file-$digest',
      base64Encode(f.bytes),
    );
    return AttachmentRef(
      name: f.name,
      mimeType: f.mimeType,
      size: f.size,
      digest: digest,
    );
  }

  @override
  Future<ChatAttachment> read(String owner, AttachmentRef ref) async =>
      ChatAttachment(
        name: ref.name,
        mimeType: ref.mimeType,
        bytes: base64Decode(
          (await account.loadGroupBlob(owner, 'qa-file-${ref.digest}'))!,
        ),
      );
}

class _DropRoutes implements RelaySocket {
  _DropRoutes(this.socket, this.dropping);
  final RelaySocket socket;
  final bool Function() dropping;
  @override
  Stream<String> get frames => socket.frames;
  @override
  void send(String frame) {
    if (dropping() && (jsonDecode(frame) as Map)['type'] == 'route') return;
    socket.send(frame);
  }

  @override
  Future<void> close() => socket.close();
}

Future<void> until(bool Function() condition) async {
  final end = DateTime.now().add(const Duration(seconds: 70));
  while (!condition()) {
    if (DateTime.now().isAfter(end)) {
      fail('Timed out waiting for production delivery');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  final dll = Platform.environment['CHTA_GROUP_CORE_DLL'];
  test(
    'production relays: native multi-peer, encrypted outbox restart, cached file and failover',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'chta-reliable-native-qa-',
      );
      final accounts = <NativeAccountWorker>[],
          services = <MessagingService>[],
          histories = <PeerHistory>[],
          networks = <RelayNetwork>[];
      final ids = <String>[], cards = <String>[], blocked = <String>{};
      var dropReceiptRoutes = false;
      Future<RelaySocket> connect(String url) =>
          defaultDataRelays.containsKey(url) && !blocked.contains(url)
          ? openRelaySocket(url)
          : Future.error(const SocketException('Synthetic route outage'));
      Future<void> start(int i) async {
        final account = accounts[i],
            history = PeerHistory(
              store: RoomHistoryStore(
                legacy: _History(account),
                blobs: account,
              ),
              attachments: _Attachments(account),
            );
        await history.load(ids[i]);
        histories.add(history);
        final network = RelayNetwork(
          account,
          connector: (url) async => _DropRoutes(
            await connect(url),
            () => i == 1 && dropReceiptRoutes,
          ),
          bootstrapRelays: defaultDataRelays,
        );
        networks.add(network);
        final service = MessagingService(
          ownerId: ids[i],
          account: account,
          network: network,
          history: history,
          ownCard: () async => cards[i],
        );
        services.add(service);
        await service.start();
      }

      try {
        for (var i = 0; i < 3; i++) {
          final dir = await Directory('${root.path}/$i').create();
          final p = await Process.start(
            Platform.environment['PYTHON'] ?? 'python.exe',
            [
              '${Directory.current.parent.parent.path}/scripts/check_group_native.py',
              '--worker',
              dll!,
            ],
            environment: {'APPDATA': dir.path, 'LOCALAPPDATA': dir.path},
          );
          p.stderr.drain<void>();
          final a = NativeAccountWorker(p);
          accounts.add(a);
          final pending = await a.call('createIdentity') as Map;
          ids.add(
            (await a.call('confirmRecovery', {'phrase': pending['mnemonic']})
                    as Map)['id']
                as String,
          );
          cards.add(await a.contactCard(displayName: 'Synthetic device $i'));
        }
        for (var i = 0; i < 3; i++) {
          for (var j = 0; j < 3; j++) {
            if (i != j) {
              await accounts[i].call('addContact', {
                'cardJson': cards[j],
                'displayName': 'Synthetic peer $j',
              });
              await accounts[i].call('markContactVerified', {
                'identityId': ids[j],
              });
            }
          }
        }
        // Queue before any network starts, then rebuild the service/history from
        // actual protected native storage. No synthetic plaintext outbox is used.
        final h = PeerHistory(store: _History(accounts[0]));
        await h.load(ids[0]);
        final pendingService = MessagingService(
          ownerId: ids[0],
          account: accounts[0],
          network: RelayNetwork(accounts[0], connector: connect),
          history: h,
          ownCard: () async => cards[0],
        );
        await pendingService.queueText(
          ids[1],
          'Synthetic restart payload',
          id: 'durable-restart',
        );
        await h.flush();
        await pendingService.close();
        h.dispose();
        for (var i = 0; i < 3; i++) {
          await start(i);
        }
        await until(() => services.every((s) => s.onlinePeers.length == 2));
        await until(
          () =>
              histories[0].messagesFor(ids[1]).single.status ==
              DeliveryStatus.delivered,
        );
        expect(histories[1].messagesFor(ids[0]).single.id, 'durable-restart');
        dropReceiptRoutes = true;
        await services[0].queueText(
          ids[1],
          'Synthetic missing receipt',
          id: 'lost-ack',
        );
        await until(
          () => histories[1].messagesFor(ids[0]).any((m) => m.id == 'lost-ack'),
        );
        final originalTime = histories[1]
            .messagesFor(ids[0])
            .singleWhere((m) => m.id == 'lost-ack')
            .receivedAtMilliseconds;
        await Future<void>.delayed(const Duration(seconds: 6));
        expect(
          histories[0]
              .messagesFor(ids[1])
              .singleWhere((m) => m.id == 'lost-ack')
              .status,
          isNot(DeliveryStatus.delivered),
        );
        dropReceiptRoutes = false;
        await until(
          () =>
              histories[0]
                  .messagesFor(ids[1])
                  .singleWhere((m) => m.id == 'lost-ack')
                  .status ==
              DeliveryStatus.delivered,
        );
        expect(
          histories[1].messagesFor(ids[0]).where((m) => m.id == 'lost-ack'),
          hasLength(1),
        );
        expect(
          histories[1]
              .messagesFor(ids[0])
              .singleWhere((m) => m.id == 'lost-ack')
              .receivedAtMilliseconds,
          originalTime,
        );
        for (var i = 1; i < 3; i++) {
          await services[i].queueText(
            ids[0],
            'Synthetic background peer $i',
            id: 'peer-$i',
          );
        }
        await until(
          () =>
              histories[0].messagesFor(ids[1]).any((m) => m.id == 'peer-1') &&
              histories[0].messagesFor(ids[2]).any((m) => m.id == 'peer-2'),
        );
        // Burst both directions while the account service, not a selected chat
        // screen, owns delivery. IDs/payloads/receipts must all remain distinct.
        for (var i = 0; i < 50; i++) {
          await services[0].queueText(
            ids[1],
            'Synthetic A $i',
            id: 'burst-a-$i',
          );
          await services[1].queueText(
            ids[0],
            'Synthetic B $i',
            id: 'burst-b-$i',
          );
        }
        await until(
          () =>
              histories[0]
                      .messagesFor(ids[1])
                      .where(
                        (m) =>
                            m.id.startsWith('burst-a-') &&
                            m.status == DeliveryStatus.delivered,
                      )
                      .length ==
                  50 &&
              histories[1]
                      .messagesFor(ids[0])
                      .where(
                        (m) =>
                            m.id.startsWith('burst-b-') &&
                            m.status == DeliveryStatus.delivered,
                      )
                      .length ==
                  50,
        );
        for (var i = 0; i < 50; i++) {
          expect(
            histories[1].messagesFor(ids[0]).where((m) => m.id == 'burst-a-$i'),
            hasLength(1),
          );
          expect(
            histories[0].messagesFor(ids[1]).where((m) => m.id == 'burst-b-$i'),
            hasLength(1),
          );
          expect(
            histories[1]
                .messagesFor(ids[0])
                .singleWhere((m) => m.id == 'burst-a-$i')
                .text,
            'Synthetic A $i',
          );
          expect(
            histories[0]
                .messagesFor(ids[1])
                .singleWhere((m) => m.id == 'burst-b-$i')
                .text,
            'Synthetic B $i',
          );
        }
        final file = ChatAttachment(
          name: 'synthetic.bin',
          mimeType: 'application/octet-stream',
          bytes: Uint8List.fromList(List.generate(65536, (i) => i % 251)),
        );
        await services[0].queueMessage(
          ids[2],
          PeerMessage(
            id: 'cached-file',
            text: file.previewLabel,
            incoming: false,
            status: DeliveryStatus.pending,
            attachment: file,
          ),
        );
        await until(
          () =>
              histories[2].fileOfferFor(
                ids[0],
                'cached-file',
                incoming: true,
              ) !=
              null,
        );
        await services[2].respondToFileOffer(
          ids[0],
          'cached-file',
          accept: true,
        );
        await until(
          () => histories[0]
              .messagesFor(ids[2])
              .any(
                (m) =>
                    m.id == 'cached-file' &&
                    m.status == DeliveryStatus.delivered,
              ),
        );
        final received = histories[2]
            .messagesFor(ids[0])
            .singleWhere((m) => m.id == 'cached-file');
        await until(
          () =>
              services[0].outgoingProgressFor(ids[2]).isEmpty &&
              services[2].incomingProgressFor(ids[0]).isEmpty,
        );
        expect(
          sha256.convert(
            (await histories[2].resolveAttachment(received)).bytes,
          ),
          sha256.convert(file.bytes),
        );
        final primary = networks[0].activeEndpoint!;
        blocked.add(primary);
        for (final network in networks) {
          await network.forget(primary);
        }
        await services[0].queueText(
          ids[1],
          'Synthetic automatic backup',
          id: 'after-failover',
        );
        await until(
          () => histories[0]
              .messagesFor(ids[1])
              .any(
                (m) =>
                    m.id == 'after-failover' &&
                    m.status == DeliveryStatus.delivered,
              ),
        );
        expect(networks[0].online, isNot(contains(primary)));
        expect(
          histories[1]
              .messagesFor(ids[0])
              .where((m) => m.id == 'durable-restart'),
          hasLength(1),
        );
      } finally {
        for (final s in services) {
          await s.close();
        }
        for (final h in histories) {
          h.dispose();
        }
        for (final a in accounts) {
          await a.close();
        }
        final resolved = await root.resolveSymbolicLinks();
        if (resolved.startsWith(Directory.systemTemp.path)) {
          await root.delete(recursive: true);
        }
      }
    },
    skip:
        dll == null || Platform.environment['CHTA_RUN_PUBLIC_MESSAGING'] != '1',
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
