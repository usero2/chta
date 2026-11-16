// Opt-in proof using actual FFI identities, Noise packets and protected storage.
// Every account and directory is disposable; no user credentials are loaded.
import 'dart:convert';
import 'dart:io';

import 'package:cht/account/account_bridge.dart';
import 'package:cht/account/account_models.dart';
import 'package:cht/contact_requests/contact_request_bridge.dart';
import 'package:cht/contact_requests/contact_request_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../groups/group_native_relay_test.dart' show NativeWorker, until;
import 'contact_request_controller_test.dart' show Transport;

class _Account implements AccountBridge, ContactRequestBridge {
  _Account(this.worker);
  final NativeWorker worker;
  Future<List<ContactView>> _contacts(
    String command,
    Map<String, Object?> args,
  ) async => (await worker.call(command, args) as List)
      .map((c) => ContactView.fromJson(Map<String, Object?>.from(c as Map)))
      .toList();
  @override
  Future<IdentityView> identity() async => IdentityView.fromJson(
    Map<String, Object?>.from(await worker.call('identity') as Map),
  );
  @override
  Future<List<ContactView>> contacts() => _contacts('contacts', {});
  @override
  Future<ContactView> inspectContactCard(String cardJson) async =>
      ContactView.fromJson(
        Map<String, Object?>.from(
          await worker.call('inspectContactCard', {'cardJson': cardJson})
              as Map,
        ),
      );
  @override
  Future<List<ContactView>> addContact(String cardJson, String displayName) =>
      _contacts('addContact', {
        'cardJson': cardJson,
        'displayName': displayName,
      });
  @override
  Future<List<ContactView>> markContactVerified(String identityId) =>
      _contacts('markContactVerified', {'identityId': identityId});
  @override
  Future<Map<String, Object?>> contactRequestCall(
    String operation,
    Map<String, Object?> args,
  ) async => Map<String, Object?>.from(
    await worker.call('contactRequestCall', {
      'operation': operation,
      'args': args,
    }) as Map,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final dll = Platform.environment['CHTA_GROUP_CORE_DLL'];
  test(
    'one-sided native request survives restart, Review grants trust and KK chat works',
    () async {
      final root = await Directory.systemTemp.createTemp('chta-contact-qa-');
      final resolved = await root.resolveSymbolicLinks();
      final repo = Directory.current.parent.parent.path;
      final workers = <NativeWorker>[],
          controllers = <ContactRequestController>[],
          transports = <Transport>[];
      try {
        final ids = <String>[], cards = <String>[];
        for (final name in ['sender', 'recipient']) {
          final directory = await Directory('${root.path}/$name').create();
          final process = await Process.start(
            Platform.environment['PYTHON'] ?? 'python.exe',
            ['$repo/scripts/check_group_native.py', '--worker', dll!],
            environment: {
              'APPDATA': directory.path,
              'LOCALAPPDATA': directory.path,
            },
          );
          process.stderr.drain<void>();
          final worker = NativeWorker(process);
          workers.add(worker);
          final pending = await worker.call('createIdentity') as Map;
          final identity = await worker.call('confirmRecovery', {
            'phrase': pending['mnemonic'],
          }) as Map;
          ids.add(identity['id'] as String);
          cards.add(
            await worker.call('contactCard', {'displayName': 'Synthetic $name'})
                as String,
          );
        }
        final a = _Account(workers[0]), b = _Account(workers[1]);
        await a.addContact(cards[1], 'Local alias');
        await a.markContactVerified(ids[1]);
        expect(await b.contacts(), isEmpty);
        ContactRequestController make(_Account account, int index) {
          final value = ContactRequestController(
            ownerId: ids[index],
            account: account,
            crypto: account,
            blobs: workers[index],
            displayName: () => 'Synthetic ${index + 1}',
            retryEvery: Duration.zero,
          );
          controllers.add(value);
          return value;
        }

        final ca = make(a, 0), ta = Transport(ids[0]), tb = Transport(ids[1]);
        transports.addAll([ta, tb]);
        await ca.initialize();
        ca.attach(ta);
        await ca.request(
          ids[1],
        ); // Local durable outbox while recipient is absent.
        final stableId = ta.sent.single['session'];
        expect(ca.statusFor(ids[1]), ContactRequestStatus.pending);
        var cb = make(b, 1);
        await cb.initialize();
        cb.attach(tb);
        ta.peer = tb;
        tb.peer = ta;
        await ca.pulse(force: true);
        await until(
          () =>
              cb.incoming.length == 1 &&
              ca.statusFor(ids[1]) == ContactRequestStatus.received,
        );
        expect(
          await b.contacts(),
          isEmpty,
          reason: 'Receiving must not authorize a peer',
        );
        expect(ta.sent.last['session'], stableId);
        expect(ta.sent.last['id'], isNot(ta.sent.first['id']));
        final saved = await workers[1].loadGroupBlob(
          ids[1],
          'contact-requests-v1',
        );
        expect(saved, contains('Synthetic 1'));
        for (final file in root.listSync(recursive: true).whereType<File>()) {
          if (file.path.endsWith('.bin')) {
            expect(
              latin1.decode(await file.readAsBytes()),
              isNot(contains('Synthetic 1')),
            );
          }
        }
        await cb.close();
        controllers.remove(cb);
        cb = make(b, 1);
        await cb.initialize();
        cb.attach(tb);
        expect(cb.incoming, hasLength(1));
        tb.peer = null; // Drop the acceptance ACK once.
        final accepted = await cb.accept(
          cb.incoming.single.id,
          alias: 'Reviewed sender',
        );
        expect(accepted.verified, isTrue);
        expect(accepted.alias, 'Reviewed sender');
        tb.peer = ta;
        await ca.pulse(force: true);
        await until(() => ca.statusFor(ids[1]) == null);
        expect(cb.incoming, isEmpty);
        expect((await a.contacts()).single.alias, 'Local alias');
        // Both production trust gates now allow the existing encrypted session.
        await workers[0].call('preparePeer', {
          'cardJson': cards[1],
          'initiator': true,
        });
        await workers[1].call('preparePeer', {
          'cardJson': cards[0],
          'initiator': false,
        });
        final first = await workers[0].call('startPeerHandshake');
        final reply = await workers[1].call('receivePeerHandshake', {
          'frame': first,
        }) as Map;
        await workers[0].call('receivePeerHandshake', {
          'frame': reply['reply'],
        });
        final frame = await workers[0].call('encryptPeerMessage', {
          'messageId': 'qa-request-proof',
          'text': 'Synthetic setup proof',
        });
        final opened = await workers[1].call('decryptPeerMessage', {
          'frame': frame,
        }) as Map;
        expect(opened['text'], 'Synthetic setup proof');
      } finally {
        for (final controller in controllers) {
          await controller.close();
        }
        for (final transport in transports) {
          await transport.close();
        }
        for (final worker in workers) {
          await worker.close();
        }
        // Remove only this proof's own verified temporary directory.
        if (await root.exists() &&
            await root.resolveSymbolicLinks() == resolved &&
            root.parent.absolute.path == Directory.systemTemp.absolute.path &&
            root.path.contains('chta-contact-qa-')) {
          await root.delete(recursive: true);
        }
      }
    },
    skip: !Platform.isWindows || dll == null
        ? 'Set CHTA_GROUP_CORE_DLL for native contact proof'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
