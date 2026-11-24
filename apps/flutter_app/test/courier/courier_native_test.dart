// Opt-in disposable identities/processes only. No owner profile or contact is used.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cht/chat/cache_policy.dart';
import 'package:cht/courier/courier_builder.dart';
import 'package:cht/courier/courier_receiver.dart';
import 'package:cht/chat/chat_attachment.dart';
import 'package:cht/chat/chunked_attachment_bridge.dart';
import 'package:cht/chat/chunked_file_cache.dart';
import 'package:cht/chat/managed_attachment_cache.dart';
import 'package:cht/chat/attachment_store.dart';
import 'package:cht/chat/peer_history.dart';
import 'package:cht/chat/room_history_store.dart';
import 'package:cht/delivery/delivery_envelope.dart';
import 'package:cht/delivery/courier_delivery_adapter.dart';
import 'package:cht/groups/group_controller.dart';
import 'package:cht/courier/courier_models.dart';
import 'package:cht/courier/courier_service.dart';

import '../delivery/peer_delivery_sink_test.dart' show MemoryHistory;
import '../groups/swarm_test.dart' show Attachments;

import 'package:cht/delivery/delivery_crypto_bridge.dart';
import 'package:cht/relay/relay_network.dart';
import 'package:flutter_test/flutter_test.dart';

import '../groups/group_native_relay_test.dart' show until;
import '../support/native_account_worker.dart';

class DeliveryWorker extends NativeAccountWorker
    implements DeliveryCryptoBridge, ChunkedAttachmentBridge {
  DeliveryWorker(super.process);
  @override
  Future<ChunkedAttachmentState> beginChunkedAttachment(
    String owner,
    String id,
    int size,
    int chunkSize, {
    String? digest,
  }) async => ChunkedAttachmentState.fromJson(
    Map<String, Object?>.from(
      await call('beginChunkedAttachment', {
        'ownerId': owner,
        'id': id,
        'size': size,
        'chunkSize': chunkSize,
        'digest': digest,
      }) as Map,
    ),
  );
  @override
  Future<ChunkedAttachmentState> chunkedAttachmentStatus(
    String owner,
    String id,
  ) async => ChunkedAttachmentState.fromJson(
    Map<String, Object?>.from(
      await call('chunkedAttachmentStatus', {'ownerId': owner, 'id': id})
          as Map,
    ),
  );
  @override
  Future<void> writeChunkedAttachment(
    String owner,
    String id,
    int index,
    Uint8List bytes,
  ) async {
    await call('writeChunkedAttachment', {
      'ownerId': owner,
      'id': id,
      'index': index,
      'data': base64Encode(bytes),
    });
  }

  @override
  Future<Uint8List> readChunkedAttachment(
    String owner,
    String id,
    int index,
  ) async => base64Decode(
    await call('readChunkedAttachment', {
      'ownerId': owner,
      'id': id,
      'index': index,
    }) as String,
  );
  @override
  Future<ChunkedAttachmentState> finishChunkedAttachment(
    String owner,
    String id, {
    String? expectedDigest,
  }) async => ChunkedAttachmentState.fromJson(
    Map<String, Object?>.from(
      await call('finishChunkedAttachment', {
        'ownerId': owner,
        'id': id,
        'expectedDigest': expectedDigest,
      }) as Map,
    ),
  );
  @override
  Future<void> deleteChunkedAttachment(String owner, String id) async {
    await call('deleteChunkedAttachment', {'ownerId': owner, 'id': id});
  }

  @override
  Future<Map<String, Object?>> deliveryCall(
    String operation,
    Map<String, Object?> args,
  ) async => Map<String, Object?>.from(
    await call('deliveryCall', {'operation': operation, 'args': args}) as Map,
  );
}

