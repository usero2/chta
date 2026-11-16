import 'dart:async';
import 'dart:convert';

import 'package:cht/account/account_bridge.dart';
import 'package:cht/account/account_models.dart';
import 'package:cht/contact_requests/contact_request_bridge.dart';
import 'package:cht/contact_requests/contact_request_controller.dart';
import 'package:cht/contact_requests/contact_request_transport.dart';
import 'package:cht/groups/group_blob_bridge.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

final alice = 'did:cht:${'a' * 64}', bob = 'did:cht:${'b' * 64}';
String card(String id) => jsonEncode({
  'identity': {'id': id},
  'displayName': id == alice ? 'Alice' : 'Bob',
});

class Account implements AccountBridge {
  Account(this.owner);
  final String owner;
  String? switchedOwner;
  final saved = <String, ContactView>{};
  @override
  Future<String> contactCard({
    String displayName = '',
    String avatar = '',
  }) async => card(owner);
  @override
  Future<IdentityView> identity() async => IdentityView(
    id: switchedOwner ?? owner,
    rootPublicKey: '',
    noiseStaticPublicKey: '',
    derivationVersion: 1,
  );
  @override
  Future<List<ContactView>> contacts() async => saved.values.toList();
  @override
  Future<ContactView> inspectContactCard(String source) async {
    final data = jsonDecode(source) as Map;
    return ContactView(
      identityId: (data['identity'] as Map)['id'] as String,
      displayName: data['displayName'] as String,
      fingerprint: 'Synthetic fingerprint',
      verified: false,
      relayUrls: (data['relayUrls'] as List? ?? const []).cast<String>(),
    );
  }

  @override
  Future<List<ContactView>> addContact(String source, String alias) async {
    final contact = await inspectContactCard(source);
    if (saved.containsKey(contact.identityId)) {
      throw StateError('Duplicate contact');
    }
    saved[contact.identityId] = ContactView(
      identityId: contact.identityId,
      displayName: alias.isEmpty ? contact.displayName : alias,
      fingerprint: contact.fingerprint,
      verified: false,
      alias: alias,
    );
    return contacts();
  }

  @override
  Future<List<ContactView>> markContactVerified(String id) async {
    final c = saved[id]!;
    saved[id] = ContactView(
      identityId: id,
      displayName: c.displayName,
      fingerprint: c.fingerprint,
      verified: true,
      alias: c.alias,
    );
    return contacts();
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class Crypto implements ContactRequestBridge {
  Crypto(this.account);
  final Account account;
  static int sequence = 0;
  List<String> routes = [];
  @override
  Future<Map<String, Object?>> contactRequestCall(
    String operation,
    Map<String, Object?> args,
  ) async {
    if (operation == 'peer') {
      return {'cardJson': card(args['peerId'] as String)};
    }
    if (operation == 'seal') {
      return {
        'envelope': {
          'from': account.owner,
          'to':
              (jsonDecode(args['peerCard'] as String)['identity'] as Map)['id'],
          'requestId': args['requestId'],
          'kind': args['kind'],
          'cardJson': jsonEncode({
            ...jsonDecode(card(account.owner)) as Map,
            'relayUrls': routes,
          }),
          'packetId': 'packet-${sequence++}',
        },
      };
    }
    final e = jsonDecode(args['source'] as String) as Map;
    if (e['to'] != account.owner) throw StateError('Wrong recipient');
    return {
      'peerId': e['from'],
      'requestId': e['requestId'],
      'kind': e['kind'],
      'cardJson': e['cardJson'],
      'packetId': e['packetId'],
    };
  }
}

class Blobs implements GroupBlobBridge {
  final values = <String, String>{};
  bool fail = false;
  Completer<void>? gate;
  @override
  Future<String?> loadGroupBlob(String owner, String key) async =>
      values['$owner/$key'];
  @override
  Future<void> saveGroupBlob(String owner, String key, String value) async {
    if (gate != null) await gate!.future;
    if (fail) throw StateError('Disk unavailable');
    values['$owner/$key'] = value;
  }

  @override
  Future<void> deleteGroupBlob(String owner, String key) async =>
      values.remove('$owner/$key');
}

class Transport extends ChangeNotifier implements ContactRequestTransport {
  Transport(this.owner);
  final String owner;
  Transport? peer;
  @override
  bool registered = true;
  final frames = StreamController<Map<String, Object?>>.broadcast();
  final sent = <Map<String, Object?>>[];
  @override
  Stream<Map<String, Object?>> get contactRequests => frames.stream;
  @override
  Future<void> sendContactRequest(Map<String, Object?> packet) async {
    if (!registered) throw StateError('Offline');
    sent.add(packet);
    if (peer?.registered == true) peer!.frames.add(Map.of(packet));
  }

  Future<void> close() async {
    await frames.close();
    dispose();
  }
}

ContactRequestController controller(
  Account account,
  Blobs store, {
  Future<void> Function(ContactView)? onTrusted,
}) => ContactRequestController(
  ownerId: account.owner,
  account: account,
  crypto: Crypto(account),
  blobs: store,
  displayName: () => account.owner == alice ? 'Alice' : 'Bob',
  retryEvery: Duration.zero,
  clock: () => 1000,
  idFactory: () => '1' * 32,
  onTrustedContact: onTrusted,
);
Future<void> drain(
  ContactRequestController a,
  ContactRequestController b,
) async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
    await a.flush();
    await b.flush();
  }
}

