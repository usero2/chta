import 'dart:collection';

import 'package:cht/delivery/gap_repair.dart';
import 'package:cht/delivery/peer_gap_repair.dart';
import 'package:cht/chat/peer_history.dart';
import 'package:cht/delivery/peer_delivery_sink.dart';
import 'package:cht/delivery/delivery_envelope.dart';
import 'package:flutter_test/flutter_test.dart';

import 'delivery_envelope_test.dart' show Crypto;
import 'peer_delivery_sink_test.dart' show MemoryHistory;

void main() {
  test('private repair keeps signed author time, orders missing messages and skips deleted history', () async {
    final author = 'did:cht:${'a' * 64}', owner = 'did:cht:${'b' * 64}';
    final history = PeerHistory(store: MemoryHistory(), clock: () => 3000);
    await history.load(owner);
    final sink = PeerDeliverySink(
      ownerId: owner,
      crypto: Crypto(),
      history: history,
      isTrusted: (id) => id == author,
    );
    final repair = PeerGapRepair(sink: sink, peer: author);
    final e = await DeliveryEnvelope.create(
      Crypto(),
      scope: repair.scope,
      messageId: 'first',
      sentAt: 1000,
      kind: 'text',
      payload: {'text': 'original'},
    );
    history.add(
      author,
      PeerMessage(
        id: 'later',
        text: 'recent',
        incoming: true,
        status: DeliveryStatus.delivered,
        sentAtMilliseconds: 2000,
      ),
    );
    await repair.commit(GapRecord('first', e.toWire()));
    expect(history.messagesFor(author).map((m) => m.id), ['first', 'later']);
    final repaired = history.messagesFor(author).first;
    expect(repaired.repaired, isTrue);
    expect(repaired.receivedAtMilliseconds, isNull);
    await expectLater(
      repair.commit(GapRecord('forged', e.toWire())),
      throwsFormatException,
    );
    await history.clearConversation(author);
    await repair.commit(GapRecord('first', e.toWire()));
    expect(history.messagesFor(author), isEmpty);
    history.dispose();
  });
  test('repair deduplicates exact records and resumes after a failed durable commit', () async {
    final wire = Queue<(bool, String)>(),
        local = <String, GapRecord>{},
        remote = <String, GapRecord>{};
    final cursors = <String, int>{};
    var fail = true, imports = 0;
    for (var i = 0; i < 20; i++) {
      remote['m$i'] = GapRecord('m$i', 'message $i');
    }
    local['m4'] = remote['m4']!;
    local['m18'] = remote['m18']!;
    GapRepair setup(bool sender) => GapRepair(
      send: (frame) async {
        wire.add((sender, frame));
      },
      authorize: (scope) async => scope == 'room',
      records: (_) => (sender ? remote : local).values.toList(),
      contains: (_, id) =>
          (sender ? remote : local).containsKey(id) || id == 'm9',
      commit: (_, record) async {
        if (record.id == 'm16' && fail) throw StateError('disk failure');
        local[record.id] = record;
        imports++;
      },
      checkpoint: (scope, snapshot, next) async {
        cursors[snapshot] = next;
      },
      resume: (scope, snapshot) async => cursors[snapshot] ?? 0,
    );
    final sender = setup(true);
    var receiver = setup(false);
    Future<void> drain() async {
      var limit = 200;
      while (wire.isNotEmpty && limit-- > 0) {
        final (fromSender, frame) = wire.removeFirst();
        await (fromSender ? receiver : sender).receive(frame);
      }
      expect(limit, greaterThan(0));
    }

    await sender.offer('room');
    await drain();
    expect(cursors.values, [16]);
    expect(local.containsKey('m16'), isFalse);
    fail = false;
    receiver.close();
    receiver = setup(false);
    await sender.offer('room');
    await drain();
    expect(local.length, 19);
    expect(local.containsKey('m9'), isFalse);
    expect(imports, 17);
    sender.close();
    receiver.close();
  });
}
