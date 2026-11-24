import 'package:cht/relay/relay_chat.dart';
import 'package:cht/relay/relay_network.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:async';

import 'relay_network_test.dart' as f;

class _GatedAccount extends f.SessionAccount {
  _GatedAccount():super('alice','bob');
  Completer<void>? gate,entered;
  @override Future<Map<String,Object?>> groupCall(String operation,Map<String,Object?> args)async {
    if(operation=='encrypt'&&gate!=null){if(entered?.isCompleted==false)entered!.complete();await gate!.future;}
    return super.groupCall(operation,args);
  }
}

void main() {
  test('closing settles queued sends so an outbox lane can be reused',()async {
    final hub=f.Hub(f.a,'relay-a'),account=_GatedAccount();
    final left=RelayNetwork(f.Crypto('alice'),connector:hub.connect),right=RelayNetwork(f.Crypto('bob'),connector:hub.connect);
    final alice=RelayChat(account,left,ownCard:()async=>'alice'),bob=RelayChat(f.SessionAccount('bob','alice'),right,ownCard:()async=>'bob');
    try {
      for(final n in [left,right]){await n.initialize();await n.addSeed(f.a);}alice.select('bob');bob.select('alice');await f.until(()=>alice.authenticated&&bob.authenticated);
      account.entered=Completer<void>();account.gate=Completer<void>();
      final first=alice.sendMessage('blocked','first',1);final firstError=expectLater(first,throwsA(anything));
      await account.entered!.future;
      final second=alice.sendMessage('queued','second',2);
      final outcome=second.then((_)=>'sent',onError:(Object _)=>'cancelled');
      await alice.close();account.gate!.complete();await firstError;
      expect(await outcome.timeout(const Duration(milliseconds:300),onTimeout:()=>'hung'),'cancelled');
    }finally{await alice.close();await bob.close();}
  });
  test(
    'two sessions share a network without stealing frames or teardown',
    () async {
      final hub = f.Hub(f.a, 'relay-a');
      final net = RelayNetwork(f.Crypto('alice'), connector: hub.connect);
      final bn = RelayNetwork(f.Crypto('bob'), connector: hub.connect);
      final cn = RelayNetwork(f.Crypto('carol'), connector: hub.connect);
      final ab = RelayChat(
        f.SessionAccount('alice', 'bob'),
        net,
        ownCard: () async => 'alice',
        ownsNetwork: false,
        boundPeer: 'bob',
      );
      final ac = RelayChat(
        f.SessionAccount('alice', 'carol'),
        net,
        ownCard: () async => 'alice',
        ownsNetwork: false,
        boundPeer: 'carol',
      );
      final ba = RelayChat(
        f.SessionAccount('bob', 'alice'),
        bn,
        ownCard: () async => 'bob',
      );
      final ca = RelayChat(
        f.SessionAccount('carol', 'alice'),
        cn,
        ownCard: () async => 'carol',
      );
      try {
        for (final n in [net, bn, cn]) {
          await n.initialize();
          await n.addSeed(f.a);
        }
        ab.select('bob');
        ac.select('carol');
        ba.select('alice');
        ca.select('alice');
        await f.until(
          () =>
              ab.authenticated &&
              ac.authenticated &&
              ba.authenticated &&
              ca.authenticated,
        );
        await ba.sendMessage('from-bob', 'b', 1);
        await ca.sendMessage('from-carol', 'c', 2);
        await f.until(
          () =>
              ab.events.any((e) => e.messageId == 'from-bob') &&
              ac.events.any((e) => e.messageId == 'from-carol'),
        );
        expect(ab.events.any((e) => e.messageId == 'from-carol'), false);
        await ab.close();
        expect(net.online, [f.a]);
        await ca.sendMessage('after-close', 'still connected', 3);
        await f.until(() => ac.events.any((e) => e.messageId == 'after-close'));
      } finally {
        await ab.close();
        await ac.close();
        await ba.close();
        await ca.close();
        await net.close();
      }
    },
  );
}
