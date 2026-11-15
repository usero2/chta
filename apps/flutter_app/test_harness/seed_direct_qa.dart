// Disposable two-browser QA. Only fresh synthetic identities are used.
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;
import 'package:cht/core/core_bridge.dart';
import 'package:cht/core/core_bridge_factory.dart';
import 'package:cht/relay/relay_crypto_bridge.dart';
import 'package:cht/relay/relay_network.dart';
import 'package:cht/relay/relay_socket.dart';
import 'package:cht/seed/seed_client.dart';
import 'package:cht/seed/seed_crypto_bridge.dart';
import 'package:cht/p2p/direct_file_link.dart';
import 'package:cht/chat/attachment_ref.dart';
import 'package:cht/chat/chunked_attachment_bridge.dart';
import 'package:cht/chat/chunked_file_cache.dart';
import 'package:cht/chat/resumable_attachment_transfer.dart';

import 'qa_result.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(
        body: Center(child: Text('Disposable signed seed / Direct QA')),
      ),
    ),
  );
  unawaited(run());
}

Future<Map<String, dynamic>> coordinate(
  String path, {
  Map<String, Object?>? body,
}) async {
  final headers = web.Headers()..set('content-type', 'application/json');
  final response = await web.window
      .fetch(
        path.toJS,
        web.RequestInit(
          method: body == null ? 'GET' : 'POST',
          headers: headers,
          body: body == null ? null : jsonEncode(body).toJS,
        ),
      )
      .toDart;
  if (!response.ok) throw StateError('QA coordinator failed');
  return jsonDecode((await response.text().toDart).toDart)
      as Map<String, dynamic>;
}

Future<void> until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 60),
}) async {
  final end = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(end)) throw StateError('QA timed out');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

class RecordingSocket implements RelaySocket {
  RecordingSocket(this.socket, this.record);
  final RelaySocket socket;
  final void Function(String) record;
  @override
  Stream<String> get frames => socket.frames;
  @override
  void send(String value) {
    record(value);
    socket.send(value);
  }

  @override
  Future<void> close() => socket.close();
}

