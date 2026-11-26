import 'dart:typed_data';

import 'package:cht/chat/chat_attachment.dart';
import 'package:cht/groups/group_models.dart';
import 'package:cht/groups/group_room.dart';
import 'package:cht/groups/swarm/swarm.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('narrow group room shows actions, senders, and swarm progress', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 40, bottom: 24);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);

    final ownerId = 'did:cht:${'a' * 64}';
    final peerId = 'did:cht:${'b' * 64}';
    var detailsOpened = false;
    var deleted = false;
    var sentText = '';
    var fileOpenCount = 0;
    final room = GroupView(
      groupId: 'group:${'c' * 64}',
      name: 'A very long group name that should fit on a phone',
      ownerId: ownerId,
      epoch: 1,
      closed: false,
      members: [
        GroupMember(identityId: ownerId, displayName: 'Owner'),
        GroupMember(identityId: peerId, displayName: 'Mali'),
      ],
      states: const [],
    );
    final manifest = SwarmManifest(
      groupId: room.groupId,
      epoch: 1,
      uploaderId: peerId,
      fileId: 'd' * 32,
      name: 'draft.pdf',
      mimeType: 'application/pdf',
      size: 100,
      pieceSize: swarmPieceSize,
      digest: 'e' * 64,
      merkleRoot: 'f' * 64,
    );
    final messages = [
      GroupMessage(
        id: 'incoming',
        groupId: room.groupId,
        senderId: peerId,
        senderName: 'Mali',
        text: 'Hello from Mali',
        event: 'message',
        sentAt: 1700000000000,
        receivedAt: 1700000001000,
        recipients: [ownerId],
      ),
      GroupMessage(
        id: 'file',
        groupId: room.groupId,
        senderId: peerId,
        senderName: 'Mali',
        text: 'Quarterly draft',
        event: 'file',
        sentAt: 1700000002000,
        recipients: [ownerId],
        manifest: manifest,
      ),
      GroupMessage(
        id: 'sent',
        groupId: room.groupId,
        senderId: ownerId,
        senderName: 'Owner',
        text: '**Confirmed**',
        event: 'message',
        sentAt: 1700000003000,
        receivedAt: 1700000004000,
        recipients: [peerId, 'did:cht:${'g' * 64}'],
        receipts: {peerId: 1700000004000},
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GroupRoom(
            group: room,
            ownId: ownerId,
            messages: messages,
            enabled: true,
            onMessageAction: (_, _, _) async => true,
            onlineCount: 1,
            onSend: (text) async {
              sentText = text;
              return true;
            },
            onSendBatch: (_, _) async => true,
            openFile: (_) async {
              fileOpenCount++;
              return ChatAttachment(
                name: 'draft.pdf',
                mimeType: 'application/pdf',
                bytes: Uint8List.fromList([1, 2, 3]),
              );
            },
            progressFor: (_) => const SwarmProgress(
              verifiedBytes: 40,
              totalBytes: 100,
              sourceCount: 2,
              complete: false,
              waitingForDirect: false,
            ),
            onDetails: () => detailsOpened = true,
            onDelete: () => deleted = true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(room.name), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const Key('group-room-title'))).dy,
      greaterThanOrEqualTo(40),
    );
    expect(
      tester.getBottomRight(find.byKey(const Key('group-message-composer'))).dy,
      lessThanOrEqualTo(696),
    );
    expect(find.text('Mali'), findsWidgets);
    expect(find.text('Hello from Mali'), findsOneWidget);
    expect(find.text('draft.pdf'), findsOneWidget);
    expect(find.textContaining('40%'), findsOneWidget);
    expect(find.textContaining('2 sources'), findsOneWidget);
    expect(find.text('1/2 delivered'), findsNothing);
    expect(find.byIcon(Icons.schedule), findsOneWidget);
    expect(find.byIcon(Icons.done_all), findsNothing);
    expect(fileOpenCount, 0);
    expect(tester.takeException(), isNull);

    await tester.longPress(find.byKey(Key('group-message-$peerId:incoming')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('message-action-grid')), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Reply'), findsOneWidget);
    expect(find.text('Edit'), findsNothing);
    expect(find.text('Delete'), findsNothing);
    await tester.tapAt(const Offset(10, 40));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(Key('group-message-actions-$ownerId:sent')));
    await tester.pumpAndSettle();
    expect(find.text('Reply'), findsOneWidget);
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
    await tester.tap(find.text('Message info'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('1/2 delivered', findRichText: true),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Group actions'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('Group details'), findsOneWidget);
    await tester.tap(find.text('Group details'));
    expect(detailsOpened, isTrue);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Group actions'), warnIfMissed: false);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete group'));
    expect(deleted, isTrue);

    await tester.enterText(
      find.byKey(const Key('group-message-input')),
      'Thanks',
    );
    await tester.tap(find.byKey(const Key('group-send-message')));
    await tester.pumpAndSettle();
    expect(sentText, 'Thanks');
    expect(tester.takeException(), isNull);
  });

  testWidgets('opens a swarm file only after verified completion', (
    tester,
  ) async {
    final ownerId = 'did:cht:${'a' * 64}';
    final group = GroupView(
      groupId: 'group:${'c' * 64}',
      name: 'Files',
      ownerId: ownerId,
      epoch: 1,
      closed: false,
      members: [GroupMember(identityId: ownerId, displayName: 'Owner')],
      states: const [],
    );
    final manifest = SwarmManifest(
      groupId: group.groupId,
      epoch: 1,
      uploaderId: ownerId,
      fileId: 'd' * 32,
      name: 'notes.txt',
      mimeType: 'text/plain',
      size: 3,
      pieceSize: swarmPieceSize,
      digest: 'e' * 64,
      merkleRoot: 'f' * 64,
    );
    var opens = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: GroupRoom(
              group: group,
              ownId: ownerId,
              messages: [
                GroupMessage(
                  id: 'file',
                  groupId: group.groupId,
                  senderId: ownerId,
                  senderName: 'Owner',
                  text: 'Notes',
                  event: 'file',
                  sentAt: 1700000000000,
                  recipients: const [],
                  manifest: manifest,
                ),
              ],
              enabled: true,
              onlineCount: 1,
              onSend: (_) async => true,
              onSendBatch: (_, _) async => true,
              openFile: (_) async {
                opens++;
                return ChatAttachment(
                  name: 'notes.txt',
                  mimeType: 'text/plain',
                  bytes: Uint8List.fromList([1, 2, 3]),
                );
              },
              progressFor: (_) => const SwarmProgress(
                verifiedBytes: 3,
                totalBytes: 3,
                sourceCount: 1,
                complete: true,
                waitingForDirect: false,
              ),
              onDetails: () {},
              onDelete: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(opens, 1);
    expect(find.text('notes.txt'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
