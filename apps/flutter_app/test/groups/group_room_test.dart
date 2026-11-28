import 'dart:convert';
import 'dart:typed_data';

import 'package:cht/account/account_models.dart';
import 'package:cht/chat/chat_attachment.dart';
import 'package:cht/chat/peer_message_action.dart';
import 'package:cht/groups/group_models.dart';
import 'package:cht/groups/group_room.dart';
import 'package:cht/groups/swarm/swarm.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;

void main() {
  testWidgets('group MP4 keeps its cover before, during, and after receiving', (
    tester,
  ) async {
    const own = 'did:cht:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    const peer = 'did:cht:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    const roomId = 'group:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
    final group = GroupView(
      groupId: roomId,
      name: 'Videos',
      ownerId: own,
      epoch: 1,
      closed: false,
      members: const [
        GroupMember(identityId: own, displayName: 'Alice'),
        GroupMember(identityId: peer, displayName: 'Bob'),
      ],
      states: const [],
    );
    final manifest = SwarmManifest(
      groupId: roomId,
      epoch: 1,
      uploaderId: peer,
      fileId: '2' * 32,
      name: 'clip.mp4',
      mimeType: 'video/mp4',
      size: 100,
      pieceSize: swarmPieceSize,
      digest: '3' * 64,
      merkleRoot: '4' * 64,
      cover: base64Encode(image.encodeJpg(image.Image(width: 6, height: 6))),
    );
    final message = GroupMessage(
      id: 'clip',
      groupId: roomId,
      senderId: peer,
      senderName: 'Bob',
      text: 'clip.mp4',
      event: 'signed file',
      sentAt: 1000,
      recipients: const [],
      manifest: manifest,
    );
    var choice = GroupFileChoice.pending;
    var received = 40, fileOpenCount = 0;
    late StateSetter redraw;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(builder: (context, setState) {
          redraw = setState;
          return GroupRoom(
            group: group,
            ownId: own,
            messages: [message],
            enabled: true,
            onlineCount: 1,
            onSend: (_) async => true,
            onSendBatch: (_, _) async => true,
            openFile: (_) async {
              fileOpenCount++;
              return ChatAttachment(
                name: manifest.name,
                mimeType: manifest.mimeType,
                bytes: Uint8List(100),
              );
            },
            progressFor: (_) => SwarmProgress(
              verifiedBytes: received,
              totalBytes: 100,
              sourceCount: 1,
              complete: received == 100,
              waitingForDirect: false,
            ),
            fileChoiceFor: (_) => choice,
            onFileChoice: (_, updated) async {
              setState(() => choice = updated);
              return true;
            },
            onDetails: () {},
            onDelete: () {},
          );
        }),
      ),
    ));
    await tester.pumpAndSettle();
    final cover = find.byType(Image);
    expect(cover, findsOneWidget);
    expect(find.text('video/mp4 · 100 B'), findsOneWidget);
    final before = tester.widget<Image>(cover).image;

    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();
    expect(find.text('40%'), findsOneWidget);
    expect(find.text('video/mp4 · 100 B'), findsOneWidget);
    expect(cover, findsOneWidget);
    expect(tester.widget<Image>(cover).image, same(before));
    redraw(() => received = 68);
    await tester.pumpAndSettle();
    expect(find.text('68%'), findsOneWidget);
    expect(tester.widget<Image>(cover).image, same(before));
    expect(fileOpenCount, 0);

    redraw(() => received = 100);
    await tester.pumpAndSettle();
    expect(fileOpenCount, 1);
    expect(find.byIcon(Icons.play_circle_fill), findsOneWidget);
    expect(cover, findsOneWidget);
  });

  for (final width in [320.0, 390.0, 960.0]) {
    testWidgets('group bubbles keep a common edge at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const own = 'owner';
      const peer = 'friend';
      final group = GroupView(
        groupId: 'group:test',
        name: 'Weekend plans',
        ownerId: own,
        epoch: 1,
        closed: false,
        members: const [
          GroupMember(identityId: own, displayName: 'You'),
          GroupMember(identityId: peer, displayName: 'Alex'),
        ],
        states: const [],
      );
      GroupMessage message(String id, String author, String text, int offset) =>
          GroupMessage(
            id: id,
            groupId: group.groupId,
            senderId: author,
            senderName: author == own ? 'You' : 'Alex',
            text: text,
            event: 'message',
            sentAt: DateTime(
              2026,
              11,
              27,
              19,
              0,
              offset,
            ).millisecondsSinceEpoch,
            recipients: [author == own ? peer : own],
            receipts: id == 'short' ? {peer: 1795780800000} : const {},
          );

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: GroupRoom(
              group: group,
              ownId: own,
              messages: [
                message('short', own, 'OK', 0),
                message('incoming', peer, 'See you there', 1),
                message('next', peer, 'Meet by the gate', 2),
                message('medium', own, 'I will bring snacks', 3),
                message(
                  'long',
                  own,
                  'Let me know if you need anything else for the trip.',
                  4,
                ),
              ],
              enabled: true,
              onlineCount: 1,
              onSend: (_) async => true,
              onSendBatch: (_, _) async => true,
              openFile: (_) async => throw StateError('No attachment'),
              progressFor: (_) => null,
              onDetails: () {},
              onDelete: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      Rect bubble(String author, String id) =>
          tester.getRect(find.byKey(Key('group-message-$author:$id')));
      for (final id in ['short', 'medium', 'long']) {
        expect(bubble(own, id).right, closeTo(width - 14, .01), reason: id);
      }
      expect(bubble(peer, 'incoming').left, closeTo(52, .01));
      expect(bubble(peer, 'next').left, closeTo(52, .01));
      expect(
        bubble(peer, 'next').top - bubble(peer, 'incoming').bottom,
        lessThan(10),
      );
      expect(
        find.byKey(const Key('group-sender-friend:incoming')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('group-sender-friend:next')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

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
    String? savedEdit;
    var fileOpenCount = 0;
    var fileChoice = GroupFileChoice.pending;
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
          body: StatefulBuilder(
            builder: (context, setState) => GroupRoom(
              group: room,
              ownId: ownerId,
              messages: messages,
              enabled: true,
              contacts: {
                peerId: ContactView(
                  identityId: peerId,
                  displayName: 'Mai',
                  signedName: 'Mali',
                  alias: 'Mai',
                  fingerprint: 'test-fingerprint',
                  verified: true,
                ),
              },
              onMessageAction: (kind, message, value) async {
                expect(kind, PeerMessageActionKind.edit);
                expect(message.id, 'sent');
                savedEdit = value;
                return true;
              },
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
              fileChoiceFor: (_) => fileChoice,
              onFileChoice: (_, choice) async {
                setState(() => fileChoice = choice);
                return true;
              },
              onDetails: () => detailsOpened = true,
              onDelete: () => deleted = true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final sender = find.byTooltip('View profile for Mai');
    expect(sender, findsOneWidget);
    await tester.tap(sender);
    await tester.pumpAndSettle();
    expect(find.text('Signed name'), findsOneWidget);
    expect(find.text('Local alias: Mai'), findsOneWidget);
    expect(find.text('Mali'), findsOneWidget);
    await tester.tapAt(const Offset(12, 80));
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
    expect(find.text('Mai'), findsOneWidget);
    expect(find.text('Hello from Mali'), findsOneWidget);
    expect(find.text('draft.pdf'), findsOneWidget);
    expect(find.text('application/pdf · 100 B'), findsOneWidget);
    expect(find.text('Reject'), findsOneWidget);
    expect(find.textContaining('40%'), findsNothing);
    expect(fileOpenCount, 0);
    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();
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
    final input = find.byKey(const Key('group-message-input'));
    await tester.enterText(input, 'Unsent draft');
    await tester.tap(find.byKey(Key('group-message-actions-$ownerId:sent')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Edit'));
    await tester.pumpAndSettle();
    expect(find.text('Editing message'), findsOneWidget);
    await tester.enterText(input, 'Revised');
    await tester.tap(find.byTooltip('Save edit'));
    await tester.pumpAndSettle();
    expect(savedEdit, 'Revised');
    expect(tester.widget<TextField>(input).controller!.text, 'Unsent draft');
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
