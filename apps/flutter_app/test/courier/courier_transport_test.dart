import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cht/chat/cache_policy.dart';
import 'package:cht/courier/courier_journal.dart';
import 'package:cht/courier/courier_models.dart';
import 'package:cht/courier/courier_store.dart';
import 'package:cht/courier/courier_transport.dart';
import 'package:cht/courier/sender_jobs.dart';
import 'package:flutter_test/flutter_test.dart';

import 'courier_journal_test.dart' show Disk;
import 'courier_store_test.dart' as f;

final host = 'did:cht:${'e' * 64}';

class Bus {
  final clients = <String, Carrier>{};
  bool corrupt = false;
  bool dropPartAck = false, corruptDownload = false;
  Map<String, Object?>? lastStored;
  void Function(Map<String, Object?>)? onSend;
  Carrier connect(String id) => clients[id] = Carrier(this, id);
}

class Carrier implements CourierCarrier {
  Carrier(this.bus, this.id);
  final Bus bus;
  final String id;
  final controller = StreamController<CourierWireFrame>.broadcast();
  @override
  Stream<CourierWireFrame> get frames => controller.stream;
  @override
  List<String> get online => ['wss://relay.example.com/cht'];
  @override
  bool send(String route, String to, Map<String, Object?> body) {
    final target = bus.clients[to];
    if (target == null) return false;
    body = jsonDecode(jsonEncode(body)) as Map<String, dynamic>;
    bus.onSend?.call(body);
    final c = body['control'];
    if (c is Map && c['kind'] == 'stored') {
      bus.lastStored = Map<String, Object?>.from(body);
      if (bus.corrupt) c['signature'] = 'forged';
    }
    if (bus.dropPartAck && body['op'] == 'partAck' && id == host) {
      bus.dropPartAck = false;
      return true;
    }
    if (bus.corruptDownload && body['op'] == 'resultPart') {
      body['bytes'] = base64UrlEncode(Uint8List(8192)).replaceAll('=', '');
    }
    target.controller.add(CourierWireFrame(route, id, body));
    return true;
  }

  @override
  Future<void> close() async {
    await controller.close();
  }
}

class Crypto extends f.Crypto {
  Crypto(this.owner, {this.node});
  final String owner;
  final String? node;
  @override
  Future<Map<String, Object?>> deliveryCall(
    String op,
    Map<String, Object?> args,
  ) async {
    if (op == 'signControl' &&
        args['kind'] != 'advertisement' &&
        (args['expiresAt'] as int) - (args['now'] as int) > 120000) {
      throw StateError('Control lifetime overflow');
    }
    if (op == 'signControl') {
      return {
        'version': 1,
        'kind': args['kind'],
        'signerId': args['nodeState'] == null ? owner : node,
        'publicKey': owner == f.sender ? f.senderPublic : f.receiverPublic,
        'certificate': args['nodeState'] == null
            ? null
            : {'nodeId': node, 'ownerId': owner},
        'challenge': args['challenge'],
        'body': args['body'],
        'issuedAt': args['now'],
        'expiresAt': args['expiresAt'],
        'signature': 'valid',
      };
    }
    return super.deliveryCall(op, args);
  }
}

