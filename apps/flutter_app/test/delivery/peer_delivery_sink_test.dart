import 'dart:async';

import 'package:cht/chat/peer_history.dart';
import 'package:cht/chat/peer_history_store.dart';
import 'package:cht/courier/courier_receiver.dart';
import 'package:cht/delivery/delivery_envelope.dart';
import 'package:cht/delivery/peer_delivery_sink.dart';
import 'package:flutter_test/flutter_test.dart';

import 'delivery_envelope_test.dart' show Crypto;

class MemoryHistory implements PeerHistoryStore {
  final values = <String, String>{};
  @override
  Future<String?> load(String owner) async => values[owner];
  @override
  Future<void> save(String owner, String source) async {
    values[owner] = source;
  }
}

class InterruptedHistory extends MemoryHistory {
  final entered = Completer<void>(), allow = Completer<void>();
  bool fail = true;
  @override
  Future<void> save(String owner, String source) async {
    if (!entered.isCompleted) entered.complete();
    await allow.future;
    if (fail) throw StateError('Synthetic disk error');
    await super.save(owner, source);
  }
}

void main() {
  final owner = 'did:cht:${'b' * 64}', peer = 'did:cht:${'a' * 64}';
  test('duplicate receipts wait for the first write and retry a failed durable commit', () async {
    final disk = InterruptedHistory(),
        history = PeerHistory(store: disk),
        crypto = Crypto();
    await history.load(owner);
    final sink = PeerDeliverySink(
      ownerId: owner,
      crypto: crypto,
      history: history,
      isTrusted: (id) => id == peer,
    );
    final e = await DeliveryEnvelope.create(
      crypto,
      scope: directDeliveryScope(owner, peer),
      messageId: 'queued',
      sentAt: 1000,
      kind: 'text',
      payload: {'text': 'hello'},
    );
    final first = sink.commit(CourierReceived(e, 2000));
    final result = expectLater(first, throwsStateError);
    await disk.entered.future;
    bool answered = false;
    final duplicate = sink
        .existingReceivedAt(e)
        .whenComplete(() => answered = true);
    final checked = expectLater(duplicate, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    final answeredBeforeWrite = answered;
    disk.allow.complete();
    await result;
    await checked;
    expect(answeredBeforeWrite, isFalse);
    expect(disk.values, isEmpty);
    disk.fail = false;
    expect(await sink.existingReceivedAt(e), 2000);
    expect(disk.values[owner], contains('queued'));
    history.dispose();
  });
  test('live and Courier copies commit once, preserve receipt times and reject conflicting content', () async {
    final crypto = Crypto(), history = PeerHistory(store: MemoryHistory());
    await history.load(owner);
    final sink = PeerDeliverySink(
      ownerId: owner,
      crypto: crypto,
      history: history,
      isTrusted: (id) => id == peer,
    );
    final e = await DeliveryEnvelope.create(
      crypto,
      scope: directDeliveryScope(owner, peer),
      messageId: 'original',
      sentAt: 1000,
      kind: 'text',
      payload: {'text': 'hello'},
    );
    await sink.commit(CourierReceived(e, 2000));
    await sink.commit(CourierReceived(e, 3000));
    expect(history.messagesFor(peer), hasLength(1));
    expect(history.messagesFor(peer).single.receivedAtMilliseconds, 2000);
    expect(await sink.existingReceivedAt(e), 2000);
    final bad = await DeliveryEnvelope.create(
      crypto,
      scope: e.scope,
      messageId: e.messageId,
      sentAt: 1000,
      kind: 'text',
      payload: {'text': 'conflicting'},
    );
    await expectLater(
      sink.commit(CourierReceived(bad, 4000)),
      throwsFormatException,
    );
    expect(history.messagesFor(peer).single.text, 'hello');
    history.dispose();
  });
  test('deleted conversations cannot be resurrected by unseen old copies or scopes belonging to another peer', () async {
    final crypto = Crypto(),
        history = PeerHistory(store: MemoryHistory(), clock: () => 2000);
    await history.load(owner);
    final sink = PeerDeliverySink(
      ownerId: owner,
      crypto: crypto,
      history: history,
      isTrusted: (id) => id == peer,
    );
    final e = await DeliveryEnvelope.create(
      crypto,
      scope: directDeliveryScope(owner, peer),
      messageId: 'unseen',
      sentAt: 1000,
      kind: 'text',
      payload: {'text': 'old'},
    );
    await history.clearConversation(peer);
    expect(sink.isDeleted(e), isTrue);
    await expectLater(sink.commit(CourierReceived(e, 3000)), throwsStateError);
    expect(history.messagesFor(peer), isEmpty);
    final wrong = await DeliveryEnvelope.create(
      crypto,
      scope: 'direct:wrong',
      messageId: 'other',
      sentAt: 3000,
      kind: 'text',
      payload: {'text': 'wrong scope'},
    );
    expect(await sink.authorize(wrong), isFalse);
    history.dispose();
  });
}
