import 'package:cht/contact_requests/contact_request_controller.dart';
import 'package:cht/contact_requests/relay_contact_request_transport.dart';
import 'package:cht/relay/relay_network.dart';
import 'package:flutter_test/flutter_test.dart';

import '../relay/relay_network_test.dart' as relay;
import 'contact_request_controller_test.dart' as requests;

class _WireCrypto extends requests.Crypto {
  _WireCrypto(super.account);
  var _sequence = 0;

  @override
  Future<Map<String, Object?>> contactRequestCall(
    String operation,
    Map<String, Object?> args,
  ) async {
    final result = await super.contactRequestCall(operation, args);
    if (operation == 'seal') {
      final envelope = result['envelope']! as Map<String, Object?>;
      final session = args['requestId']! as String;
      final kind = args['kind']! as String;
      final suffix = (++_sequence).toRadixString(16).padLeft(32, '0');
      envelope.addAll({
        'version': 2,
        'topic': 'contacts',
        'session': session,
        'id': 'cht-contact-request-v1-$session-$kind-$suffix',
        'expiresAt': 121000,
      });
    }
    return result;
  }
}

ContactRequestController _controller(
  requests.Account account,
  requests.Blobs store,
) => ContactRequestController(
  ownerId: account.owner,
  account: account,
  crypto: _WireCrypto(account),
  blobs: store,
  displayName: () => 'Synthetic contact',
  retryEvery: Duration.zero,
  clock: () => 1000,
  idFactory: () => 'a' * 32,
);

void main() {
  test('saved pending request reaches Review over data relay without reciprocal scan', () async {
    final hub = relay.Hub(relay.a, 'relay-a');
    final alice = requests.Account(requests.alice);
    final bob = requests.Account(requests.bob);
    await alice.addContact(requests.card(requests.bob), 'Stored alias');
    await alice.markContactVerified(requests.bob);
    final senderStore = requests.Blobs();
    var sending = _controller(alice, senderStore);
    final receiving = _controller(bob, requests.Blobs());
    final senderNetwork = RelayNetwork(
      relay.Crypto(alice.owner),
      connector: hub.connect,
    );
    final receiverNetwork = RelayNetwork(
      relay.Crypto(bob.owner),
      connector: hub.connect,
    );
    // The sender's Seed can register, yet the recipient has no Seed route.
    final seed = requests.Transport(alice.owner);
    final outbound = RelayContactRequestTransport(
      ownerId: alice.owner,
      network: senderNetwork,
      seed: seed,
    );
    final inbound = RelayContactRequestTransport(
      ownerId: bob.owner,
      network: receiverNetwork,
    );
    try {
      await sending.initialize();
      sending.attach(seed);
      await sending.request(bob.owner);
      expect(sending.statusFor(bob.owner), ContactRequestStatus.pending);
      expect(receiving.incoming, isEmpty);
      await sending.close();
      sending = _controller(alice, senderStore);
      await receiving.initialize();
      await sending.initialize();
      receiving.attach(inbound);
      await receiverNetwork.addSeed(relay.a);
      await relay.until(() => receiverNetwork.online.contains(relay.a));
      await senderNetwork.addSeed(relay.a);
      await relay.until(() => senderNetwork.online.contains(relay.a));
      sending.attach(outbound);
      await relay.until(() => receiving.incoming.isNotEmpty);
      expect(await bob.contacts(), isEmpty);
      await relay.until(
        () => sending.statusFor(bob.owner) == ContactRequestStatus.received,
      );
      final contact = await receiving.accept(
        receiving.incoming.single.id,
        alias: 'Reviewed sender',
      );
      expect(contact.verified, isTrue);
      await relay.until(() => sending.statusFor(bob.owner) == null);
      expect((await alice.contacts()).single.alias, 'Stored alias');
      expect((await bob.contacts()).single.alias, 'Reviewed sender');
      expect(receiving.incoming, isEmpty);
    } finally {
      await sending.close();
      await receiving.close();
      await outbound.close();
      await inbound.close();
      await seed.close();
      await senderNetwork.close();
      await receiverNetwork.close();
    }
  });
}
