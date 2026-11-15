import 'package:cht/account/account_models.dart';
import 'package:cht/groups/group_dialogs.dart';
import 'package:cht/groups/group_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const own =
    'did:cht:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const friend =
    'did:cht:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const other =
    'did:cht:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
const outsider =
    'did:cht:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';

ContactView contact(String id, String name, {bool verified = true}) =>
    ContactView(
      identityId: id,
      displayName: name,
      fingerprint: 'fingerprint-$name',
      verified: verified,
    );

GroupView group({String owner = own, bool closed = false}) => GroupView(
  groupId:
      'group:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
  name: 'Project Room',
  ownerId: owner,
  epoch: 1,
  closed: closed,
  members: const [
    GroupMember(identityId: own, displayName: 'Owner'),
    GroupMember(identityId: friend, displayName: 'Friend'),
  ],
  states: const [],
);

Future<void> openDialog(
  WidgetTester tester,
  Future<void> Function(BuildContext) open,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => open(context),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('create dialog requires a valid name and one verified friend', (
    tester,
  ) async {
    final contacts = [
      contact(friend, 'Friend'),
      contact(other, 'Other'),
      contact(outsider, 'Unverified', verified: false),
    ];
    (String, List<String>)? result;
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await openDialog(tester, (context) async {
      result = await showCreateGroupDialog(context, contacts);
    });
    expect(find.text('New group'), findsOneWidget);
    expect(find.text('Unverified'), findsNothing);
    expect(find.text('0/15 selected'), findsOneWidget);
    ElevatedButton createButton() => tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, 'Create'),
    );
    expect(createButton().onPressed, isNull);
    await tester.enterText(
      find.byKey(const Key('new-group-name')),
      'Build crew',
    );
    await tester.pump();
    expect(createButton().onPressed, isNull);
    await tester.ensureVisible(
      find.byKey(const Key('create-group-contact:$friend')),
    );
    await tester.tap(find.byKey(const Key('create-group-contact:$friend')));
    await tester.pump();
    expect(find.text('1/15 selected'), findsOneWidget);
    expect(createButton().onPressed, isNotNull);
    await tester.ensureVisible(find.widgetWithText(ElevatedButton, 'Create'));
    await tester.tap(find.widgetWithText(ElevatedButton, 'Create'));
    await tester.pumpAndSettle();
    expect(result?.$1, 'Build crew');
    expect(result?.$2, [friend]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('create group accepts the 64 character name limit', (
    tester,
  ) async {
    (String, List<String>)? result;
    await openDialog(tester, (context) async {
      result = await showCreateGroupDialog(context, [
        contact(friend, 'Friend'),
      ]);
    });
    await tester.enterText(find.byKey(const Key('new-group-name')), 'x' * 64);
    await tester.ensureVisible(
      find.byKey(const Key('create-group-contact:$friend')),
    );
    await tester.tap(find.byKey(const Key('create-group-contact:$friend')));
    await tester.pump();
    await tester.ensureVisible(find.widgetWithText(ElevatedButton, 'Create'));
    await tester.tap(find.widgetWithText(ElevatedButton, 'Create'));
    await tester.pumpAndSettle();
    expect(result?.$1, 'x' * 64);
  });

  testWidgets('create group counts Unicode characters toward the name limit', (
    tester,
  ) async {
    (String, List<String>)? result;
    await openDialog(tester, (context) async {
      result = await showCreateGroupDialog(context, [
        contact(friend, 'Friend'),
      ]);
    });
    final name = List.filled(64, '😀').join();
    await tester.enterText(find.byKey(const Key('new-group-name')), name);
    await tester.tap(find.byKey(const Key('create-group-contact:$friend')));
    await tester.pump();
    final button = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, 'Create'),
    );
    expect(button.onPressed, isNotNull);
    await tester.tap(find.widgetWithText(ElevatedButton, 'Create'));
    await tester.pumpAndSettle();
    expect(result?.$1, name);
  });

  testWidgets('create dialog caps selection at fifteen verified friends', (
    tester,
  ) async {
    final contacts = List.generate(
      16,
      (index) => contact(
        'did:cht:${index.toRadixString(16).padLeft(64, '0')}',
        'Friend $index',
      ),
    );
    await openDialog(tester, (context) async {
      await showCreateGroupDialog(context, contacts);
    });
    await tester.enterText(find.byKey(const Key('new-group-name')), 'Fifteen');
    for (final item in contacts.take(15)) {
      final row = find.byKey(Key('create-group-contact:${item.identityId}'));
      await tester.ensureVisible(row);
      await tester.tap(row);
      await tester.pump();
    }
    expect(find.text('15/15 selected'), findsOneWidget);
    final last = tester.widget<CheckboxListTile>(
      find.byKey(Key('create-group-contact:${contacts.last.identityId}')),
    );
    expect(last.onChanged, isNull);
  });

  testWidgets('owner details invite verified nonmembers and confirm removal', (
    tester,
  ) async {
    final calls = <String>[];
    final contacts = [
      contact(own, 'Owner'),
      contact(friend, 'Friend'),
      contact(other, 'New member'),
      contact(outsider, 'Unverified', verified: false),
    ];
    await openDialog(
      tester,
      (context) async => showGroupDetails(
        context,
        group: group(),
        ownId: own,
        contacts: contacts,
        onInvite: (id) async => calls.add('invite:$id'),
        onRemove: (id) async => calls.add('remove:$id'),
        onLeave: () async => calls.add('leave'),
      ),
    );
    expect(find.text('Project Room'), findsOneWidget);
    expect(find.text('2 members'), findsOneWidget);
    expect(find.text('Creator'), findsOneWidget);
    expect(find.text('Unverified'), findsNothing);
    await tester.tap(find.byKey(const Key('group-invite:$other')));
    await tester.pumpAndSettle();
    expect(calls, ['invite:$other']);
    await tester.tap(find.byKey(const Key('group-remove:$friend')));
    await tester.pumpAndSettle();
    expect(find.text('Remove Friend?'), findsOneWidget);
    await tester.tap(find.widgetWithText(ElevatedButton, 'Remove member'));
    await tester.pumpAndSettle();
    expect(calls, ['invite:$other', 'remove:$friend']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ordinary member cannot see owner membership actions', (
    tester,
  ) async {
    await openDialog(
      tester,
      (context) async => showGroupDetails(
        context,
        group: group(),
        ownId: friend,
        contacts: [contact(other, 'New member')],
        onInvite: (_) async {},
        onRemove: (_) async {},
        onLeave: () async {},
      ),
    );
    expect(find.text('Invite friends'), findsNothing);
    expect(find.byKey(const Key('group-remove:$friend')), findsNothing);
    expect(find.byKey(const Key('group-invite:$other')), findsNothing);
  });

  testWidgets('owner leave requires explicit close-for-everyone confirmation', (
    tester,
  ) async {
    var closed = false;
    await openDialog(
      tester,
      (context) async => showGroupDetails(
        context,
        group: group(),
        ownId: own,
        contacts: const [],
        onInvite: (_) async {},
        onRemove: (_) async {},
        onLeave: () async => closed = true,
      ),
    );
    await tester.tap(find.text('Close group'));
    await tester.pumpAndSettle();
    expect(find.text('Close this group for everyone?'), findsOneWidget);
    expect(find.textContaining('all members'), findsOneWidget);
    expect(closed, isFalse);
    await tester.tap(find.widgetWithText(ElevatedButton, 'Close group'));
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ordinary member confirms leaving without owner close wording', (
    tester,
  ) async {
    var left = false;
    await openDialog(
      tester,
      (context) async => showGroupDetails(
        context,
        group: group(),
        ownId: friend,
        contacts: const [],
        onInvite: (_) async {},
        onRemove: (_) async {},
        onLeave: () async => left = true,
      ),
    );
    await tester.tap(find.text('Leave group'));
    await tester.pumpAndSettle();
    expect(find.text('Leave this group?'), findsOneWidget);
    expect(find.textContaining('everyone'), findsNothing);
    await tester.tap(find.widgetWithText(ElevatedButton, 'Leave group'));
    await tester.pumpAndSettle();
    expect(left, isTrue);
  });

  testWidgets('group invitations show readable owner and accept invite', (
    tester,
  ) async {
    String? accepted;
    final invitation = GroupInvitation(
      id: 'invite-id',
      source: 'signed-source',
      groupId: 'group:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
      name: 'Weekend Crew',
      ownerId: other,
      expiresAt: 5000,
    );
    final unknownOwnerInvite = GroupInvitation(
      id: 'invite-two',
      source: 'signed-source-two',
      groupId: 'group:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
      name: 'Book Club',
      ownerId: outsider,
      expiresAt: 5000,
    );
    String? declined;
    await openDialog(
      tester,
      (context) async => showGroupInvitations(
        context,
        invitations: [invitation, unknownOwnerInvite],
        contacts: [contact(other, 'Casey')],
        onAccept: (id) async => accepted = id,
        onDecline: (id) async => declined = id,
      ),
    );
    expect(find.text('Weekend Crew'), findsOneWidget);
    expect(find.text('From Casey'), findsOneWidget);
    expect(find.text('From Owner dddddddd'), findsOneWidget);
    await tester.tap(
      find.byKey(const Key('group-invitation-decline:invite-id')),
    );
    await tester.pumpAndSettle();
    expect(declined, 'invite-id');
    await tester.tap(
      find.byKey(const Key('group-invitation-accept:invite-two')),
    );
    await tester.pumpAndSettle();
    expect(accepted, 'invite-two');
  });

  testWidgets(
    'delete confirmation says history is local and membership remains',
    (tester) async {
      var deleted = false;
      await openDialog(tester, (context) async {
        deleted = await confirmDeleteGroupChat(context);
      });
      expect(find.text('Delete group chat history?'), findsOneWidget);
      expect(find.textContaining('membership will remain'), findsOneWidget);
      expect(deleted, isFalse);
      await tester.tap(find.widgetWithText(ElevatedButton, 'Delete history'));
      await tester.pumpAndSettle();
      expect(deleted, isTrue);
    },
  );
}
