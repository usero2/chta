import 'dart:async';
import 'dart:convert';

import 'package:cht/chat/attachment_ref.dart';
import 'package:cht/chat/peer_history.dart';
import 'package:cht/chat/peer_history_store.dart';
import 'package:cht/notifications/incoming_notifications.dart';
import 'package:cht/notifications/peer_history_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

import 'incoming_notifications_test.dart' show RecordingBackend;

class MemoryHistoryStore implements PeerHistoryStore {
  String? source;
  bool fail = false;
  Completer<void>? barrier;
  @override
  Future<String?> load(String ownerId) async => source;
  @override
  Future<void> save(String ownerId, String value) async {
    await barrier?.future;
    if (fail) throw StateError('Disk full');
    source = value;
  }
}

PeerMessage message(
  String id, {
  bool incoming = true,
  DeliveryStatus status = DeliveryStatus.delivered,
  AttachmentRef? attachmentRef,
}) => PeerMessage(
  id: id,
  text: 'secret text',
  incoming: incoming,
  status: status,
  attachmentRef: attachmentRef,
);

void main() {
  late MemoryHistoryStore store;
  late PeerHistory history;
  late RecordingBackend backend;
  late IncomingNotifications notifications;
  late PeerHistoryNotifications observer;
  setUp(() async {
    store = MemoryHistoryStore();
    history = PeerHistory(store: store);
    await history.load('me');
    backend = RecordingBackend();
    notifications = IncomingNotifications(identityId: 'me', backend: backend);
  });
  tearDown(() {
    observer.dispose();
    notifications.dispose();
    history.dispose();
  });
  Future<void> settle() async {
    await history.flush();
    await Future<void>.delayed(Duration.zero);
  }

  void bind() => observer = PeerHistoryNotifications(
    history: history,
    notifications: notifications,
  );

  test(
    'baseline history is silent but new incoming messages notify once',
    () async {
      history.add('alice', message('old'));
      await settle();
      bind();
      history.add('alice', message('new'));
      history.add('alice', message('out', incoming: false));
      history.changed();
      await settle();
      expect(backend.shown.map((n) => n.messageId), ['new']);
    },
  );

  test(
    'pending incoming file notifies only after durable completion',
    () async {
      final ref = AttachmentRef(
        digest: 'a' * 64,
        name: 'archive.zip',
        mimeType: 'application/zip',
        size: 10,
        chunkedId: 'file_identifier_1234',
        chunkSize: 262144,
      );
      history.add(
        'alice',
        message('file', status: DeliveryStatus.pending, attachmentRef: ref),
      );
      await settle();
      bind();
      history.changed();
      await settle();
      expect(backend.shown, isEmpty);
      store.barrier = Completer<void>();
      history.setStatus('alice', 'file', DeliveryStatus.delivered);
      await Future<void>.delayed(Duration.zero);
      expect(backend.shown, isEmpty);
      store.barrier!.complete();
      await settle();
      expect(backend.shown.single.body, 'Received file: archive.zip');
    },
  );

  test(
    'reloaded delivered history is never treated as incoming arrival',
    () async {
      bind();
      store.source = jsonEncode({
        'version': 3,
        'rooms': {
          'alice': [message('loaded').toJson()],
        },
      });
      await history.load('me');
      history.changed();
      await settle();
      expect(backend.shown, isEmpty);
      history.add('alice', message('new'));
      await settle();
      expect(backend.shown.map((n) => n.messageId), ['new']);
    },
  );

  test(
    'failed persistence and identity change cannot leak notifications',
    () async {
      bind();
      store.fail = true;
      history.add('alice', message('lost'));
      await settle();
      expect(backend.shown, isEmpty);
      store.fail = false;
      await history.load('different identity');
      history.add('bob', message('other'));
      await settle();
      expect(backend.shown, isEmpty);
    },
  );

  test(
    'disposal cancels notification waiting for history persistence',
    () async {
      bind();
      store.barrier = Completer<void>();
      history.add('alice', message('pending write'));
      observer.dispose();
      store.barrier!.complete();
      await settle();
      expect(backend.shown, isEmpty);
    },
  );
}