void main() {
  test('pausing a logical job interrupts an active Courier package before its next fragment', () async {
    final bus = Bus(),
        budget = CachePolicy(
          ownerId: host,
          settings: Disk(),
          availableSpace: () async => null,
        );
    await budget.initialize();
    final crypto = Crypto(host, node: f.nodeId),
        store = CourierStore(
          nodeId: f.nodeId,
          journal: CourierJournal(
            ownerId: host,
            namespace: 'courier_host',
            storage: Disk(),
          ),
          crypto: crypto,
          budget: budget,
          clock: () => f.now,
        );
    await store.initialize();
    final serving = CourierTransport(
      ownerId: host,
      crypto: crypto,
      carrier: bus.connect(host),
      clock: () => f.now,
    );
    await serving.startHost(
      nodeState: 'protected',
      certificate: {'nodeId': f.nodeId, 'ownerId': host},
      store: store,
    );
    final sending = CourierTransport(
      ownerId: f.sender,
      crypto: Crypto(f.sender),
      carrier: bus.connect(f.sender),
      clock: () => f.now,
    );
    var fragments = 0;
    bus.onSend = (b) {
      if (b['op'] == 'uploadPart') {
        fragments++;
        sending.cancelJob((f.offer()['body'] as Map)['jobId'] as String);
      }
    };
    final node = CourierNode.verified(
      nodeId: f.nodeId,
      ownerId: host,
      certificate: {'nodeId': f.nodeId, 'ownerId': host},
      routes: ['wss://relay.example.com/cht'],
      expiresAt: f.now + f.day,
      freeBytes: 1073741824,
    );
    await expectLater(
      sending.request(
        node,
        kind: 'store',
        body: Map<String, Object?>.from(f.offer()['body'] as Map),
        upload: f.cipher,
      ),
      throwsStateError,
    );
    expect(fragments, 1);
    expect(bus.lastStored, isNull);
    await sending.close();
    await serving.close();
    store.close();
    budget.dispose();
  });
  test('a recipient can pick up packages held by its own Desktop Courier without a self chat', () async {
    final owner = f.receiver,
        bus = Bus(),
        budget = CachePolicy(
          ownerId: f.receiver,
          settings: Disk(),
          availableSpace: () async => null,
        );
    await budget.initialize();
    final crypto = Crypto(owner, node: f.nodeId),
        store = CourierStore(
          nodeId: f.nodeId,
          journal: CourierJournal(
            ownerId: owner,
            namespace: 'courier_host',
            storage: Disk(),
          ),
          crypto: crypto,
          budget: budget,
          clock: () => f.now,
        );
    await store.initialize();
    final serving = CourierTransport(
      ownerId: owner,
      crypto: crypto,
      carrier: bus.connect(owner),
      clock: () => f.now,
    );
    await serving.startHost(
      nodeState: 'protected',
      certificate: {'nodeId': f.nodeId, 'ownerId': owner},
      store: store,
    );
    final sender = CourierTransport(
      ownerId: f.sender,
      crypto: Crypto(f.sender),
      carrier: bus.connect(f.sender),
      clock: () => f.now,
    );
    final node = CourierNode.verified(
      nodeId: f.nodeId,
      ownerId: owner,
      certificate: {'nodeId': f.nodeId, 'ownerId': owner},
      routes: ['wss://relay.example.com/cht'],
      expiresAt: f.now + f.day,
      freeBytes: 1073741824,
    );
    await sender.request(
      node,
      kind: 'store',
      body: Map<String, Object?>.from(f.offer()['body'] as Map),
      upload: f.cipher,
    );
    final list = await serving.request(
      node,
      kind: 'pickup',
      body: Map<String, Object?>.from(f.pickup(action: 'list')['body'] as Map),
    );
    expect(jsonDecode(utf8.decode(list.bytes!)), hasLength(1));
    await serving.close();
    await sender.close();
    store.close();
    budget.dispose();
  });
  test(
    'stopping during an awaited host initialization cannot revive listening',
    () async {
      final settings = Disk(),
          budget = CachePolicy(
            ownerId: host,
            settings: settings,
            availableSpace: () async => null,
          );
      await budget.initialize();
      final entered = Completer<void>(), release = Completer<void>();
      settings.beforeSave = (_, _) async {
        if (!entered.isCompleted) {
          entered.complete();
          await release.future;
        }
      };
      final crypto = Crypto(host, node: f.nodeId),
          store = CourierStore(
            nodeId: f.nodeId,
            journal: CourierJournal(
              ownerId: host,
              namespace: 'courier_host',
              storage: Disk(),
            ),
            crypto: crypto,
            budget: budget,
            clock: () => f.now,
          );
      final serving = CourierTransport(
        ownerId: host,
        crypto: crypto,
        carrier: Bus().connect(host),
        clock: () => f.now,
      );
      final starting = serving.startHost(
        nodeState: 'protected',
        certificate: {'nodeId': f.nodeId, 'ownerId': host},
        store: store,
      );
      await entered.future;
      serving.stopHost();
      release.complete();
      await starting;
      expect(serving.hosting, isFalse);
      await serving.close();
      store.close();
      budget.dispose();
    },
  );
  test('Courier uses a valid reserved relay session identifier', () {
    expect(courierRoutingSession, matches(RegExp(r'^[0-9a-f]{32}$')));
  });
  test('a stranger deposits and the authenticated recipient picks up bounded ciphertext without a contact entry', () async {
    final bus = Bus()..dropPartAck = true,
        budget = CachePolicy(
          ownerId: host,
          settings: Disk(),
          availableSpace: () async => null,
        );
    await budget.initialize();
    final crypto = Crypto(host, node: f.nodeId),
        store = CourierStore(
          nodeId: f.nodeId,
          journal: CourierJournal(
            ownerId: host,
            namespace: 'courier_host',
            storage: Disk(),
          ),
          crypto: crypto,
          budget: budget,
          clock: () => f.now,
        );
    await store.initialize();
    final serving = CourierTransport(
      ownerId: host,
      crypto: crypto,
      carrier: bus.connect(host),
      clock: () => f.now,
    );
    await serving.startHost(
      nodeState: 'protected',
      certificate: {'nodeId': f.nodeId, 'ownerId': host},
      store: store,
    );
    var advancingTime = f.now;
    final sender = CourierTransport(
      ownerId: f.sender,
      crypto: Crypto(f.sender),
      carrier: bus.connect(f.sender),
      clock: () => advancingTime++,
      partTimeout: const Duration(milliseconds: 30),
    );
    final recipient = CourierTransport(
      ownerId: f.receiver,
      crypto: Crypto(f.receiver),
      carrier: bus.connect(f.receiver),
      clock: () => f.now,
    );
    final node = CourierNode.verified(
      nodeId: f.nodeId,
      ownerId: host,
      certificate: {'nodeId': f.nodeId, 'ownerId': host},
      routes: ['wss://relay.example.com/cht'],
      expiresAt: f.now + f.day,
      freeBytes: 1024 * 1024 * 1024,
    );
    final bytes = Uint8List.fromList(List.generate(262184, (i) => i % 251));
    final body = Map<String, Object?>.from(f.offer()['body'] as Map)
      ..['cipherBytes'] = bytes.length
      ..['hash'] = CourierSenderJobs.packageHash(0, bytes);
    final stored = await sender.request(
      node,
      kind: 'store',
      body: body,
      upload: bytes,
    );
    expect(stored.control['kind'], 'stored');
    expect((stored.control['body'] as Map)['hash'], body['hash']);
    final list = await recipient.request(
      node,
      kind: 'pickup',
      body: Map<String, Object?>.from(f.pickup(action: 'list')['body'] as Map),
    );
    final items = jsonDecode(utf8.decode(list.bytes!)) as List;
    expect(items, hasLength(1));
    final result = await recipient.request(
      node,
      kind: 'pickup',
      body: {
        ...Map<String, Object?>.from(
          f.pickup(action: 'package')['body'] as Map,
        ),
        'jobKey': items.single['jobKey'],
        'index': 0,
      },
    );
    expect(result.bytes, bytes);
    expect(((result.control['body'] as Map)['package'] as Map?)?['proof'], [
      'f' * 64,
    ]);
    bus.corruptDownload = true;
    await expectLater(
      recipient.request(
        node,
        kind: 'pickup',
        body: {
          ...Map<String, Object?>.from(
            f.pickup(action: 'package')['body'] as Map,
          ),
          'jobKey': items.single['jobKey'],
          'index': 0,
        },
      ),
      throwsFormatException,
    );
    await serving.close();
    await sender.close();
    await recipient.close();
    store.close();
    budget.dispose();
  });
  test('a forged storage ACK never reports success and closed generations cannot resume a request', () async {
    final bus = Bus()..corrupt = true,
        budget = CachePolicy(
          ownerId: host,
          settings: Disk(),
          availableSpace: () async => null,
        );
    await budget.initialize();
    final crypto = Crypto(host, node: f.nodeId),
        store = CourierStore(
          nodeId: f.nodeId,
          journal: CourierJournal(
            ownerId: host,
            namespace: 'courier_host',
            storage: Disk(),
          ),
          crypto: crypto,
          budget: budget,
          clock: () => f.now,
        );
    await store.initialize();
    final serving = CourierTransport(
      ownerId: host,
      crypto: crypto,
      carrier: bus.connect(host),
      clock: () => f.now,
    );
    await serving.startHost(
      nodeState: 'protected',
      certificate: {'nodeId': f.nodeId, 'ownerId': host},
      store: store,
    );
    final sender = CourierTransport(
      ownerId: f.sender,
      crypto: Crypto(f.sender),
      carrier: bus.connect(f.sender),
      clock: () => f.now,
      timeout: const Duration(milliseconds: 300),
    );
    final node = CourierNode.verified(
      nodeId: f.nodeId,
      ownerId: host,
      certificate: {'nodeId': f.nodeId, 'ownerId': host},
      routes: ['wss://relay.example.com/cht'],
      expiresAt: f.now + f.day,
      freeBytes: 1024 * 1024 * 1024,
    );
    await expectLater(
      sender.request(
        node,
        kind: 'store',
        body: Map<String, Object?>.from(f.offer()['body'] as Map),
        upload: f.cipher,
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(bus.lastStored, isNotNull);
    await sender.close();
    await expectLater(
      sender.request(node, kind: 'pickup', body: {}),
      throwsStateError,
    );
    await serving.close();
    store.close();
    budget.dispose();
  });
}