Future<void> run() async {
  final role = Uri.base.queryParameters['role'];
  if (role != 'a' && role != 'b') {
    reportQa({'ok': false, 'error': 'Expected role a or b'});
    return;
  }
  const size = 26 * 1024 * 1024 + 123;
  const marker = 'QA-DIRECT-ONLY-CONTENT';
  final seedFrames = <String, int>{};
  var contentOnSeed = false,
      receivedText = false,
      receivedFile = false,
      signatures = 0;
  String? owner, sourceId, receivedId;
  SeedClient? seed;
  DirectFileLink? link;
  ResumableAttachmentTransfer? transfer;
  ChunkedAttachmentBridge? chunks;
  RelayNetwork? network;
  StreamSubscription<SeedVerifiedSignal>? signalSubscription;
  StreamSubscription<String>? dataSubscription;
  final watch = Stopwatch()..start();
  try {
    final core = createCoreBridge();
    if (core is InitializableCoreBridge) {
      await (core as InitializableCoreBridge).initializePlatform();
    }
    if (await core.hasIdentity()) {
      throw StateError('QA requires a fresh disposable browser profile');
    }
    final created = await core.createIdentity();
    owner = (await core.confirmRecovery(created.mnemonic)).id;
    await coordinate(
      '/qa/card',
      body: {
        'role': role,
        'card': await core.contactCard(displayName: 'Synthetic QA $role'),
      },
    );
    String? peerCard;
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    while (peerCard == null) {
      final state = await coordinate('/qa/peer?role=$role');
      peerCard = state['card'] as String?;
      if (peerCard == null) {
        if (DateTime.now().isAfter(deadline)) {
          throw StateError('Peer browser missing');
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    final inspected = await core.inspectContactCard(peerCard);
    await core.addContact(peerCard, 'Synthetic peer');
    await core.markContactVerified(inspected.identityId);
    final friend = (await core.contacts()).singleWhere(
      (entry) => entry.identityId == inspected.identityId,
    );
    final relayCrypto = core as RelayCryptoBridge;
    network = RelayNetwork(relayCrypto);
    seed = SeedClient(
      account: core,
      relayCrypto: relayCrypto,
      signalCrypto: core as SeedCryptoBridge,
      network: network,
      connector: (url) async => RecordingSocket(await openRelaySocket(url), (
        value,
      ) {
        final type = (jsonDecode(value) as Map)['type'] as String;
        seedFrames[type] = (seedFrames[type] ?? 0) + 1;
        contentOnSeed |=
            value.contains(marker) || value.contains('qa-seed-file-transfer');
      }),
    );
    final service = seed;
    link = DirectFileLink(ownIdentityId: owner, sendSignal: service.sendSignal);
    final direct = link;
    signalSubscription = service.signals.listen((signal) {
      signatures++;
      unawaited(direct.receiveSignal(signal.messageId, signal.text));
    });
    service.addListener(() => unawaited(direct.bind(friend.identityId,
      signalingAvailable: service.registered && service.selectedPeer == friend.identityId,
    ).catchError((Object _) { /* A transient attempt retries on the next signal. */ })));
    chunks = createChunkedAttachmentBridge(bridge: core);
    if (chunks == null) throw StateError('Missing encrypted chunk cache');
    final received = Completer<void>();
    transfer = ResumableAttachmentTransfer(
      ownerId: owner,
      peerId: friend.identityId,
      bridge: chunks,
      isDirect: () => direct.ready,
      sendPacket: (id, text) =>
          direct.send(jsonEncode({'kind': 'file', 'id': id, 'text': text})),
      onOffer: (id, ref, time) async {
        receivedId = ref.chunkedId;
      },
      onCompleted: (id, ref) async {
        receivedFile = true;
        if (!received.isCompleted) received.complete();
        return DateTime.now().millisecondsSinceEpoch;
      },
    );
    final protocol = transfer;
    dataSubscription = direct.frames.listen((frame) async {
      final packet = jsonDecode(frame) as Map<String, dynamic>;
      if (packet['kind'] == 'file') {
        await protocol.receive(
          packet['id'] as String,
          packet['text'] as String,
          direct: true,
        );
      } else if (packet['kind'] == 'text' && packet['text'] == marker) {
        receivedText = true;
        await direct.send(jsonEncode({'kind': 'textAck'}));
      } else if (packet['kind'] == 'textAck') {
        receivedText = true;
      }
    });
    await service.start(owner);
    service.selectContact(friend);
    reportQa({'phase': 'negotiating', 'role': role});
    await until(() => direct.ready);
    await coordinate('/qa/ready', body: {'role': role});
    var both = false;
    while (!both) {
      both = (await coordinate('/qa/ready'))['both'] == true;
      if (!both) await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await service.stop();
    await direct.bind(friend.identityId, signalingAvailable: false);
    await coordinate('/qa/stopped', body: {'role': role});
    both = false;
    while (!both) {
      both = (await coordinate('/qa/stopped'))['both'] == true;
      if (!both) await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!direct.ready) throw StateError('Direct link died with seed');
    reportQa({'phase': 'direct-without-seed', 'role': role});
    if (role == 'a') {
      await direct.send(jsonEncode({'kind': 'text', 'text': marker}));
      await until(() => receivedText);
      sourceId = 'qa-seed-source-cache-0001';
      Stream<List<int>> source() async* {
        for (var offset = 0; offset < size; offset += 65536) {
          final count = (size - offset).clamp(0, 65536);
          yield Uint8List.fromList(
            List.generate(count, (i) => (offset + i) % 251),
          );
        }
      }

      final stored = await ChunkedFileCache(chunks)
          .importStream(owner, sourceId, size, source());
      final ref = AttachmentRef(
        name: 'synthetic-seed-26MiB.bin',
        mimeType: 'application/octet-stream',
        size: size,
        digest: stored.digest!,
        chunkedId: sourceId,
        chunkSize: stored.chunkSize,
      );
      await protocol.send('qa-seed-file-transfer-0001', ref);
      receivedFile = true;
    } else {
      await received.future.timeout(const Duration(seconds: 90));
    }
    await until(() => receivedText && receivedFile);
    reportQa({
      'ok': true,
      'scenario': 'signed-seed-direct',
      'role': role,
      'bytes': size,
      'verifiedSignals': signatures,
      'directAfterSeedStopped': direct.ready,
      'contentOnSeed': contentOnSeed,
      'seedFrameTypes': seedFrames,
      'elapsedSeconds': watch.elapsedMilliseconds / 1000,
    });
    await coordinate('/qa/done', body: {'role': role});
    // Keep the Direct peer alive until both completion acknowledgements are sent.
    both = false;
    while (!both) {
      both = (await coordinate('/qa/done'))['both'] == true;
      if (!both) await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  } catch (error, stack) {
    reportQa({
      'ok': false,
      'role': role,
      'error': error.toString(),
      'stack': stack.toString(),
    });
  } finally {
    transfer?.dispose();
    await signalSubscription?.cancel();
    await dataSubscription?.cancel();
    await seed?.close();
    await link?.close();
    await network?.close();
    if (chunks != null && owner != null) {
      for (final id in [sourceId, receivedId]) {
        if (id != null) {
          try {
            await chunks.deleteChunkedAttachment(owner, id);
          } catch (_) {
            /* Disposable cache may be incomplete. */
          }
        }
      }
    }
  }
}
