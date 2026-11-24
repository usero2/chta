import 'dart:convert';

import 'package:cht/chat/peer_history.dart';
import 'package:cht/account/account_models.dart';
import 'package:cht/chat/room_history_store.dart';
import 'package:cht/groups/group_blob_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

import 'durable_outbox_test.dart' show Store;

class Blobs implements GroupBlobBridge {
  final values = <String, String>{};
  final writes = <String>[];
  bool failPage = false, failIndex = false;
  bool failAny = false;
  @override
  Future<String?> loadGroupBlob(String owner, String key) async =>
      values['$owner/$key'];
  @override
  Future<void> saveGroupBlob(String owner, String key, String value) async {
    if (failAny) throw StateError('Synthetic storage unavailable');
    if (failPage && key.startsWith('history_room_') ||
        failIndex && key == RoomHistoryStore.indexKey) {
      throw StateError('Synthetic disk full');
    }
    writes.add(key);
    values['$owner/$key'] = value;
  }

  @override
  Future<void> deleteGroupBlob(String owner, String key) async {
    values.remove('$owner/$key');
  }
}

Map<String, Object?> message(String id, String text) => PeerMessage(
  id: id,
  text: text,
  incoming: false,
  status: DeliveryStatus.delivered,
  sentAtMilliseconds: 1,
).toJson();
String metadata() => jsonEncode({
  'version': 5,
  'names': {'alice': 'Alice', 'bob': 'Bob'},
  'avatars': {},
  'conversationGenerations': {},
  'tombstones': {},
});
String snapshot() => jsonEncode({
  ...jsonDecode(metadata()) as Map,
  'rooms': {
    'alice': [message('a', 'old')],
    'bob': [message('b', 'keep')],
  },
});

class CountedMessage extends PeerMessage {
  CountedMessage()
    : super(
        id: 'counted',
        text: 'other room',
        incoming: false,
        status: DeliveryStatus.delivered,
      );
  int serializations = 0;
  @override
  Map<String, Object?> toJson() {
    serializations++;
    return super.toJson();
  }
}

