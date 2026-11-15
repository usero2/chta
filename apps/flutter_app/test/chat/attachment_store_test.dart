import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cht/chat/attachment_store.dart';
import 'package:cht/chat/attachment_ref.dart';
import 'package:cht/chat/chat_attachment.dart';
import 'package:cht/chat/peer_history.dart';
import 'package:cht/chat/peer_history_store.dart';
import 'package:flutter_test/flutter_test.dart';

final file = ChatAttachment(
  name: 'test.bin',
  mimeType: 'application/octet-stream',
  bytes: Uint8List.fromList([4, 7, 9]),
);
PeerMessage message(String id) => PeerMessage(
  id: id,
  text: file.previewLabel,
  incoming: true,
  status: DeliveryStatus.delivered,
  attachment: file,
);

void main() {
  test(
    'failed legacy migration cannot bypass owner switch or disposal',
    () async {
      final store = _History();
      store.values['alice'] = jsonEncode({
        'version': 2,
        'rooms': {
          'friend': [message('legacy-secret').toJson()],
        },
      });
      final history = PeerHistory(
        store: store,
        attachments: BridgeAttachmentStore(_Bridge()..fail = true),
      );
      await history.load('alice');
      final old = history.messagesFor('friend').single;
      expect((await history.resolveAttachment(old)).bytes, file.bytes);
      await history.load('bob');
      await expectLater(history.resolveAttachment(old), throwsStateError);
      history.dispose();
      await expectLater(history.resolveAttachment(old), throwsStateError);
    },
  );
  test('bounded thumbnails reuse encrypted cache after reopening and never block receipt', () async {
    final bridge = _Bridge(), store = _History();
    final history = PeerHistory(
      store: store,
      attachments: BridgeAttachmentStore(bridge),
    );
    await history.load('alice');
    await history.addAttachment('friend', message('video'));
    final saved = history.messagesFor('friend').single;
    var generated = 0;
    Future<Uint8List?> generate(ChatAttachment _) async {
      generated++;
      return Uint8List.fromList([1, 2, 3]);
    }

    expect(await history.thumbnailFor(saved, generate: generate), [1, 2, 3]);
    await history.flush();
    final reopened = PeerHistory(
      store: store,
      attachments: BridgeAttachmentStore(bridge),
    );
    await reopened.load('alice');
    expect(
      await reopened.thumbnailFor(
        reopened.messagesFor('friend').single,
        generate: generate,
      ),
      [1, 2, 3],
    );
    expect(generated, 1);
    expect(store.values['alice'], isNot(contains('"bytes"')));
    await reopened.addAttachment('friend', message('huge'));
    expect(
      await reopened.thumbnailFor(
        reopened.messagesFor('friend').last,
        generate: (_) async => Uint8List(262145),
      ),
      isNull,
    );
  });
  test(
    'batch caches every file before one history commit and retries safely',
    () async {
      final bridge = _Bridge()..failOnWrite = 2;
      final store = _History();
      final history = PeerHistory(
        store: store,
        attachments: BridgeAttachmentStore(bridge),
      );
      await history.load('alice');
      final messages = [message('first'), message('second')];
      await expectLater(
        history.addAttachments('friend', messages),
        throwsStateError,
      );
      expect(history.messagesFor('friend'), isEmpty);
      expect(store.values['alice'], isNull);
      bridge.failOnWrite = null;
      await history.addAttachments('friend', messages);
      await history.addAttachments('friend', messages);
      expect(history.messagesFor('friend').length, 2);
      expect(store.writes, 1);
      expect(store.values['alice'], isNot(contains('"bytes"')));
    },
  );
  test(
    'switching identities invalidates an in-flight read and old message',
    () async {
      final bridge = _Bridge();
      final history = PeerHistory(
        store: _History(),
        attachments: BridgeAttachmentStore(bridge),
      );
      await history.load('alice');
      await history.addAttachment('friend', message('private'));
      final old = history.messagesFor('friend').single;
      bridge.readGate = Completer<void>();
      final read = expectLater(
        history.resolveAttachment(old),
        throwsStateError,
      );
      await history.load('bob');
      bridge.readGate!.complete();
      await read;
      await expectLater(history.resolveAttachment(old), throwsStateError);
    },
  );
  test(
    'cache survives reopening, isolates owners and detects corruption',
    () async {
      final bridge = _Bridge();
      final first = BridgeAttachmentStore(bridge);
      final ref = await first.put('alice', file);
      final reopened = BridgeAttachmentStore(bridge);
      expect((await reopened.read('alice', ref)).bytes, file.bytes);
      await expectLater(reopened.read('bob', ref), throwsStateError);
      bridge.values['alice:${ref.digest}'] = base64Encode([0]);
      await expectLater(reopened.read('alice', ref), throwsFormatException);
      expect(
        () => AttachmentRef.fromJson({...ref.toJson(), 'digest': '../bad'}),
        throwsFormatException,
      );
    },
  );

  test('receipt saves references automatically and reopens offline', () async {
    final bridge = _Bridge();
    final store = _History();
    final cache = BridgeAttachmentStore(bridge);
    final history = PeerHistory(store: store, attachments: cache);
    await history.load('alice');
    await history.addAttachment('friend', message('one'));
    expect(store.values['alice'], isNot(contains('"bytes"')));
    expect(history.messagesFor('friend').single.attachment, isNull);
    final reopened = PeerHistory(store: store, attachments: cache);
    await reopened.load('alice');
    expect(
      (await reopened.resolveAttachment(reopened.messagesFor('friend').single))
          .bytes,
      file.bytes,
    );
  });

  test(
    'migration preserves embedded source until both writes succeed',
    () async {
      final store = _History();
      final legacy = jsonEncode({
        'version': 2,
        'rooms': {
          'friend': [message('old').toJson()],
        },
      });
      store.values['alice'] = legacy;
      final bridge = _Bridge()..fail = true;
      final history = PeerHistory(
        store: store,
        attachments: BridgeAttachmentStore(bridge),
      );
      await history.load('alice');
      expect(store.values['alice'], legacy);
      expect(history.messagesFor('friend').single.attachment, isNotNull);
      bridge.fail = false;
      store.fail = true;
      await history.load('alice');
      expect(store.values['alice'], legacy);
      expect(history.messagesFor('friend').single.attachment, isNotNull);
      store.fail = false;
      await history.load('alice');
      expect(store.values['alice'], isNot(contains('"bytes"')));
      expect(
        (await history.resolveAttachment(history.messagesFor('friend').single))
            .bytes,
        file.bytes,
      );
    },
  );

  test('failed durable receipt is retryable without duplicate entry', () async {
    final store = _History()..fail = true;
    final history = PeerHistory(
      store: store,
      attachments: BridgeAttachmentStore(_Bridge()),
    );
    await history.load('alice');
    await expectLater(
      history.addAttachment('friend', message('retry')),
      throwsStateError,
    );
    expect(history.messagesFor('friend'), isEmpty);
    store.fail = false;
    await history.addAttachment('friend', message('retry'));
    await history.addAttachment('friend', message('retry'));
    expect(history.messagesFor('friend').length, 1);
  });

  test(
    'identity switch during cache write never inserts into new identity',
    () async {
      final bridge = _Bridge()..gate = Completer<void>();
      final store = _History();
      final history = PeerHistory(
        store: store,
        attachments: BridgeAttachmentStore(bridge),
      );
      await history.load('alice');
      final pending = history.addAttachment('friend', message('switch'));
      final assertion = expectLater(pending, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      final switched = history.load('bob');
      bridge.gate!.complete();
      await assertion;
      await switched;
      expect(history.messagesFor('friend'), isEmpty);
      expect(store.values['bob'], isNull);
    },
  );
}

class _Bridge implements AttachmentBridge {
  final values = <String, String>{};
  bool fail = false;
  int? failOnWrite;
  int writes = 0;
  Completer<void>? gate;
  Completer<void>? readGate;
  @override
  Future<void> savePeerAttachment(
    String ownerId,
    String digest,
    String data,
  ) async {
    await gate?.future;
    if (fail || ++writes == failOnWrite) throw StateError('disk full');
    values['$ownerId:$digest'] = data;
  }

  @override
  Future<String?> loadPeerAttachment(String ownerId, String digest) async {
    await readGate?.future;
    return values['$ownerId:$digest'];
  }
}

class _History implements PeerHistoryStore {
  final values = <String, String>{};
  bool fail = false;
  int writes = 0;
  @override
  Future<String?> load(String ownerId) async => values[ownerId];
  @override
  Future<void> save(String ownerId, String source) async {
    if (fail) throw StateError('disk full');
    writes++;
    values[ownerId] = source;
  }
}