void main() {
  test(
    'fresh signed relay routes are learned only after consent and accepted ACK',
    () async {
      final a = Account(alice), b = Account(bob);
      await a.addContact(card(bob), '');
      await a.markContactVerified(bob);
      final ac = Crypto(a)..routes = ['wss://sender.example.com/cht'];
      final bc = Crypto(b)..routes = ['wss://recipient.example.com/cht'];
      final learnedA = <String>[], learnedB = <String>[];
      ContactRequestController make(
        Account account,
        Crypto crypto,
        List<String> learned,
      ) => ContactRequestController(
        ownerId: account.owner,
        account: account,
        crypto: crypto,
        blobs: Blobs(),
        displayName: () => 'Synthetic',
        retryEvery: Duration.zero,
        clock: () => 1000,
        onAcceptedRoutes: (routes) async {
          learned.addAll(routes);
        },
      );
      final ca = make(a, ac, learnedA), cb = make(b, bc, learnedB);
      final ta = Transport(alice), tb = Transport(bob);
      ta.peer = tb;
      tb.peer = ta;
      await ca.initialize();
      await cb.initialize();
      ca.attach(ta);
      cb.attach(tb);
      await ca.request(bob);
      await drain(ca, cb);
      expect(learnedA, isEmpty);
      expect(learnedB, isEmpty);
      await cb.accept(cb.incoming.single.id);
      await drain(ca, cb);
      expect(learnedA, contains('wss://recipient.example.com/cht'));
      expect(learnedB, contains('wss://sender.example.com/cht'));
      await ca.close();
      await cb.close();
      await ta.close();
      await tb.close();
    },
  );
  test('removing a contact cancels its pending retries', () async {
    final a = Account(alice), store = Blobs();
    await a.addContact(card(bob), '');
    await a.markContactVerified(bob);
    final c = controller(a, store), t = Transport(alice);
    await c.initialize();
    c.attach(t);
    await c.request(bob);
    final before = t.sent.length;
    a.saved.remove(bob);
    await c.pulse(force: true);
    expect(t.sent.length, before);
    expect(c.statusFor(bob), isNull);
    await c.close();
    await t.close();
  });
  test(
    'deleted accepted contact requires Review again despite a cached decision',
    () async {
      final a = Account(alice), b = Account(bob), sa = Blobs(), sb = Blobs();
      await a.addContact(card(bob), '');
      await a.markContactVerified(bob);
      final ca = controller(a, sa),
          cb = controller(b, sb),
          ta = Transport(alice),
          tb = Transport(bob);
      ta.peer = tb;
      tb.peer = ta;
      await ca.initialize();
      await cb.initialize();
      ca.attach(ta);
      cb.attach(tb);
      await ca.request(bob);
      await drain(ca, cb);
      await cb.accept(cb.incoming.single.id);
      await drain(ca, cb);
      b.saved.remove(alice);
      await ca.request(bob);
      await drain(ca, cb);
      expect(cb.incoming, hasLength(1));
      expect(b.saved, isEmpty);
      expect(ca.statusFor(bob), ContactRequestStatus.received);
      await ca.close();
      await cb.close();
      await ta.close();
      await tb.close();
    },
  );
  test(
    'pending inbox and received ACK appear only after durable storage succeeds',
    () async {
      final a = Account(alice), b = Account(bob), sa = Blobs(), sb = Blobs();
      await a.addContact(card(bob), '');
      await a.markContactVerified(bob);
      final ca = controller(a, sa),
          cb = controller(b, sb),
          ta = Transport(alice),
          tb = Transport(bob);
      ta.peer = tb;
      tb.peer = ta;
      await ca.initialize();
      await cb.initialize();
      ca.attach(ta);
      cb.attach(tb);
      sb.gate = Completer<void>();
      await ca.request(bob);
      await Future<void>.delayed(Duration.zero);
      expect(cb.incoming, isEmpty);
      expect(tb.sent, isEmpty);
      expect(b.saved, isEmpty);
      sb.gate!.complete();
      await drain(ca, cb);
      expect(cb.incoming, hasLength(1));
      expect(ca.statusFor(bob), ContactRequestStatus.received);
      await ca.close();
      await cb.close();
      await ta.close();
      await tb.close();
    },
  );
  test('restart recovers an accepted contact when saving its decision previously failed', () async {
    final a = Account(alice), b = Account(bob), sa = Blobs(), sb = Blobs();
    await a.addContact(card(bob), '');
    await a.markContactVerified(bob);
    final ca = controller(a, sa);
    var cb = controller(b, sb);
    final ta = Transport(alice), tb = Transport(bob);
    ta.peer = tb;
    tb.peer = ta;
    await ca.initialize();
    await cb.initialize();
    ca.attach(ta);
    cb.attach(tb);
    await ca.request(bob);
    await drain(ca, cb);
    sb.fail = true;
    await expectLater(cb.accept(cb.incoming.single.id), throwsStateError);
    expect(cb.incoming, hasLength(1));
    expect(tb.sent.where((e) => e['kind'] == 'accepted'), isEmpty);
    sb.fail = false;
    await cb.close();
    cb = controller(b, sb);
    await cb.initialize();
    cb.attach(tb);
    await ca.pulse(force: true);
    await drain(ca, cb);
    expect(cb.incoming, isEmpty);
    expect(ca.statusFor(bob), isNull);
    await ca.close();
    await cb.close();
    await ta.close();
    await tb.close();
  });
  test('one-sided add persists pending until Review Accept, then authenticates a decision', () async {
    final a = Account(alice), b = Account(bob), sa = Blobs(), sb = Blobs();
    await a.addContact(card(bob), 'My Bob');
    await a.markContactVerified(bob);
    final trusted = <String>[];
    final ca = controller(
          a,
          sa,
          onTrusted: (c) async {
            trusted.add(c.identityId);
          },
        ),
        cb = controller(b, sb);
    final ta = Transport(alice), tb = Transport(bob);
    ta.peer = tb;
    tb.peer = ta;
    await ca.initialize();
    await cb.initialize();
    ca.attach(ta);
    cb.attach(tb);
    await ca.request(bob);
    await drain(ca, cb);
    expect(cb.incoming, hasLength(1));
    expect(b.saved, isEmpty);
    expect(ca.statusFor(bob), ContactRequestStatus.received);
    final accepted = await cb.accept(cb.incoming.single.id, alias: 'My Alice');
    await drain(ca, cb);
    expect(accepted.verified, isTrue);
    expect(accepted.displayName, 'My Alice');
    expect(ca.statusFor(bob), isNull);
    expect(cb.incoming, isEmpty);
    expect(trusted, [bob]);
    expect(a.saved[bob]!.displayName, 'My Bob');
    await ca.close();
    await cb.close();
    await ta.close();
    await tb.close();
  });
  test('sender restarts offline with the same request ID; lost accepted ACK recovers without another Review', () async {
    final a = Account(alice), b = Account(bob), sa = Blobs(), sb = Blobs();
    await a.addContact(card(bob), '');
    await a.markContactVerified(bob);
    var ca = controller(a, sa);
    var cb = controller(b, sb);
    final ta = Transport(alice), tb = Transport(bob)..registered = false;
    ta.peer = tb;
    tb.peer = ta;
    await ca.initialize();
    await cb.initialize();
    ca.attach(ta);
    cb.attach(tb);
    await ca.request(bob);
    expect(ca.statusFor(bob), ContactRequestStatus.pending);
    await ca.close();
    ca = controller(a, sa);
    await ca.initialize();
    ca.attach(ta);
    tb.registered = true;
    await ca.pulse(force: true);
    await drain(ca, cb);
    expect(cb.incoming.single.requestId, '1' * 32);
    ta.registered = false;
    await cb.accept(cb.incoming.single.id);
    await cb.close();
    cb = controller(b, sb);
    await cb.initialize();
    cb.attach(tb);
    ta.registered = true;
    await ca.pulse(force: true);
    await drain(ca, cb);
    expect(cb.incoming, isEmpty);
    expect(ca.statusFor(bob), isNull);
    expect(b.saved[alice]!.verified, isTrue);
    await ca.close();
    await cb.close();
    await ta.close();
    await tb.close();
  });
  test('Decline persists and retrying the same request does not prompt or add a friend', () async {
    final a = Account(alice), b = Account(bob), sa = Blobs(), sb = Blobs();
    await a.addContact(card(bob), '');
    await a.markContactVerified(bob);
    final ca = controller(a, sa),
        cb = controller(b, sb),
        ta = Transport(alice),
        tb = Transport(bob);
    ta.peer = tb;
    tb.peer = ta;
    await ca.initialize();
    await cb.initialize();
    ca.attach(ta);
    cb.attach(tb);
    await ca.request(bob);
    await drain(ca, cb);
    await cb.decline(cb.incoming.single.id);
    await drain(ca, cb);
    expect(ca.statusFor(bob), ContactRequestStatus.declined);
    expect(b.saved, isEmpty);
    expect(cb.incoming, isEmpty);
    await ca.pulse(force: true);
    await drain(ca, cb);
    expect(cb.incoming, isEmpty);
    await ca.close();
    await cb.close();
    await ta.close();
    await tb.close();
  });
  test('failed outgoing persistence sends nothing and owner switch stops queued setup', () async {
    final a = Account(alice), store = Blobs();
    await a.addContact(card(bob), '');
    await a.markContactVerified(bob);
    final c = controller(a, store), transport = Transport(alice);
    await c.initialize();
    c.attach(transport);
    store.fail = true;
    await expectLater(c.request(bob), throwsStateError);
    expect(transport.sent, isEmpty);
    expect(c.statusFor(bob), isNull);
    store.fail = false;
    await c.request(bob);
    final before = transport.sent.length;
    a.switchedOwner = bob;
    await expectLater(c.pulse(force: true), throwsStateError);
    expect(transport.sent.length, before);
    await c.close();
    await transport.close();
  });
}
