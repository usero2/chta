import 'package:cht/account/account_models.dart';
import 'package:cht/chat/cache_policy.dart';
import 'package:cht/chat/peer_history.dart';
import 'package:cht/chat/messaging_service.dart';
import 'package:cht/courier/courier_service.dart';
import 'package:cht/courier/courier_models.dart';
import 'package:cht/delivery/courier_delivery_adapter.dart';
import 'package:cht/delivery/delivery_envelope.dart';
import 'package:cht/relay/relay_network.dart';
import 'package:flutter_test/flutter_test.dart';

import '../courier/courier_builder_test.dart' as builder;
import '../courier/courier_directory_test.dart' as directory;
import '../courier/courier_journal_test.dart' show Disk;
import '../courier/courier_transport_test.dart' as wire;
import '../relay/relay_network_test.dart' as relay;
import 'peer_delivery_sink_test.dart' show MemoryHistory;
import '../chat/messaging_service_test.dart' as messaging;

import 'package:cht/groups/group_controller.dart';

import '../groups/group_controller_test.dart' as group;
import '../groups/swarm_test.dart' as swarm;

class Account extends messaging.Account {
  Account(super.id, super.peers);
  @override
  Future<ContactView> inspectContactCard(String source) async => ContactView(
    identityId: source,
    displayName: 'Friend',
    fingerprint: 'verified',
    verified: true,
    capabilities: ['peer-sessions-v2', 'files-v2', 'delivery-v2', 'courier-v1'],
  );
}

class Crypto extends builder.Crypto {
  String job = '';
  int expiry = 0;
  int signs = 0;
  @override
  Future<Map<String, Object?>> deliveryCall(
    String op,
    Map<String, Object?> args,
  ) async {
    if (op == 'verifyControl') {
      return directory.Crypto().deliveryCall(op, args);
    }
    if (op == 'newJob') {
      job = args['jobId'] as String;
      expiry = args['expiresAt'] as int;
    }
    if (op == 'signEvent') signs++;
    final result = await super.deliveryCall(op, args);
    if (op == 'newJob') result['bucket'] = (args['now'] as int) ~/ 86400000;
    if (op == 'sealManifest') {
      (result['manifest'] as Map)['jobId'] = job;
      (result['manifest'] as Map)['expiresAt'] = expiry;
    }
    return result;
  }
}