void main() {
  test('v6 paged history preserves signed delivery metadata and deletion cutoffs',()async{
    final blobs=Blobs(),legacy=Store(),store=RoomHistoryStore(legacy:legacy,blobs:blobs);
    final history=PeerHistory(store:store,clock:()=>2000);await history.load('owner');
    history.add('friend',PeerMessage(id:'original',text:'hello',incoming:false,status:DeliveryStatus.pending,sentAtMilliseconds:1000,deliveryEnvelope:{'version':2,'event':{'messageId':'original'},'payload':'{}'}));await history.flush();expect(history.error,isNull);
    final restored=PeerHistory(store:RoomHistoryStore(legacy:legacy,blobs:blobs));await restored.load('owner');expect(restored.messagesFor('friend').single.deliveryEnvelope,isNotNull);
    await history.clearConversation('friend');final after=PeerHistory(store:RoomHistoryStore(legacy:legacy,blobs:blobs));await after.load('owner');expect(after.isDeletedDelivery('friend','unseen',1000),isTrue);
    history.dispose();restored.dispose();after.dispose();
  });
  test('a corrupt previous index cannot prevent saving the healthy current history', () async {
    final blobs = Blobs();
    final store = RoomHistoryStore(legacy: Store(), blobs: blobs);
    await store.save('owner', snapshot());
    blobs.values['owner/peer_history_previous_index_v1'] = '{damaged backup';
    await store.saveChanges('owner', metadata(), {
      'alice': jsonEncode([message('a', 'new')]),
    });
    expect(
      (jsonDecode((await store.load('owner'))!) as Map)['rooms']['alice'],
      [message('a', 'new')],
    );
  });
  for (final metadataOnly in [false, true]) {
    test(
      'failed room remains dirty across ${metadataOnly ? "metadata" : "other room"} saves',
      () async {
        final blobs = Blobs();
        final store = RoomHistoryStore(legacy: Store(), blobs: blobs);
        final history = PeerHistory(store: store);
        await history.load('owner');
        blobs.failPage = true;
        history.add(
          'alice',
          PeerMessage(
            id: 'pending',
            text: 'must survive',
            incoming: false,
            status: DeliveryStatus.pending,
            queuedForDelivery: true,
          ),
        );
        await history.flush();
        expect(history.error, isNotNull);
        blobs.failPage = false;
        if (metadataOnly) {
          history.rememberContacts([
            ContactView(
              identityId: 'bob',
              displayName: 'Bob',
              fingerprint: 'fixture',
              verified: true,
            ),
          ]);
        } else {
          history.add(
            'bob',
            PeerMessage(
              id: 'other',
              text: 'other room',
              incoming: true,
              status: DeliveryStatus.delivered,
            ),
          );
        }
        await history.flush();
        expect(history.error, isNull);
        final reopened = PeerHistory(
          store: RoomHistoryStore(legacy: Store(), blobs: blobs),
        );
        await reopened.load('owner');
        expect(reopened.messagesFor('alice').map((m) => m.id), ['pending']);
        expect(reopened.queuedMessages.single.value.id, 'pending');
        history.dispose();
        reopened.dispose();
      },
    );
  }
  test(
    'legacy received time and unrelated room survive first incremental save',
    () async {
      final legacy = Store(), blobs = Blobs();
      legacy.saved['owner'] = jsonEncode({
        'version': 1,
        'rooms': {
          'old': [
            {
              'id': 'old',
              'text': 'legacy',
              'incoming': true,
              'status': 'delivered',
              'sentAtMilliseconds': 42,
            },
          ],
        },
      });
      final store = RoomHistoryStore(legacy: legacy, blobs: blobs);
      await store.saveChanges('owner', metadata(), {
        'alice': jsonEncode([message('new', 'new')]),
      });
      final value = jsonDecode((await store.load('owner'))!) as Map;
      expect(value['rooms']['old'][0]['sentAtMilliseconds'], isNull);
      expect(value['rooms']['old'][0]['receivedAtMilliseconds'], 42);
    },
  );
  test(
    'concurrent room changes serialize and older pages are safely reclaimed',
    () async {
      final blobs = Blobs(),
          store = RoomHistoryStore(legacy: Store(), blobs: Blobs());
      final actual = RoomHistoryStore(legacy: Store(), blobs: blobs);
      await Future.wait([
        actual.saveChanges('owner', metadata(), {
          'alice': jsonEncode([message('a', 'one')]),
        }),
        actual.saveChanges('owner', metadata(), {
          'bob': jsonEncode([message('b', 'keep')]),
        }),
      ]);
      for (final text in ['two', 'three', 'four']) {
        await actual.saveChanges('owner', metadata(), {
          'alice': jsonEncode([message('a', text)]),
        });
      }
      final value = jsonDecode((await actual.load('owner'))!) as Map;
      expect(value['rooms']['alice'], [message('a', 'four')]);
      expect(value['rooms']['bob'], [message('b', 'keep')]);
      expect(
        blobs.values.keys.where((k) => k.contains('/history_room_')).length,
        3,
      );
      expect(await store.load('owner'), isNull);
    },
  );
  test('metadata-only updates never serialize room messages', () async {
    final history = PeerHistory(
      store: RoomHistoryStore(legacy: Store(), blobs: Blobs()),
    );
    await history.load('owner');
    final message = CountedMessage();
    history.add('bob', message);
    await history.flush();
    message.serializations = 0;
    history.rememberContacts([
      ContactView(
        identityId: 'bob',
        displayName: 'New name',
        fingerprint: 'fixture',
        verified: true,
      ),
    ]);
    await history.flush();
    expect(message.serializations, 0);
    history.dispose();
  });
  test(
    'migration keeps legacy backup and updates only the changed room',
    () async {
      final legacy = Store(), blobs = Blobs();
      final original = snapshot();
      legacy.saved['owner'] = original;
      final store = RoomHistoryStore(legacy: legacy, blobs: blobs);
      expect(await store.load('owner'), original);
      await store.saveChanges('owner', metadata(), {
        'alice': jsonEncode([message('a', 'new')]),
      });
      expect(legacy.saved['owner'], original);
      final loaded = jsonDecode((await store.load('owner'))!) as Map;
      expect((loaded['rooms'] as Map)['bob'], [message('b', 'keep')]);
      blobs.writes.clear();
      await store.saveChanges('owner', metadata(), {
        'alice': jsonEncode([message('a', 'newer')]),
      });
      expect(
        blobs.writes.where((k) => k.startsWith('history_room_')).length,
        1,
      );
      expect(await store.load('other'), isNull);
    },
  );
  for (final failingPage in [true, false]) {
    test(
      'failed ${failingPage ? 'page' : 'manifest'} write leaves prior commit readable',
      () async {
        final legacy = Store(), blobs = Blobs();
        final store = RoomHistoryStore(legacy: legacy, blobs: blobs);
        await store.save('owner', snapshot());
        final before = await store.load('owner');
        blobs.failPage = failingPage;
        blobs.failIndex = !failingPage;
        await expectLater(
          store.saveChanges('owner', metadata(), {
            'alice': jsonEncode([message('a', 'not committed')]),
          }),
          throwsStateError,
        );
        final reopened = RoomHistoryStore(legacy: legacy, blobs: blobs);
        expect(await reopened.load('owner'), before);
      },
    );
  }
  test(
    'a missing or corrupted committed page never silently loads the old backup',
    () async {
      final legacy = Store(), blobs = Blobs();
      legacy.saved['owner'] = snapshot();
      final store = RoomHistoryStore(legacy: legacy, blobs: blobs);
      await store.save('owner', snapshot());
      final page = blobs.values.keys.firstWhere(
        (k) => k.contains('/history_room_'),
      );
      final value = blobs.values.remove(page)!;
      await expectLater(store.load('owner'), throwsFormatException);
      blobs.values[page] = value.replaceFirst('old', 'tampered');
      await expectLater(store.load('owner'), throwsFormatException);
      expect(legacy.saved['owner'], snapshot());
    },
  );
  test('status changes do not serialize another room and deletion persists tombstones', () async {
    final store = RoomHistoryStore(legacy: Store(), blobs: Blobs());
    final history = PeerHistory(store: store);
    await history.load('owner');
    final other = CountedMessage();
    history.add('bob', other);
    history.add(
      'alice',
      PeerMessage(
        id: 'a',
        text: 'hello',
        incoming: false,
        status: DeliveryStatus.pending,
      ),
    );
    await history.flush();
    other.serializations = 0;
    history.setStatus(
      'alice',
      'a',
      DeliveryStatus.delivered,
      receivedAtMilliseconds: 123,
    );
    await history.flush();
    expect(other.serializations, 0);
    await history.clearConversation('alice');
    final resumed = PeerHistory(
      store: RoomHistoryStore(legacy: Store(), blobs: store.blobs),
    );
    await resumed.load('owner');
    expect(resumed.messagesFor('alice'), isEmpty);
    resumed.add(
      'alice',
      PeerMessage(
        id: 'a',
        text: 'replayed',
        incoming: true,
        status: DeliveryStatus.delivered,
      ),
    );
    expect(resumed.messagesFor('alice'), isEmpty);
    history.dispose();
    resumed.dispose();
  });
  test(
    'large rooms are split into bounded pages and reload in order',
    () async {
      final blobs = Blobs(),
          store = RoomHistoryStore(legacy: Store(), blobs: Blobs());
      final actual = RoomHistoryStore(legacy: Store(), blobs: blobs);
      final items = [
        for (var i = 0; i < 400; i++) message('m$i', 'fixture-$i'),
      ];
      await actual.saveChanges('owner', metadata(), {
        'alice': jsonEncode(items),
      });
      final pages = blobs.values.entries
          .where((e) => e.key.contains('/history_room_'))
          .toList();
      expect(pages.length, greaterThan(1));
      expect(
        pages.every(
          (p) => utf8.encode(p.value).length <= RoomHistoryStore.maxPageBytes,
        ),
        isTrue,
      );
      expect(
        (jsonDecode((await actual.load('owner'))!) as Map)['rooms']['alice'],
        items,
      );
      expect(await store.load('owner'), isNull);
    },
  );
}
