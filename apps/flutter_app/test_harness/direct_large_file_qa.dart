// Disposable test entrypoint. Never launch with the production account directory.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:cht/core/core_bridge.dart';
import 'package:cht/core/core_bridge_factory.dart';
import 'package:cht/chat/chunked_attachment_bridge.dart';
import 'package:cht/chat/chunked_file_cache.dart';
import 'package:cht/chat/attachment_ref.dart';
import 'package:cht/chat/resumable_attachment_transfer.dart';
import 'package:cht/p2p/direct_file_link.dart';

import 'qa_result.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('cht disposable large-file QA'))),
    ),
  );
  unawaited(run());
}

Future<void> run() async {
  const size = 129 * 1024 * 1024 + 123;
  final watch = Stopwatch()..start();
  DirectFileLink? left, right;
  ResumableAttachmentTransfer? sender, receiver;
  ChunkedAttachmentBridge? bridge;
  String? owner, receivedId;
  const sourceId = 'qa-streamed-source-fixture-0001',
      wireId = 'qa-streamed-message-fixture-0001';
  var maximumSourceRead = 0,
      firstConfirmed = 0,
      offers = 0,
      deliberateDrop = false;
  reportQa({'phase': 'initializing'});
  try {
    final core = createCoreBridge();
    if (core is InitializableCoreBridge) {
      await (core as InitializableCoreBridge).initializePlatform();
    }
    if (await core.hasIdentity()) {
      throw StateError('QA requires a disposable empty account store');
    }
    final identity = await core.createIdentity();
    owner = (await core.confirmRecovery(identity.mnemonic)).id;
    bridge = createChunkedAttachmentBridge(bridge: core);
    if (bridge == null) throw StateError('Chunked cache unavailable');
    final cache = ChunkedFileCache(bridge);
    Stream<List<int>> source() async* {
      for (var offset = 0; offset < size; offset += 65536) {
        final length = (size - offset).clamp(0, 65536);
        if (length > maximumSourceRead) maximumSourceRead = length;
        yield Uint8List.fromList(
          List.generate(length, (index) => (offset + index) % 251),
        );
      }
    }

    reportQa({'phase': 'spooling', 'size': size});
    final state = await cache.importStream(owner, sourceId, size, source());
    final ref = AttachmentRef(
      name: 'synthetic-129MiB.bin',
      mimeType: 'application/octet-stream',
      size: size,
      digest: state.digest!,
      chunkedId: sourceId,
      chunkSize: state.chunkSize,
    );
    final a = 'did:cht:${'a' * 64}', b = 'did:cht:${'b' * 64}';
    Future<void> pair({required bool interrupt}) async {
      late DirectFileLink l, r;
      l = DirectFileLink(
        ownIdentityId: a,
        sendSignal: (id, text) => r.receiveSignal(id, text),
      );
      r = DirectFileLink(
        ownIdentityId: b,
        sendSignal: (id, text) => l.receiveSignal(id, text),
      );
      left = l;
      right = r;
      sender = ResumableAttachmentTransfer(
        ownerId: owner!,
        peerId: b,
        bridge: bridge!,
        isDirect: () => l.ready,
        sendPacket: (id, text) => l.send(jsonEncode({'id': id, 'text': text})),
        onOffer: (id, ref, time) async {},
        onCompleted: (id, ref) async => 1,
      );
      receiver = ResumableAttachmentTransfer(
        ownerId: owner,
        peerId: a,
        bridge: bridge,
        isDirect: () => r.ready,
        sendPacket: (id, text) => r.send(jsonEncode({'id': id, 'text': text})),
        onOffer: (id, ref, time) async {
          offers++;
          receivedId = ref.chunkedId;
        },
        onCompleted: (id, ref) async => DateTime.now().millisecondsSinceEpoch,
        onProgress: (id, value, incoming) {
          if (interrupt &&
              !deliberateDrop &&
              value.confirmedBytes >= 32 * 1024 * 1024) {
            deliberateDrop = true;
            firstConfirmed = value.confirmedBytes;
            sender!.disconnected();
            receiver!.disconnected();
            unawaited(l.bind(null, signalingAvailable: false));
            unawaited(r.bind(null, signalingAvailable: false));
          }
        },
      );
      l.frames.listen((frame) {
        final p = jsonDecode(frame) as Map;
        unawaited(
          sender!.receive(p['id'] as String, p['text'] as String, direct: true),
        );
      });
      r.frames.listen((frame) {
        final p = jsonDecode(frame) as Map;
        unawaited(
          receiver!.receive(
            p['id'] as String,
            p['text'] as String,
            direct: true,
          ),
        );
      });
      await r.bind(a, signalingAvailable: true);
      await l.bind(b, signalingAvailable: true);
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (!(l.ready && r.ready)) {
        if (DateTime.now().isAfter(deadline)) {
          throw StateError('Real WebRTC pair timed out');
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if (!interrupt) {
        await l.bind(b, signalingAvailable: false);
        await r.bind(a, signalingAvailable: false);
      }
    }

    reportQa({'phase': 'direct-first-pass', 'size': size});
    await pair(interrupt: true);
    try {
      await sender!.send(wireId, ref);
      throw StateError('Expected synthetic connection loss');
    } on TransferInterrupted {
      // The first pass deliberately disconnects after 32 MiB.
    }
    if (!deliberateDrop || receivedId == null) {
      throw StateError('Synthetic interruption was not reached');
    }
    await left!.close();
    await right!.close();
    sender!.dispose();
    receiver!.dispose();
    final partial = await bridge.chunkedAttachmentStatus(owner, receivedId!);
    if (partial.contiguousChunks < 128 || partial.completed) {
      throw StateError('Durable resume state invalid');
    }
    reportQa({
      'phase': 'resuming-without-signaling',
      'durableBlocks': partial.contiguousChunks,
      'size': size,
    });
    await pair(interrupt: false);
    await sender!.send(wireId, ref);
    final complete = await bridge.chunkedAttachmentStatus(owner, receivedId!);
    if (!complete.completed ||
        complete.digest != state.digest ||
        complete.size != size ||
        maximumSourceRead > 65536) {
      throw StateError('Final hash or streaming bound failed');
    }
    reportQa({
      'ok': true,
      'bytes': size,
      'digest': complete.digest,
      'sourceMaxRead': maximumSourceRead,
      'cacheBlockSize': state.chunkSize,
      'firstConfirmed': firstConfirmed,
      'resumeBlocks': partial.contiguousChunks,
      'offers': offers,
      'directAfterSignalingLoss': true,
      'elapsedSeconds': watch.elapsedMilliseconds / 1000,
    });
  } catch (error, stack) {
    reportQa({
      'ok': false,
      'error': error.toString(),
      'stack': stack.toString(),
      'elapsedSeconds': watch.elapsedMilliseconds / 1000,
    });
  } finally {
    sender?.dispose();
    receiver?.dispose();
    await left?.close();
    await right?.close();
    if (bridge != null && owner != null) {
      try {
        await bridge.deleteChunkedAttachment(owner, sourceId);
        if (receivedId != null) {
          await bridge.deleteChunkedAttachment(owner, receivedId!);
        }
      } catch (_) {}
    }
  }
}
