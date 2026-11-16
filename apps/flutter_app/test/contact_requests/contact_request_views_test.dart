import 'package:cht/contact_requests/contact_request_views.dart';
import 'package:cht/account/contacts_page.dart';
import 'package:cht/profile/profile_store.dart';
import 'package:cht/profile/profile_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'contact_request_controller_test.dart' as f;

class _ProfileStore implements ProfileStore {
  @override
  Future<StoredProfile> load() async =>
      const StoredProfile(name: 'Synthetic user');
  @override
  Future<void> save(StoredProfile value) async {}
}

Future<void> _finish(WidgetTester tester, List<Future<void>> futures) async {
  var done = 0;
  Object? error;
  for (final future in futures) {
    future.then<void>(
      (_) {
        done++;
      },
      onError: (Object e, StackTrace _) {
        error ??= e;
        done++;
      },
    );
  }
  // Subscription cancellation and widget work may complete in different zones.
  for (var i = 0; i < 40 && done < futures.length; i++) {
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }
  expect(error, isNull);
  expect(done, futures.length);
}

void main() {
  testWidgets(
    'Add friend confirms the signed identity and queues a reciprocal request',
    (tester) async {
      final account = f.Account(f.alice),
          store = f.Blobs(),
          profile = ProfileController(_ProfileStore());
      final requests = f.controller(account, store);
      await requests.initialize();
      await profile.load();
      var opened = false;
      await tester.pumpWidget(
        MaterialApp(
          home: ContactsPage(
            bridge: account,
            identity: await account.identity(),
            onChat: (_) => opened = true,
            profileController: profile,
            requests: requests,
            readQrImage: () async => f.card(f.bob),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('import-friend-qr-image')),
      );
      await tester.tap(find.byKey(const Key('import-friend-qr-image')));
      await tester.pumpAndSettle();
      expect(find.byType(CheckboxListTile), findsNothing);
      await tester.tap(find.byKey(const Key('confirm-add-friend')));
      await tester.pumpAndSettle();
      expect(account.saved[f.bob]!.verified, isTrue);
      expect(requests.statusFor(f.bob), isNotNull);
      expect(opened, isTrue);
      await tester.pumpWidget(const SizedBox());
      await _finish(tester, [requests.close()]);
      profile.dispose();
    },
  );
  for (final accept in [true, false]) {
    testWidgets(
      'recipient Reviews before ${accept ? 'accepting' : 'declining'} a one-sided request',
      (tester) async {
        final a = f.Account(f.alice),
            b = f.Account(f.bob),
            sa = f.Blobs(),
            sb = f.Blobs();
        await a.addContact(f.card(f.bob), '');
        await a.markContactVerified(f.bob);
        final ca = f.controller(a, sa),
            cb = f.controller(b, sb),
            ta = f.Transport(f.alice),
            tb = f.Transport(f.bob);
        ta.peer = tb;
        tb.peer = ta;
        await ca.initialize();
        await cb.initialize();
        ca.attach(ta);
        cb.attach(tb);
        await ca.request(f.bob);
        await tester.pump();
        var opened = false;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: FriendRequestsSection(
                controller: cb,
                onAccepted: (_) => opened = true,
              ),
            ),
          ),
        );
        expect(b.saved, isEmpty);
        expect(find.text('Review'), findsOneWidget);
        await tester.tap(find.text('Review'));
        await tester.pumpAndSettle();
        expect(find.text('Synthetic fingerprint'), findsOneWidget);
        expect(b.saved, isEmpty);
        if (accept) {
          await tester.enterText(
            find.byKey(const Key('request-alias-input')),
            'My Alice',
          );
        }
        await tester.tap(find.text(accept ? 'Accept' : 'Decline'));
        await tester.pumpAndSettle();
        await tester.pumpAndSettle();
        expect(find.text('Review'), findsNothing);
        expect(opened, accept);
        if (accept) {
          expect(b.saved[f.alice]!.verified, isTrue);
          expect(b.saved[f.alice]!.displayName, 'My Alice');
        } else {
          expect(b.saved, isEmpty);
        }
        await tester.pumpWidget(const SizedBox());
        await _finish(tester, [ca.close(), cb.close()]);
        await _finish(tester, [ta.close(), tb.close()]);
      },
    );
  }
}
