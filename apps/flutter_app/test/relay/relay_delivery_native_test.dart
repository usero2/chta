// Opt-in: real native crypto and native Dart WSS via a disposable public relay.
import 'dart:io';

import 'package:cht/relay/relay_chat.dart';
import 'package:cht/relay/relay_network.dart';
import 'package:cht/relay/relay_socket.dart';
import 'package:cht/seed/seed_client.dart';
import 'package:flutter_test/flutter_test.dart';

import '../groups/group_native_relay_test.dart' show until;
import '../support/native_account_worker.dart';

void main() {
  final dll = Platform.environment['CHTA_GROUP_CORE_DLL'];
  final endpoint = Platform.environment['CHTA_DELIVERY_PUBLIC_RELAY'];
  test(
    'native public relay delivers retries and recovers recipient socket loss',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'chta-public-delivery-qa-',
      );
      final resolved = await root.resolveSymbolicLinks();
      final accounts = <NativeAccountWorker>[],
          networks = <RelayNetwork>[],
          chats = <RelayChat>[],
          seeds = <SeedClient>[];
      final ids = <String>[], cards = <String>[];
      Future<RelaySocket> connectOnlyTestRelay(String url) => url == endpoint
          ? openRelaySocket(url)
          : Future.error(
              const SocketException(
                'Only the disposable data relay is enabled in this proof',
              ),
            );
      var phase = 'initializing';
      try {
        for (final name in ['sender', 'recipient']) {
          final directory = await Directory('${root.path}/$name').create();
          final process = await Process.start(
            Platform.environment['PYTHON'] ?? 'python.exe',
            [
              '${Directory.current.parent.parent.path}/scripts/check_group_native.py',
              '--worker',
              dll!,
            ],
            environment: {
              'APPDATA': directory.path,
              'LOCALAPPDATA': directory.path,
            },
          );
          process.stderr.drain<void>();
          final account = NativeAccountWorker(process);
          accounts.add(account);
          final pending = await account.call('createIdentity') as Map;
          final identity = await account.call('confirmRecovery', {
            'phrase': pending['mnemonic'],
          }) as Map;
          ids.add(identity['id'] as String);
          cards.add(await account.contactCard(displayName: 'Synthetic $name'));
        }
        for (var i = 0; i < 2; i++) {
          final account = accounts[i], other = 1 - i;
          await account.call('addContact', {
            'cardJson': cards[other],
            'displayName': 'Synthetic peer',
          });
          await account.call('markContactVerified', {'identityId': ids[other]});
          final network = RelayNetwork(
            account,
            connector: connectOnlyTestRelay,
          );
          networks.add(network);
          await network.initialize();
          final seed = SeedClient(
            account: account,
            relayCrypto: account,
            signalCrypto: account,
            network: network,
          );
          seeds.add(seed);
          await seed.start(ids[i]);
          final chat = RelayChat(
            account,
            network,
            ownCard: () async => cards[i],
          );
          chats.add(chat);
          await network.addSeed(endpoint!);
          chat.select(ids[other]);
        }
        phase = 'public registration and Noise handshake';
        // A new Quick Tunnel may need time for public DNS and edge routing.
        final discoveryDeadline = DateTime.now().add(
          const Duration(seconds: 90),
        );
        while ((!seeds.every((s) => s.registered) ||
                !chats.every((c) => c.authenticated)) &&
            DateTime.now().isBefore(discoveryDeadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        await until(
          () =>
              seeds.every((s) => s.registered) &&
              chats.every((c) => c.authenticated),
        );
        expect(networks.every((n) => n.activeEndpoint == endpoint), isTrue);
        for (var i = 0; i < 12; i++) {
          phase = 'message $i';
          final from = i % 2, to = 1 - from, id = 'native-public-$i';
          await chats[from].sendMessage(
            id,
            'Synthetic encrypted probe $i',
            1000 + i,
          );
          await until(
            () => chats[to].events.any(
              (e) => e.type == 'message' && e.messageId == id,
            ),
          );
          if (i == 0) {
            chats[to].drainEvents();
            // Omit one ACK. The native core marks the retransmission duplicate.
            await until(
              () => chats[to].events.any(
                (e) => e.type == 'message' && e.messageId == id,
              ),
            );
          }
          await chats[to].acknowledge(id, 2000 + i);
          await until(
            () => chats[from].events.any(
              (e) => e.type == 'delivered' && e.messageId == id,
            ),
          );
          chats[from].drainEvents();
          chats[to].drainEvents();
        }
        final from = 0, to = 1;
        phase = 'recipient disconnect';
        await seeds[to].close();
        seeds.removeAt(to);
        await chats[to].close();
        chats.removeAt(to);
        networks.removeAt(to);
        await chats[from].sendMessage(
          'after-disconnect',
          'Synthetic retry across reconnect',
          3000,
        );
        await until(() => !chats[from].authenticated);
        phase = 'recipient reconnect';
        final network = RelayNetwork(
          accounts[to],
          connector: connectOnlyTestRelay,
        );
        networks.add(network);
        await network.initialize();
        final recipient = RelayChat(
          accounts[to],
          network,
          ownCard: () async => cards[to],
        );
        chats.add(recipient);
        await network.addSeed(endpoint!);
        recipient.select(ids[from]);
        await until(() => chats.every((c) => c.authenticated));
        await until(
          () => recipient.events.any(
            (e) => e.type == 'message' && e.messageId == 'after-disconnect',
          ),
        );
        await recipient.acknowledge('after-disconnect', 4000);
        await until(
          () => chats[from].events.any(
            (e) => e.type == 'delivered' && e.messageId == 'after-disconnect',
          ),
        );
      } catch (error) {
        fail(
          'Public proof failed at $phase: $error; seed=${seeds.map((s) => s.status).toList()}, '
          'relays=${networks.map((n) => n.online.length).toList()}, '
          'errors=${networks.map((n) => n.error).toList()}, chats=${chats.map((c) => c.state).toList()}',
        );
      } finally {
        for (final seed in seeds) {
          await seed.close();
        }
        for (final chat in chats) {
          await chat.close();
        }
        for (final account in accounts) {
          await account.close();
        }
        if (await root.exists() &&
            await root.resolveSymbolicLinks() == resolved &&
            root.parent.absolute.path == Directory.systemTemp.absolute.path &&
            root.path.contains('chta-public-delivery-qa-')) {
          await root.delete(recursive: true);
        }
      }
    },
    skip: !Platform.isWindows || dll == null || endpoint == null
        ? 'Set native core DLL and disposable public relay for WSS proof'
        : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