void main() {
  final dll = Platform.environment['CHTA_GROUP_CORE_DLL'],
      exe = Platform.environment['CHTA_GROUP_RELAY_EXE'];
  test(
    'real Rust keys, protected disk and relay move a split job via two strangers and return a recipient receipt after sender reconnects',
    () async {
      final root = await Directory.systemTemp.createTemp(
            'chta-courier-native-',
          ),
          resolved = await Directory.systemTemp.resolveSymbolicLinks();
      final workers = <DeliveryWorker>[],
          networks = <RelayNetwork>[],
          services = <CourierService>[],
          adapters = <CourierDeliveryAdapter>[],
          groups = <GroupController>[],
          budgets = <CachePolicy>[];
      Process? relay;
      try {
        final listener = await ServerSocket.bind(
              InternetAddress.loopbackIPv4,
              0,
            ),
            port = listener.port;
        await listener.close();
        final url = 'ws://127.0.0.1:$port/cht',
            config = File('${root.path}/relay.json');
        await config.writeAsString(
          jsonEncode({
            'listen_ip': '127.0.0.1',
            'port': port,
            'tcp_enabled': false,
            'state_dir': '${root.path}/relay',
            'websocket': {
              'listen': '127.0.0.1:$port',
              'public_url': url,
              'bootstrap_urls': [],
              'max_clients': 16,
              'allow_loopback': true,
              'bytes_per_minute': 67108864,
            },
          }),
        );
        relay = await Process.start(exe!, [
          '--config',
          config.path,
          '--windows-credential',
        ], mode: ProcessStartMode.normal);
        relay.stdout.drain<void>();
        relay.stderr.drain<void>();
        var listening = false;
        for (var i = 0; i < 200 && !listening; i++) {
          try {
            final s = await Socket.connect(
              '127.0.0.1',
              port,
              timeout: const Duration(milliseconds: 100),
            );
            s.destroy();
            listening = true;
          } catch (_) {
            await Future<void>.delayed(const Duration(milliseconds: 25));
          }
        }
        expect(listening, isTrue);
        final ids = <String>[], cards = <String>[];
        String? recipientPhrase;
        for (var i = 0; i < 4; i++) {
          final folder = await Directory('${root.path}/identity$i').create();
          final p = await Process.start(
            Platform.environment['PYTHON'] ?? 'python.exe',
            [
              '${Directory.current.parent.parent.path}/scripts/check_group_native.py',
              '--worker',
              dll!,
            ],
            environment: {'APPDATA': folder.path, 'LOCALAPPDATA': folder.path},
          );
          p.stderr.drain<void>();
          final w = DeliveryWorker(p);
          workers.add(w);
          final Map identity;
          if (i == 2) {
            identity = await w.call('restoreIdentity', {
              'phrase': recipientPhrase!,
            }) as Map;
          } else {
            final pending = await w.call('createIdentity') as Map;
            if (i == 1) recipientPhrase = pending['mnemonic'] as String;
            identity = await w.call('confirmRecovery', {
              'phrase': pending['mnemonic'],
            }) as Map;
          }
          ids.add(identity['id'] as String);
          cards.add(await w.contactCard(displayName: 'Synthetic Courier QA'));
        }
        for (var i = 0; i < 2; i++) {
          await workers[i].call('addContact', {
            'cardJson': cards[1 - i],
            'displayName': 'Synthetic peer',
          });
          await workers[i].call('markContactVerified', {
            'identityId': ids[1 - i],
          });
        }
        Future<CourierService> connect(int i) async {
          final network = RelayNetwork(workers[i]);
          networks.add(network);
          await network.initialize();
          await network.addSeed(url);
          await until(() => network.online.isNotEmpty);
          final budget = CachePolicy(
            ownerId: ids[i],
            settings: workers[i],
            availableSpace: () async => null,
          );
          budgets.add(budget);
          await budget.initialize();
          final service = CourierService(
            ownerId: ids[i],
            crypto: workers[i],
            storage: workers[i],
            budget: budget,
            network: network,
            canHost: i >= 2,
            allowLoopback: true,
          );
          services.add(service);
          await service.start();
          return service;
        }

        for (var i = 0; i < 4; i++) {
          await connect(i);
        }
        await services[0].refresh();
        await until(
          () =>
              services[0].directory.nodes
                  .where((n) => n.ownerId != ids[0])
                  .length ==
              2,
        );
        expect(await workers[2].contacts(), isEmpty);
        expect(await workers[3].contacts(), isEmpty);
        final now = DateTime.now().millisecondsSinceEpoch,
            id = '7' * 32,
            scope = directDeliveryScope(ids[0], ids[1]);
        final payload = Uint8List.fromList(
          List.generate(262145, (i) => i % 251),
        );
        final marker = utf8.encode('synthetic-courier-private-content');
        payload.setRange(0, marker.length, marker);
        final event = await DeliveryEnvelope.create(
          workers[0],
          scope: scope,
          messageId: 'native-courier-message',
          sentAt: now,
          kind: 'file',
          payload: {
            'text': '[file] synthetic.bin',
            'file': {
              'name': 'synthetic.bin',
              'mime': 'application/octet-stream',
              'size': payload.length,
              'digest': sha256.convert(payload).toString(),
            },
          },
        );
        final builder = CourierBuilder(
          jobs: services[0].jobs,
          crypto: workers[0],
          budget: budgets[0],
        );
        final job = await builder.prepare(
          id: id,
          peerId: ids[1],
          envelope: event,
          file: ChatAttachment.fromOwnedBytes(
            name: 'synthetic.bin',
            mimeType: 'application/octet-stream',
            bytes: payload,
          ),
        );
        expect(await services[0].deposit(id), job.packageCount);
        expect(services[0].jobs.find(id)!.status, CourierJobStatus.stored);
        await services[0].close();
        await networks[0]
            .close(); // Sender has no live route while the recipient collects.
        await services[1].refresh();
        await until(() => services[1].directory.nodes.length == 2);
        final nodes = services[1].directory.nodes, offers = <CourierOffer>[];
        for (final node in nodes) {
          final items = await services[1].pickup(
            node,
            bucket: job.mailboxBucket,
          );
          expect(items, hasLength(1));
          final bitmap = IndexBitmap.fromEncoded(
            job.packageCount,
            items.single['available'] as String,
          );
          expect(bitmap.length, lessThan(job.packageCount));
          offers.add(CourierOffer(node, items.single));
        }
        final historyStore = RoomHistoryStore(
          legacy: MemoryHistory(),
          blobs: workers[1],
        );
        final history = PeerHistory(
          store: historyStore,
          attachments: HybridAttachmentStore(
            Attachments(),
            ChunkedFileCache(workers[1]),
          ),
        );
        await history.load(ids[1]);
        final recipientContacts = await workers[1].contacts();
        final receiverAdapter = CourierDeliveryAdapter(
          service: services[1],
          history: history,
          contacts: () => recipientContacts,
          cache: BudgetedChunkCache(workers[1], budgets[1]),
        );
        adapters.add(receiverAdapter);
        await receiverAdapter.start();
        await until(
          () =>
              history.messagesFor(ids[0]).isNotEmpty &&
              receiverAdapter.activePickups == 0,
        );
        final receiver = receiverAdapter.receiver;
        final receipt = (await receiver.receive(offers))!;
        final received = (receipt['body'] as Map)['receivedAt'] as int;
        expect(await receiver.receive(offers), receipt);
        expect(history.messagesFor(ids[0]), hasLength(1));
        final message = history.messagesFor(ids[0]).single;
        expect(message.sentAtMilliseconds, now);
        expect(message.receivedAtMilliseconds, received);
        final file = await history.resolveAttachment(message);
        expect(
          (await sha256.bind(file.openRead()).first).toString(),
          sha256.convert(payload).toString(),
        );
        final restored = PeerHistory(
          store: RoomHistoryStore(legacy: MemoryHistory(), blobs: workers[1]),
        );
        await restored.load(ids[1]);
        expect(restored.messagesFor(ids[0]).single.deliveryEnvelope, isNotNull);
        restored.dispose();
        for (final node in nodes) {
          await services[1].depositReceipt(node, receipt);
        }
        final restarted = await connect(0);
        expect(restarted.jobs.find(id)!.status, CourierJobStatus.stored);
        await restarted.refresh();
        await until(() => restarted.directory.nodes.length == 2);
        for (final node in restarted.directory.nodes) {
          for (final proof in await restarted.receipts(
            node,
            received ~/ 86400000,
          )) {
            await restarted.jobs.recordReceipt(id, proof);
            await restarted.acknowledgeReceipt(
              node,
              proof,
              received ~/ 86400000,
            );
          }
        }
        expect(restarted.jobs.find(id)!.status, CourierJobStatus.delivered);
        expect(restarted.jobs.find(id)!.receivedAt, received);
        expect(restarted.jobs.find(id)!.sentAt, now);
        await receiverAdapter.close();
        history.dispose();
        // Deliver the cancellation over the real transport while the recipient
        // is offline. Its next mailbox scan must see no cancelled package.
        final cancelledId = '8' * 32;
        final cancelledEvent = await DeliveryEnvelope.create(
          workers[0],
          scope: scope,
          messageId: 'native-cancelled',
          sentAt: DateTime.now().millisecondsSinceEpoch,
          kind: 'text',
          payload: {'text': 'synthetic cancelled message'},
        );
        final cancelled = await CourierBuilder(
          jobs: restarted.jobs,
          crypto: workers[0],
          budget: restarted.budget,
        ).prepare(id: cancelledId, peerId: ids[1], envelope: cancelledEvent);
        expect(await restarted.deposit(cancelledId), cancelled.packageCount);
        await restarted.cancel(cancelledId);
        await until(
          () => restarted.jobs.find(cancelledId)?.nodeIds.isEmpty == true,
        );
        final afterCancel = await connect(1);
        await until(() => afterCancel.directory.nodes.length == 2);
        for (final node in afterCancel.directory.nodes) {
          final list = await afterCancel.pickup(
            node,
            bucket: cancelled.mailboxBucket,
          );
          expect(list.any((item) => item['jobId'] == cancelledId), isFalse);
        }
        await afterCancel.close();
        await networks.last.close();
        // Keep the original signed epoch and import received group files into
        // the existing swarm cache, without any live group transport.
        final created = await workers[0].groupCall('create', {
          'name': 'Synthetic offline group',
          'displayName': 'Sender',
          'now': DateTime.now().millisecondsSinceEpoch,
        });
        final gid =
            (jsonDecode(created['state'] as String) as Map)['groupId']
                as String;
        final invite = await workers[0].groupCall('invite', {
          'groupId': gid,
          'peerId': ids[1],
          'now': DateTime.now().millisecondsSinceEpoch,
        });
        final acceptance = await workers[1].groupCall('accept', {
          'invite': invite['invite'],
          'displayName': 'Recipient',
          'now': DateTime.now().millisecondsSinceEpoch,
        });
        final joined = await workers[0].groupCall('add', {
          'receipt': acceptance['receipt'],
          'now': DateTime.now().millisecondsSinceEpoch,
        });
        await workers[1].groupCall('apply', {'state': joined['state']});
        for (var i = 0; i < 2; i++) {
          final controller = GroupController(
            ownerId: ids[i],
            crypto: workers[i],
            blobs: workers[i],
            attachments: HybridAttachmentStore(
              Attachments(),
              ChunkedFileCache(workers[i]),
            ),
            displayName: () => 'Synthetic group peer',
          );
          await controller.initialize();
          groups.add(controller);
        }
        final senderHistory = PeerHistory(
          store: RoomHistoryStore(legacy: MemoryHistory(), blobs: workers[0]),
        );
        await senderHistory.load(ids[0]);
        final senderContacts = await workers[0].contacts();
        await workers[0].call('removeContact', {'identityId': ids[1]});
        await workers[1].call('removeContact', {'identityId': ids[0]});
        final groupSender = CourierDeliveryAdapter(
          service: restarted,
          history: senderHistory,
          contacts: () => senderContacts,
          cache: BudgetedChunkCache(workers[0], budgets[0]),
          automatic: false,
        );
        adapters.add(groupSender);
        await groupSender.start();
        groupSender.attachGroups(groups[0]);
        expect(
          await groups[0].sendText(gid, 'synthetic offline group text'),
          isTrue,
        );
        expect(
          await groups[0].sendBatch(gid, 'group caption', [
            ChatAttachment.fromOwnedBytes(
              name: 'synthetic-group.bin',
              mimeType: 'application/octet-stream',
              bytes: payload,
            ),
          ]),
          isTrue,
        );
        await groupSender.pump();
        await groupSender.settlePreparations();
        final groupJobs = restarted.jobs.jobs
            .where((j) => j.scope.startsWith('$gid:'))
            .toList();
        expect(groupJobs, hasLength(2));
        for (final job in groupJobs) {
          await restarted.deposit(job.id);
          expect(restarted.jobs.find(job.id)!.status, CourierJobStatus.stored);
        }
        await groupSender.close();
        final recipientService = await connect(1);
        final recipientHistory = PeerHistory(
          store: RoomHistoryStore(legacy: MemoryHistory(), blobs: workers[1]),
        );
        await recipientHistory.load(ids[1]);
        final groupReceiver = CourierDeliveryAdapter(
          service: recipientService,
          history: recipientHistory,
          contacts: () => [],
          cache: BudgetedChunkCache(workers[1], budgets[1]),
        );
        adapters.add(groupReceiver);
        groupReceiver.attachGroups(groups[1]);
        await groupReceiver.start();
        await until(
          () =>
              groups[1].messagesFor(gid).length == 2 &&
              groupReceiver.activePickups == 0,
        );
        final groupFile = groups[1]
            .messagesFor(gid)
            .singleWhere((m) => m.manifest != null);
        expect(
          (await sha256
                  .bind(
                    (await groups[1].openFile(groupFile.manifest!)).openRead(),
                  )
                  .first)
              .toString(),
          sha256.convert(payload).toString(),
        );
        expect(
          groups[1].messagesFor(gid).every((m) => m.deliveryEnvelope != null),
          isTrue,
        );
        await groupReceiver.close();
        final groupRestart = await connect(0),
            groupReceipts = CourierDeliveryAdapter(
              service: groupRestart,
              history: senderHistory,
              contacts: () => senderContacts,
              cache: BudgetedChunkCache(workers[0], budgets[0]),
            );
        adapters.add(groupReceipts);
        groupReceipts.attachGroups(groups[0]);
        await groupReceipts.start();
        await until(
          () => groups[0]
              .messagesFor(gid)
              .every((m) => m.receipts.containsKey(ids[1])),
        );
        for (final sent in groups[0].messagesFor(gid)) {
          expect(
            sent.receipts[ids[1]],
            groups[1]
                .messagesFor(gid)
                .singleWhere((m) => m.id == sent.id)
                .receivedAt,
          );
        }
        await groupReceipts.close();
        senderHistory.dispose();
        recipientHistory.dispose();
        for (var i = 2; i < 4; i++) {
          await for (final file in Directory(
            '${root.path}/identity$i',
          ).list(recursive: true)) {
            if (file is File && file.path.endsWith('.bin')) {
              final bytes = await file.readAsBytes();
              expect(
                latin1
                    .decode(bytes)
                    .contains('synthetic-courier-private-content'),
                isFalse,
              );
              expect(latin1.decode(bytes).contains('synthetic.bin'), isFalse);
            }
          }
        }
      } finally {
        for (final controller in groups) {
          await controller.close();
        }
        for (final adapter in adapters) {
          await adapter.close();
        }
        for (final s in services.reversed) {
          await s.close();
        }
        for (final n in networks.reversed) {
          await n.close();
        }
        for (final b in budgets) {
          b.dispose();
        }
        for (final w in workers) {
          await w.close();
        }
        relay?.kill();
        if (relay != null) {
          await relay.exitCode.timeout(const Duration(seconds: 5));
        }
        final target = await root.resolveSymbolicLinks();
        if (root.parent.path == Directory.systemTemp.path &&
            root.path.contains('chta-courier-native-') &&
            Directory(target).parent.path == resolved) {
          await root.delete(recursive: true);
        }
      }
    },
    skip: !Platform.isWindows || dll == null || exe == null
        ? 'Set disposable native core and relay executable'
        : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
