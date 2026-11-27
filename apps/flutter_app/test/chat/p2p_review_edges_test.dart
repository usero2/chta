import 'dart:async';
import 'dart:typed_data';

import 'package:cht/chat/chat_attachment.dart';
import 'package:cht/chat/messaging_service.dart';
import 'package:cht/chat/peer_history.dart';
import 'package:cht/relay/relay_network.dart';
import 'package:flutter_test/flutter_test.dart';

import '../relay/relay_network_test.dart' as f;
import '../groups/swarm_test.dart' show Attachments;
import 'messaging_service_test.dart' show Account;
import 'durable_outbox_test.dart' show Store;

class GatedAccount extends Account {
  GatedAccount() : super('alice', ['bob']);
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<Map<String, Object?>> groupCall(
    String op,
    Map<String, Object?> args,
  ) async {
    if (op == 'encrypt' && args['text'].toString().contains('CHT_ATTACHMENT')) {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    }
    return super.groupCall(op, args);
  }
}

void main() {
  for (final cancelDuringEncryption in [false, true]) {
    test(
      cancelDuringEncryption
          ? 'cancel during relay encryption stops file and text recovers'
          : 'permanent legacy validation ends durable retry intent',
      () async {
        final hub = f.Hub(f.a, 'relay-a'), gated = GatedAccount();
        final histories = <PeerHistory>[], services = <MessagingService>[];
        try {
          for (var i = 0; i < 2; i++) {
            final owner = i == 0 ? 'alice' : 'bob',
                peer = i == 0 ? 'bob' : 'alice';
            final h = PeerHistory(store: Store(), attachments: Attachments());
            await h.load(owner);
            histories.add(h);
            final net = RelayNetwork(f.Crypto(owner), connector: hub.connect);
            await net.addSeed(f.a);
            final service = MessagingService(
              ownerId: owner,
              account: i == 0 && cancelDuringEncryption
                  ? gated
                  : Account(owner, [peer]),
              network: net,
              history: h,
              ownCard: () async => owner,
              observeNetwork: false,
            );
            services.add(service);
            await service.start();
          }
          await f.until(() => services.every((s) => s.onlinePeers.isNotEmpty));
          final message = PeerMessage(
            id: cancelDuringEncryption
                ? 'cancel-queued-file'
                : 'invalid!transfer',
            text: 'file',
            incoming: false,
            status: DeliveryStatus.pending,
            attachment: ChatAttachment(
              name: 'fixture.bin',
              mimeType: 'application/octet-stream',
              bytes: Uint8List(16),
            ),
          );
          await services.first.queueMessage('bob', message);
          if (cancelDuringEncryption) {
            await f.until(
              () =>
                  histories.last.fileOfferFor(
                    'alice',
                    message.id,
                    incoming: true,
                  ) !=
                  null,
            );
            await services.last.respondToFileOffer(
              'alice',
              message.id,
              accept: true,
            );
            await gated.entered.future.timeout(const Duration(seconds: 3));
            await services.first.cancelFile('bob', message.id);
            gated.release.complete();
            await Future<void>.delayed(const Duration(milliseconds: 200));
            expect(histories.last.messageById('alice', message.id), isNull);
            await services.first.queueText(
              'bob',
              'text after cancel',
              id: 'after-cancel',
            );
            await f.until(
              () => histories.last
                  .messagesFor('alice')
                  .any((m) => m.id == 'after-cancel'),
            );
          } else {
            await Future<void>.delayed(const Duration(milliseconds: 200));
            expect(message.queuedForDelivery, isFalse);
            expect(message.status, DeliveryStatus.failed);
            expect(message.failureReason, contains('Invalid transfer ID'));
          }
        } finally {
          if (!gated.release.isCompleted) gated.release.complete();
          for (final s in services) {
            await s.close();
          }
          for (final h in histories) {
            h.dispose();
          }
        }
      },
    );
  }
}