void main() {
  test(
    'a prepared job is cancelled if its contact is removed before deposit',
    () async {
      final owner = group.owner,
          peer = group.friend,
          history = PeerHistory(store: MemoryHistory());
      await history.load(owner);
      final budget = CachePolicy(
            ownerId: owner,
            settings: Disk(),
            availableSpace: () async => null,
          ),
          network = RelayNetwork(relay.Crypto(owner));
      final service = CourierService(
        ownerId: owner,
        crypto: Crypto(),
        storage: Disk(),
        budget: budget,
        network: network,
        carrier: wire.Bus().connect(owner),
        clock: () => 2000,
      );
      final contacts = [
        ContactView(
          identityId: peer,
          displayName: 'Friend',
          fingerprint: 'verified',
          verified: true,
          capabilities: ['courier-v1'],
        ),
      ];
      final adapter = CourierDeliveryAdapter(
        service: service,
        history: history,
        contacts: () => contacts,
        automatic: false,
        clock: () => 2000,
      );
      await adapter.start();
      final message = PeerMessage(
        id: 'contact-removed',
        text: 'hello',
        incoming: false,
        status: DeliveryStatus.pending,
        sentAtMilliseconds: 1000,
        queuedForDelivery: true,
      );
      history.add(peer, message);
      await adapter.queue(peer, message);
      await adapter.settlePreparations();
      expect(
        service.jobs.find(message.courierJobId!)!.status,
        CourierJobStatus.waitingForNodes,
      );
      contacts.clear();
      await adapter.pump();
      expect(
        service.jobs.find(message.courierJobId!)!.status,
        CourierJobStatus.cancelled,
      );
      await adapter.close();
      await network.close();
      budget.dispose();
      history.dispose();
    },
  );
  test('upgraded friends can still receive near-limit relay text without an oversized envelope', () async {
    final owner = group.owner,
        peer = group.friend,
        history = PeerHistory(store: MemoryHistory());
    await history.load(owner);
    final budget = CachePolicy(
          ownerId: owner,
          settings: Disk(),
          availableSpace: () async => null,
        ),
        network = RelayNetwork(relay.Crypto(owner));
    final service = CourierService(
      ownerId: owner,
      crypto: Crypto(),
      storage: Disk(),
      budget: budget,
      network: network,
      carrier: wire.Bus().connect(owner),
    );
    final adapter = CourierDeliveryAdapter(
      service: service,
      history: history,
      contacts: () => [
        ContactView(
          identityId: peer,
          displayName: 'Friend',
          fingerprint: 'verified',
          verified: true,
          capabilities: ['delivery-v2'],
        ),
      ],
      automatic: false,
    );
    await adapter.start();
    for (final text in ['x' * 12000, '"' * 11000]) {
      final message = PeerMessage(
        id: 'long-${text.length}',
        text: text,
        incoming: false,
        status: DeliveryStatus.pending,
        queuedForDelivery: true,
      );
      history.add(peer, message);
      expect(await adapter.liveText(peer, message), text);
      expect(message.deliveryEnvelope, isNotNull);
    }
    await adapter.close();
    await network.close();
    budget.dispose();
    history.dispose();
  });
  test('offline group scanning visits one history page per pass and reaches later pending messages', () async {
    final owner = group.owner,
        peer = group.friend,
        history = PeerHistory(store: MemoryHistory());
    await history.load(owner);
    final budget = CachePolicy(
      ownerId: owner,
      settings: Disk(),
      availableSpace: () async => null,
    );
    await budget.initialize();
    final network = RelayNetwork(relay.Crypto(owner));
    final controller = GroupController(
      ownerId: owner,
      crypto: group.ModelCrypto()..includeFriend = true,
      blobs: swarm.Blobs(),
      attachments: swarm.Attachments(),
      displayName: () => 'Alice',
    );
    await controller.initialize();
    await controller.createGroup('Team', []);
    for (var i = 0; i < 40; i++) {
      await controller.sendText(group.gid, 'message $i');
      if (i < 39) controller.messagesFor(group.gid).last.receipts[peer] = 2000;
    }
    final service = CourierService(
          ownerId: owner,
          crypto: Crypto(),
          storage: Disk(),
          budget: budget,
          network: network,
          carrier: wire.Bus().connect(owner),
          clock: () => 2000000000000,
        ),
        adapter = CourierDeliveryAdapter(
          service: service,
          history: history,
          contacts: () => [
            ContactView(
              identityId: peer,
              displayName: 'Friend',
              fingerprint: 'verified',
              verified: true,
              capabilities: ['courier-v1'],
            ),
          ],
          automatic: false,
          clock: () => 2000000000000,
        );
    await adapter.start();
    adapter.attachGroups(controller);
    await adapter.pump();
    await adapter.settlePreparations();
    expect(service.jobs.jobs, isEmpty);
    await adapter.pump();
    await adapter.settlePreparations();
    expect(
      service.jobs.jobs.single.messageId,
      controller.messagesFor(group.gid).last.id,
    );
    await adapter.close();
    await controller.close();
    await network.close();
    budget.dispose();
    history.dispose();
  });
  test('group messages queue one recipient-bound Courier job and restore its protected envelope and job mapping', () async {
    final owner = group.owner,
        peer = group.friend,
        history = PeerHistory(store: MemoryHistory());
    await history.load(owner);
    final budget = CachePolicy(
      ownerId: owner,
      settings: Disk(),
      availableSpace: () async => null,
    );
    await budget.initialize();
    final network = RelayNetwork(relay.Crypto(owner)),
        disk = Disk(),
        blobs = swarm.Blobs();
    final core = group.ModelCrypto()..includeFriend = true;
    final controller = GroupController(
      ownerId: owner,
      crypto: core,
      blobs: blobs,
      attachments: swarm.Attachments(),
      displayName: () => 'Alice',
    );
    await controller.initialize();
    await controller.createGroup('Team', []);
    await controller.sendText(group.gid, 'group hello');
    final service = CourierService(
      ownerId: owner,
      crypto: Crypto(),
      storage: disk,
      budget: budget,
      network: network,
      carrier: wire.Bus().connect(owner),
      clock: () => 2000000000000,
    );
    final adapter = CourierDeliveryAdapter(
      service: service,
      history: history,
      contacts: () => [
        ContactView(
          identityId: peer,
          displayName: 'Friend',
          fingerprint: 'verified',
          verified: true,
          capabilities: ['courier-v1'],
        ),
      ],
      automatic: false,
      clock: () => 2000000000000,
    );
    await adapter.start();
    adapter.attachGroups(controller);
    await adapter.pump();
    await adapter.settlePreparations();
    final m = controller.messagesFor(group.gid).single;
    expect(m.deliveryEnvelope, isNotNull);
    expect(m.courierJobs.keys, [peer]);
    expect(service.jobs.jobs, hasLength(1));
    expect(service.jobs.jobs.single.scope, '${group.gid}:1');
    expect(service.jobs.jobs.single.status, CourierJobStatus.waitingForNodes);
    final jobId = m.courierJobs[peer];
    await adapter.pump();
    await adapter.settlePreparations();
    expect(m.courierJobs[peer], jobId);
    await adapter.close();
    await controller.close();
    await network.close();
    budget.dispose();
    history.dispose();
  });
  final owner = 'did:cht:${'a' * 64}', peer = 'did:cht:${'b' * 64}';
  ContactView contact({bool supported = true}) => ContactView(
    identityId: peer,
    displayName: 'Friend',
    fingerprint: 'verified',
    verified: true,
    capabilities: supported ? ['delivery-v2', 'courier-v1'] : [],
  );
  test('the account outbox starts Courier only when two other identities are reachable', () async {
    final history = PeerHistory(store: MemoryHistory());
    await history.load(owner);
    final budget = CachePolicy(
      ownerId: owner,
      settings: Disk(),
      availableSpace: () async => null,
    );
    await budget.initialize();
    final network = RelayNetwork(relay.Crypto(owner)),
        account = Account(owner, [peer]);
    final courier = CourierService(
      ownerId: owner,
      crypto: Crypto(),
      storage: Disk(),
      budget: budget,
      network: network,
      carrier: wire.Bus().connect(owner),
      clock: () => 2000,
    );
    final adapter = CourierDeliveryAdapter(
      service: courier,
      history: history,
      contacts: () => [contact()],
      clock: () => 2000,
      automatic: false,
    );
    final service = MessagingService(
      ownerId: owner,
      account: account,
      network: network,
      history: history,
      ownCard: () async => owner,
      observeNetwork: false,
      courier: adapter,
    );
    await service.start();
    await service.queueMessage(
      peer,
      PeerMessage(
        id: 'offline-outbox',
        text: 'offline hello',
        incoming: false,
        status: DeliveryStatus.pending,
        sentAtMilliseconds: 1000,
      ),
    );
    expect(service.canDepositOffline(peer), isFalse);
    await adapter.settlePreparations();
    expect(courier.jobs.jobs, isEmpty);
    expect(history.messagesFor(peer).single.queuedForDelivery, isTrue);
    expect(history.messagesFor(peer).single.status, DeliveryStatus.pending);
    final firstOwner = 'did:cht:${'c' * 64}';
    await courier.directory.merge([
      directory.ad('1' * 64, owner: firstOwner),
      directory.ad('2' * 64, owner: firstOwner),
      directory.ad('3' * 64, owner: peer),
    ]);
    await service.reconnect(peer);
    expect(courier.depositRootCount(peer), 1);
    expect(service.canDepositOffline(peer), isFalse);
    expect(courier.jobs.jobs, isEmpty);
    await courier.directory.merge([
      directory.ad('4' * 64, owner: 'did:cht:${'d' * 64}'),
    ]);
    expect(service.canDepositOffline(peer), isTrue);
    await service.reconnect(peer);
    await relay.until(
      () => history.messagesFor(peer).single.courierJobId != null,
    );
    await adapter.settlePreparations();
    expect(courier.jobs.jobs.single.status, CourierJobStatus.depositing);
    expect(history.messagesFor(peer).single.status, DeliveryStatus.pending);
    await service.close();
    expect(courier.ready, isFalse);
    history.dispose();
    budget.dispose();
  });
  test('offline queue persists one author envelope and job, waits for two nodes and survives adapter restart without claiming delivery', () async {
    final disk = Disk(),
        settings = Disk(),
        store = MemoryHistory(),
        crypto = Crypto(),
        history = PeerHistory(store: store);
    await history.load(owner);
    final budget = CachePolicy(
      ownerId: owner,
      settings: settings,
      availableSpace: () async => null,
    );
    await budget.initialize();
    final network = RelayNetwork(relay.Crypto(owner));
    CourierService service() => CourierService(
      ownerId: owner,
      crypto: crypto,
      storage: disk,
      budget: budget,
      network: network,
      carrier: wire.Bus().connect(owner),
      clock: () => 2000,
    );
    var host = service(),
        adapter = CourierDeliveryAdapter(
          service: host,
          history: history,
          contacts: () => [contact()],
          clock: () => 2000,
          automatic: false,
        );
    await adapter.start();
    final message = PeerMessage(
      id: 'original',
      text: 'hello',
      incoming: false,
      status: DeliveryStatus.pending,
      sentAtMilliseconds: 1000,
      queuedForDelivery: true,
    );
    history.add(peer, message);
    await history.flush();
    await Future.wait([
      adapter.queue(peer, message),
      adapter.queue(peer, message),
    ]);
    await adapter.settlePreparations();
    final id = message.courierJobId!, proof = message.deliveryEnvelope;
    expect(crypto.signs, 1);
    expect(host.jobs.jobs, hasLength(1));
    expect(host.jobs.find(id)!.status, CourierJobStatus.waitingForNodes);
    expect(message.status, DeliveryStatus.pending);
    expect(message.receivedAtMilliseconds, isNull);
    await adapter.queue(peer, message);
    await adapter.settlePreparations();
    expect(message.courierJobId, id);
    expect(message.deliveryEnvelope, proof);
    await adapter.close();
    host = service();
    adapter = CourierDeliveryAdapter(
      service: host,
      history: history,
      contacts: () => [contact()],
      clock: () => 2000,
      automatic: false,
    );
    await adapter.start();
    await adapter.queue(peer, message);
    await adapter.settlePreparations();
    expect(host.jobs.jobs, hasLength(1));
    expect(message.courierJobId, id);
    await adapter.delivered(peer, message.id, 3000);
    expect(host.jobs.find(id), isNull);
    expect(message.status, DeliveryStatus.delivered);
    expect(message.receivedAtMilliseconds, 3000);
    await adapter.close();
    await network.close();
    history.dispose();
    budget.dispose();
  });
  test('legacy friends remain live compatible and authenticated v2 copies preserve one receive timestamp', () async {
    final crypto = builder.Crypto(),
        history = PeerHistory(store: MemoryHistory());
    await history.load(peer);
    final budget = CachePolicy(
      ownerId: peer,
      settings: Disk(),
      availableSpace: () async => null,
    );
    await budget.initialize();
    final network = RelayNetwork(relay.Crypto(peer));
    final service = CourierService(
      ownerId: peer,
      crypto: crypto,
      storage: Disk(),
      budget: budget,
      network: network,
      carrier: wire.Bus().connect(peer),
    );
    var supported = false;
    final adapter = CourierDeliveryAdapter(
      service: service,
      history: history,
      contacts: () => [
        ContactView(
          identityId: owner,
          displayName: 'Friend',
          fingerprint: 'verified',
          verified: true,
          capabilities: supported ? ['delivery-v2', 'courier-v1'] : [],
        ),
      ],
      automatic: false,
    );
    await adapter.start();
    expect(adapter.canQueue(owner), isFalse);
    supported = true;
    expect(adapter.canQueue(owner), isTrue);
    final envelope = await DeliveryEnvelope.create(
      crypto,
      scope: directDeliveryScope(owner, peer),
      messageId: 'live-id',
      sentAt: 1000,
      kind: 'text',
      payload: {'text': 'hello'},
    );
    expect(
      await adapter.receiveLive(
        owner,
        'live-id',
        envelope.toWire(),
        1000,
        2000,
      ),
      2000,
    );
    expect(
      await adapter.receiveLive(
        owner,
        'live-id',
        envelope.toWire(),
        1000,
        4000,
      ),
      2000,
    );
    expect(history.messagesFor(owner), hasLength(1));
    await expectLater(
      adapter.receiveLive(owner, 'different', envelope.toWire(), 1000, 5000),
      throwsFormatException,
    );
    await adapter.close();
    await network.close();
    history.dispose();
    budget.dispose();
  });
}
