// Four-browser QA. Only fresh synthetic browser identities are permitted.
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;
import 'package:cht/chat/attachment_source.dart';
import 'package:cht/chat/attachment_store.dart';
import 'package:cht/chat/chat_attachment.dart';
import 'package:cht/core/core_bridge.dart';
import 'package:cht/core/core_bridge_factory.dart';
import 'package:cht/groups/group_blob_bridge.dart';
import 'package:cht/groups/group_controller.dart';
import 'package:cht/groups/group_crypto_bridge.dart';
import 'package:cht/groups/group_models.dart';
import 'package:cht/groups/group_seed_client.dart';
import 'package:cht/groups/group_transport.dart';
import 'package:cht/groups/swarm/swarm.dart';
import 'package:cht/relay/relay_crypto_bridge.dart';
import 'package:cht/relay/relay_network.dart';
import 'package:cht/relay/relay_socket.dart';

import 'qa_result.dart';

const _roles = {'a', 'b', 'c', 'd'};
const _groupMarker = 'CHTA-GROUP-QA-CONTENT-MARKER';
const _fileName = 'synthetic-groups-8MiB.bin';
const _fileSize = 8 * 1024 * 1024;
const _qaPrefix = 'chta-groups-qa-v1:';
const _resumeKey = 'qa_groups_resume_v1';
const _sessionRoleKey = 'chtGroupsQaRole';
const _sessionOwnerKey = 'chtGroupsQaOwner';
const _sessionGroupKey = 'chtGroupsQaGroup';
const _sessionResumeKey = 'chtGroupsQaReloadPending';
const _sessionSeedTypesKey = 'chtGroupsQaSeedTypes';
const _sessionSeedContentKey = 'chtGroupsQaSeedContent';
const _sessionDeadlineKey = 'chtGroupsQaDeadlineEpochMs';
const _seedEndpoint = String.fromEnvironment('CHT_SEED_URL');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  Timer.periodic(const Duration(seconds: 1), (_) {
    final h = _active;
    globalContext.setProperty(
      'chtGroupQaStatus'.toJS,
      {
        'phase': _phase,
        'groups': h?.controller?.groups.length ?? 0,
        'members': h?.controller?.groups.firstOrNull?.members.length ?? 0,
        'invitations': h?.controller?.invitations.length ?? 0,
        'jobs': h?.controller?.pendingJobCount ?? 0,
        'peers': h?.transport?.onlinePeers.length ?? 0,
        'seed': h?.transport?.signaling.registered ?? false,
        'seedTypes': h?.audit.types ?? const <String, int>{},
        'cryptoCalls': h?._crypto?.calls ?? const <String, int>{},
        'cryptoErrors': h?._crypto?.errors ?? const <String>[],
      'receivedPieces': h?.receivedPieces ?? 0,
      'assemblies': h?.pieces.length ?? 0,
      'backgroundError': h?.backgroundError?.toString(),
      }.jsify(),
    );
  });
  runApp(
    const MaterialApp(
      home: Scaffold(
        body: Center(child: Text('Disposable four-browser Groups QA')),
      ),
    ),
  );
  unawaited(_runGuarded());
}

Future<Map<String, dynamic>> _coordinate(
  String path, {
  Map<String, Object?>? body,
}) async {
  final headers = web.Headers()..set('content-type', 'application/json');
  final response = await web.window
      .fetch(
        path.toJS,
        web.RequestInit(
          method: body == null ? 'GET' : 'POST',
          headers: headers,
          body: body == null ? null : jsonEncode(body).toJS,
        ),
      )
      .toDart;
  if (!response.ok) throw StateError('QA coordinator rejected a request');
  return jsonDecode((await response.text().toDart).toDart)
      as Map<String, dynamic>;
}

String? _sessionValue(String key) => web.window.sessionStorage.getItem(key);

void _setSessionValue(String key, String value) =>
    web.window.sessionStorage.setItem(key, value);

class _SeedAudit {
  final types = <String, int>{};
  bool containsGroupContent = false;

  void observe(String source) {
    try {
      final frame = jsonDecode(source);
      final type = frame is Map ? frame['type'] : null;
      if (type is String) types[type] = (types[type] ?? 0) + 1;
    } catch (_) {
      types['unparsed'] = (types['unparsed'] ?? 0) + 1;
    }
    containsGroupContent |=
        source.contains(_groupMarker) || source.contains(_fileName);
  }
}

class _RecordingSocket implements RelaySocket {
  _RecordingSocket(this._inner, this._audit);
  final RelaySocket _inner;
  final _SeedAudit _audit;

  @override
  Stream<String> get frames => _inner.frames.map((frame) {
    _audit.observe(frame);
    return frame;
  });

  @override
  void send(String frame) {
    _audit.observe(frame);
    _inner.send(frame);
  }

  @override
  Future<void> close() => _inner.close();
}

class _QaPeer {
  _QaPeer(
    this.role,
    this.ownerId,
    this.controller,
    this.transport,
    this.network,
  );
  final String role, ownerId;
  final GroupController controller;
  final GroupTransport transport;
  final RelayNetwork network;
}

class _FileSource implements AttachmentSource {
  const _FileSource();
  @override
  int get length => _fileSize;
  @override
  String get key => 'groups-qa-deterministic-8mib-v1';

  @override
  Stream<List<int>> openRead({int start = 0, int? end}) async* {
    final last = end ?? _fileSize;
    if (start < 0 || last < start || last > _fileSize) {
      throw RangeError.range(last, start, _fileSize);
    }
    for (var offset = start; offset < last; offset += 65536) {
      final length = (last - offset).clamp(0, 65536);
      yield Uint8List.fromList(
        List<int>.generate(length, (index) => (offset + index) % 251),
      );
    }
  }
}

class _SeedPieceAssembly {
  _SeedPieceAssembly(this.count);
  final int count;
  final parts = <int, Uint8List>{};
  List<String>? proof;
}

class _AuditedCrypto implements GroupCryptoBridge {
  _AuditedCrypto(this.inner);
  final GroupCryptoBridge inner;
  final calls = <String, int>{};
  final errors = <String>[];
  @override
  Future<Map<String, Object?>> groupCall(
    String operation,
    Map<String, Object?> args,
  ) async {
    calls[operation] = (calls[operation] ?? 0) + 1;
    try {
      return await inner.groupCall(operation, args);
    } catch (e) {
      errors.add('$operation: $e');
      if (errors.length > 8) errors.removeAt(0);
      rethrow;
    }
  }
}

class _Harness {
  _Harness(this.role, this.core, this.ownerId, this.audit);
  final String role, ownerId;
  final AppBridge core;
  final _SeedAudit audit;
  final pieces = <String, _SeedPieceAssembly>{};
  final contentPeers = <String, String>{};
  Object? backgroundError;
  StackTrace? backgroundStack;
  Future<void> incoming = Future<void>.value();
  StreamSubscription<GroupPeerFrame>? frameSubscription;
  GroupController? controller;
  GroupTransport? transport;
  RelayNetwork? network;
  SwarmTransfer? transfer;
  SparseSwarmCache? cache;
  bool paused = false, dComplete = false, finished = false;
  SwarmManifest? manifest;
  String? signedEvent;
  int receivedPieces = 0;
  int sourceCount = 0;

  _AuditedCrypto? _crypto;
  GroupCryptoBridge get crypto =>
      _crypto ??= _AuditedCrypto(core as GroupCryptoBridge);
  GroupBlobBridge get blobs => core as GroupBlobBridge;

  Future<void> waitUntil(
    FutureOr<bool> Function() condition, {
    int seconds = 600,
  }) async {
    final deadline = DateTime.now().add(Duration(seconds: seconds));
    while (!await condition()) {
      _throwBackgroundError();
      if (DateTime.now().isAfter(deadline) ||
          _deadline == null ||
          DateTime.now().isAfter(_deadline!)) {
        throw StateError('Timed out during $_phase');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  void _throwBackgroundError() {
    if (backgroundError != null) {
      Error.throwWithStackTrace(backgroundError!, backgroundStack!);
    }
  }

  Future<void> arrive(String name) async {
    await _coordinate('/qa/phase', body: {'role': role, 'name': name});
  }

  Future<void> waitRoles(String name, Set<String> roles) async {
    await waitUntil(() async {
      final result = await _coordinate('/qa/phase?name=$name');
      final found = (result['roles'] as List).cast<String>().toSet();
      return found.containsAll(roles);
    });
  }
}

String _phase = 'startup';
_Harness? _active;
DateTime? _deadline;

Future<void> _runGuarded() async {
  String? role;
  _Harness? harness;
  try {
    role = Uri.base.queryParameters['role'];
    _phase = 'identity';
    if (!_roles.contains(role)) throw StateError('Expected role a, b, c, or d');
    if (_seedEndpoint.isEmpty) throw StateError('CHT_SEED_URL is required');
    final core = createCoreBridge();
    if (core is InitializableCoreBridge) {
      await (core as InitializableCoreBridge).initializePlatform();
    }
    final resumed = await _identity(core, role!);
    final savedDeadline = _sessionValue(_sessionDeadlineKey);
    if (resumed.$2) {
      if (savedDeadline == null) {
        throw StateError('QA resume deadline marker is missing');
      }
      _deadline = DateTime.fromMillisecondsSinceEpoch(int.parse(savedDeadline));
    } else {
      _deadline = DateTime.now().add(const Duration(seconds: 600));
      _setSessionValue(
        _sessionDeadlineKey,
        _deadline!.millisecondsSinceEpoch.toString(),
      );
    }
    if (DateTime.now().isAfter(_deadline!)) {
      throw StateError('Groups browser QA exceeded its ten-minute limit');
    }
    harness = _Harness(role, core, resumed.$1, _SeedAudit());
    if (resumed.$2) {
      final oldTypes = _sessionValue(_sessionSeedTypesKey);
      if (oldTypes != null) {
        harness.audit.types.addAll(
          (jsonDecode(oldTypes) as Map).cast<String, int>(),
        );
      }
      harness.audit.containsGroupContent =
          _sessionValue(_sessionSeedContentKey) == '1';
    }
    _active = harness;
    await _workflow(harness, resumed.$2);
  } catch (error, stack) {
    reportQa({
      'ok': false,
      'role': role,
      'phase': _phase,
      'error': _safe(error.toString()),
      'stack': _safe(stack.toString()),
      'seedContent': harness?.audit.containsGroupContent ?? false,
      'seedFrameTypes': harness?.audit.types ?? const <String, int>{},
    });
  } finally {
    await _active?._cleanup();
    _active = null;
  }
}

String _safe(String source) => source
    .replaceAll(RegExp(r'did:cht:[0-9a-f]{64}'), '[identity]')
    .replaceAll(RegExp(r'\b(?:[a-z]{3,12}\s+){11}[a-z]{3,12}\b'), '[secret]');

Future<(String, bool)> _identity(AppBridge core, String role) async {
  final resume =
      role == 'd' &&
      _sessionValue(_sessionRoleKey) == 'd' &&
      _sessionValue(_sessionResumeKey) == '1';
  final hasIdentity = await core.hasIdentity();
  if (hasIdentity) {
    if (!resume || _sessionValue(_sessionOwnerKey) == null) {
      throw StateError('QA requires a fresh synthetic browser identity');
    }
    final owner = (await core.identity()).id;
    if (owner != _sessionValue(_sessionOwnerKey)) {
      throw StateError('Resume identity does not match its QA session marker');
    }
    _setSessionValue(_sessionResumeKey, '0');
    return (owner, true);
  }
  if (resume) throw StateError('QA resume identity is missing');
  final pending = await core.createIdentity();
  final owner = (await core.confirmRecovery(pending.mnemonic)).id;
  _setSessionValue(_sessionRoleKey, role);
  _setSessionValue(_sessionOwnerKey, owner);
  _setSessionValue(_sessionResumeKey, '0');
  return (owner, false);
}

Future<Map<String, String>> _verifyBootstrapContacts(
  AppBridge core,
  String role,
) async {
  final card = await core.contactCard(displayName: 'Synthetic Group QA $role');
  await _coordinate('/qa/card', body: {'role': role, 'card': card});
  final wanted = role == 'a' ? _roles.difference({'a'}) : {'a'};
  Map<String, String> cards = {};
  final deadline = DateTime.now().add(const Duration(seconds: 90));
  while (!cards.keys.toSet().containsAll(wanted)) {
    final result = await _coordinate('/qa/peers?role=$role');
    cards = (result['cards'] as Map).cast<String, String>();
    if (!cards.keys.toSet().containsAll(wanted)) {
      if (DateTime.now().isAfter(deadline) ||
          _deadline == null ||
          DateTime.now().isAfter(_deadline!)) {
        throw StateError('Other synthetic browser cards did not register');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
  final ids = <String, String>{};
  for (final peerRole in wanted) {
    final peerCard = cards[peerRole]!;
    final inspected = await core.inspectContactCard(peerCard);
    await core.addContact(peerCard, 'Synthetic QA $peerRole');
    await core.markContactVerified(inspected.identityId);
    ids[peerRole] = inspected.identityId;
  }
  return ids;
}

Future<_QaPeer> _startController(_Harness h, Map<String, String> peers) async {
  h.network = RelayNetwork(h.core as RelayCryptoBridge);
  h.controller = GroupController(
    ownerId: h.ownerId,
    crypto: h.crypto,
    blobs: h.blobs,
    attachments: createAttachmentStore(bridge: h.core),
    displayName: () => 'Synthetic QA ${h.role}',
  );
  await h.controller!.initialize();
  final seed = GroupSeedClient(
    account: h.core,
    relayCrypto: h.core as RelayCryptoBridge,
    crypto: h.crypto,
    network: h.network!,
    connector: (endpoint) async =>
        _RecordingSocket(await openRelaySocket(endpoint), h.audit),
    endpoint: _seedEndpoint,
  );
  h.transport = GroupTransport(
    ownerId: h.ownerId,
    crypto: h.crypto,
    network: h.network!,
    signaling: SeedGroupSignaling(seed),
  );
  await h.controller!.attachTransport(h.transport!);
  for (final peer in peers.values) {
    unawaited(h.transport!.connect(peer).catchError((Object _) {}));
  }
  return _QaPeer(h.role, h.ownerId, h.controller!, h.transport!, h.network!);
}

Future<GroupTransport> _startBareTransport(_Harness h) async {
  h.network = RelayNetwork(h.core as RelayCryptoBridge);
  final seed = GroupSeedClient(
    account: h.core,
    relayCrypto: h.core as RelayCryptoBridge,
    crypto: h.crypto,
    network: h.network!,
    connector: (endpoint) async =>
        _RecordingSocket(await openRelaySocket(endpoint), h.audit),
    endpoint: _seedEndpoint,
  );
  h.transport = GroupTransport(
    ownerId: h.ownerId,
    crypto: h.crypto,
    network: h.network!,
    signaling: SeedGroupSignaling(seed),
  );
  await h.transport!.start();
  return h.transport!;
}

Future<void> _workflow(_Harness h, bool resumed) async {
  if (resumed) {
    await _resumeD(h);
    return;
  }
  _phase = 'contact-bootstrap';
  final peers = await _verifyBootstrapContacts(h.core, h.role);
  final qa = await _startController(h, peers);
  _phase = 'all-ready';
  await h.arrive('ready');
  await h.waitRoles('ready', _roles);

  _phase = 'group-membership';
  late String groupId;
  if (h.role == 'a') {
    groupId = await qa.controller.createGroup('Synthetic Group QA', [
      peers['b']!,
      peers['c']!,
      peers['d']!,
    ]);
  } else {
    await h.waitUntil(() => qa.controller.invitations.isNotEmpty);
    final invitation = qa.controller.invitations.first;
    groupId = invitation.groupId;
    await qa.controller.acceptInvitation(invitation.id);
  }
  _setSessionValue(_sessionGroupKey, groupId);
  await h.waitUntil(() {
    final group = qa.controller.group(groupId);
    return group != null &&
        group.contains(h.ownerId) &&
        group.members.length == 4 &&
        qa.controller.canSend(groupId);
  });
  final members = qa.controller.group(groupId)!.members;
  for (final member in members.where(
    (member) => member.identityId != h.ownerId,
  )) {
    unawaited(
      qa.transport.connect(member.identityId).catchError((Object _) {}),
    );
  }
  await h.waitUntil(
    () => members
        .where((member) => member.identityId != h.ownerId)
        .every((member) => qa.transport.isDirect(member.identityId)),
  );
  await h.arrive('members');
  await h.waitRoles('members', _roles);

  _phase = 'group-messages-and-receipts';
  const first = 'CHTA-GROUP-QA-CONTENT-MARKER from A';
  const second = 'CHTA-GROUP-QA-CONTENT-MARKER from B';
  if (h.role == 'a') {
    if (!await qa.controller.sendText(groupId, first)) {
      throw StateError('Could not queue the synthetic A message');
    }
  }
  await h.waitUntil(
    () => qa.controller.messagesFor(groupId).any((m) => m.text == first),
  );
  if (h.role == 'b') {
    if (!await qa.controller.sendText(groupId, second)) {
      throw StateError('Could not queue the synthetic B message');
    }
  }
  await h.waitUntil(
    () => qa.controller.messagesFor(groupId).any((m) => m.text == second),
  );
  await h.waitUntil(() {
    final members = qa.controller.group(groupId)!.members;
    final senderA = members
        .singleWhere((member) => member.displayName == 'Synthetic QA a')
        .identityId;
    final senderB = members
        .singleWhere((member) => member.displayName == 'Synthetic QA b')
        .identityId;
    final sentA = qa.controller
        .messagesFor(groupId)
        .where((m) => m.senderId == senderA && m.text == first)
        .firstOrNull;
    final sentB = qa.controller
        .messagesFor(groupId)
        .where((m) => m.senderId == senderB && m.text == second)
        .firstOrNull;
    if (sentA == null || sentB == null) return false;
    if (h.role == 'a') return sentA.receipts.length == 3;
    if (h.role == 'b') return sentB.receipts.length == 3;
    return true;
  });
  await h.arrive('messages');
  await h.waitRoles('messages', _roles);

  final group = qa.controller.group(groupId)!;
  await qa.controller.flush();
  await qa.controller.close();
  h.controller = null;
  h.transport = null;
  await h.network!.close();
  h.network = null;
  await _swarmPhase(h, group);
}

Future<void> _resumeD(_Harness h) async {
  _phase = 'resume-controller';
  final groupId = _sessionValue(_sessionGroupKey);
  if (groupId == null) throw StateError('QA group resume marker is missing');
  final attachments = createAttachmentStore(bridge: h.core);
  final restored = GroupController(
    ownerId: h.ownerId,
    crypto: h.crypto,
    blobs: h.blobs,
    attachments: attachments,
    displayName: () => 'Synthetic QA d',
  );
  h.controller = restored;
  await restored.initialize();
  final group = restored.group(groupId);
  if (group == null ||
      !group.contains(h.ownerId) ||
      group.members.length != 4) {
    throw StateError('Persisted membership did not restore');
  }
  final checkpoint = await h.blobs.loadGroupBlob(h.ownerId, _resumeKey);
  if (checkpoint == null) throw StateError('Swarm resume marker is missing');
  final values = jsonDecode(checkpoint) as Map<String, dynamic>;
  if (values['groupId'] != groupId || values['manifest'] is! Map) {
    throw const FormatException('QA swarm checkpoint is invalid');
  }
  final storedManifest = SwarmManifest.fromJson(
    Map<String, dynamic>.from(values['manifest'] as Map),
  );
  final event = values['event'] as String;
  await restored.close();
  h.controller = null;
  h.manifest = await _inspectFileEvent(
    h.crypto,
    event,
    groupId,
    group.epoch,
    group.ownerId,
  );
  if (storedManifest.identityHash != h.manifest!.identityHash) {
    throw const FormatException(
      'QA checkpoint manifest did not match its signed event',
    );
  }
  h.signedEvent = event;
  h.cache = SparseSwarmCache(
    h.ownerId,
    blobs: h.blobs,
    attachments: attachments,
  );
  await h.cache!.begin(h.manifest!);
  final sourceIds = group.members
      .where(
        (member) =>
            member.identityId != group.ownerId &&
            member.identityId != h.ownerId,
      )
      .map((member) => member.identityId)
      .toList();
  h.transfer = _makeTransfer(h, sourceIds);
  h.transfer!.register(h.manifest!);
  await _startBareTransport(h);
  for (final peer in group.members.where(
    (member) =>
        member.identityId != h.ownerId && member.identityId != group.ownerId,
  )) {
    unawaited(h.transport!.connect(peer.identityId).catchError((Object _) {}));
  }
  await h.waitUntil(
    () => group.members
        .where(
          (member) =>
              member.identityId != h.ownerId &&
              member.identityId != group.ownerId,
        )
        .every((member) => h.transport!.isDirect(member.identityId)),
  );
  _listenSwarm(h);
  await h.arrive('d-reloaded');
  await h.waitRoles('seed-offline', {'a'});
  await _announceAvailability(
    h,
    group.members
        .where(
          (member) =>
              member.identityId != h.ownerId &&
              member.identityId != group.ownerId,
        )
        .map((member) => member.identityId),
  );
  _phase = 'swarm-resume-download';
  await _downloadUntilComplete(h);
  final digest = await _verifyComplete(h, h.manifest!);
  h.sourceCount = h.transfer!.progressFor(h.manifest!.fileId)?.sourceCount ?? 0;
  if (h.sourceCount < 2) {
    throw StateError('D did not download from both B and C');
  }
  await h.arrive('d-complete');
  for (final peer in group.members.where(
    (m) => m.identityId != h.ownerId && m.identityId != group.ownerId,
  )) {
    await _sendQa(h.transport!, peer.identityId, {'type': 'd-complete'});
  }
  await _checkHashAndFinish(h, digest, h.manifest!, group.members.length);
}

Future<void> _swarmPhase(_Harness h, GroupView group) async {
  _phase = 'swarm-transport';
  final peers = {
    for (final member in group.members)
      if (member.displayName.startsWith('Synthetic QA '))
        member.displayName.substring('Synthetic QA '.length): member.identityId,
  };
  if (!_roles.every(peers.containsKey)) {
    throw StateError('Group membership is missing a synthetic role');
  }
  await _startBareTransport(h);
  final memberIds = group.members.map((m) => m.identityId).toList();
  for (final peer in memberIds.where((id) => id != h.ownerId)) {
    unawaited(h.transport!.connect(peer).catchError((Object _) {}));
  }
  await h.waitUntil(
    () => memberIds
        .where((id) => id != h.ownerId)
        .every((id) => h.transport!.isDirect(id)),
  );
  h.cache = SparseSwarmCache(
    h.ownerId,
    blobs: h.blobs,
    attachments: createAttachmentStore(bridge: h.core),
  );
  h.transfer = null;
  _listenSwarm(h);
  await h.arrive('swarm-ready');
  await h.waitRoles('swarm-ready', _roles);

  if (h.role == 'a') {
    _phase = 'swarm-source-import';
    final file = ChatAttachment.fromSource(
      name: _fileName,
      mimeType: 'application/octet-stream',
      source: const _FileSource(),
    );
    final manifest = await h.cache!.importFile(
      groupId: group.groupId,
      epoch: group.epoch,
      uploaderId: h.ownerId,
      fileId: groupRandomId(),
      file: file,
    );
    h.manifest = manifest;
    final signed = await h.crypto.groupCall('sign', {
      'groupId': group.groupId,
      'id': groupRandomId(),
      'kind': 'file',
      'payload': jsonEncode(manifest.toJson()),
      'now': DateTime.now().millisecondsSinceEpoch,
    });
    final event = signed['event'] as String;
    h.signedEvent = event;
    for (final member in group.members.where(
      (m) => m.identityId != h.ownerId,
    )) {
      await _sendQa(h.transport!, member.identityId, {
        'type': 'file-event',
        'event': event,
      });
    }
    for (var index = 0; index < manifest.pieceCount; index++) {
      if (_deadline == null || DateTime.now().isAfter(_deadline!)) {
        throw StateError('Timed out during $_phase');
      }
      final piece = await h.cache!.readPiece(manifest, index);
      final recipient = index.isEven ? peers['b']! : peers['c']!;
      await _sendSeedPiece(
        h,
        recipient,
        manifest,
        index,
        piece.bytes,
        piece.proof,
      );
    }
    await h.waitRoles('seed-ready', {'b', 'c', 'd'});
    await h.arrive('seed-ready');
    await h.waitRoles('seed-ready', _roles);
    await h.transport!.close();
    h.transport = null;
    await h.network!.close();
    h.network = null;
    await h.arrive('seed-offline');
    final digest = await _verifyComplete(h, manifest);
    await _checkHashAndFinish(h, digest, manifest, group.members.length);
    return;
  }

  if (h.role == 'd') {
    await h.waitUntil(() => h.manifest != null);
    final manifest = h.manifest!;
    h.transfer = _makeTransfer(h, [peers['b']!, peers['c']!]);
    h.transfer!.register(manifest);
    final event = h.signedEvent!;
    await h.blobs.saveGroupBlob(
      h.ownerId,
      _resumeKey,
      jsonEncode({
        'groupId': group.groupId,
        'event': event,
        'manifest': manifest.toJson(),
      }),
    );
    _setSessionValue(_sessionResumeKey, '1');
    await h.arrive('seed-ready');
    await h.waitRoles('seed-ready', _roles);
    await h.waitRoles('seed-offline', {'a'});
    await _announceAvailability(h, [peers['b']!, peers['c']!]);
    h.transfer!.addListener(() {
      final current = h.transfer?.progressFor(manifest.fileId);
      if (current != null && current.verifiedBytes >= 2 * swarmPieceSize) {
        h.paused = true;
      }
    });
    _phase = 'swarm-partial-before-reload';
    while (!h.paused) {
      if (_deadline == null || DateTime.now().isAfter(_deadline!)) {
        throw StateError('Timed out during $_phase');
      }
      await h.transfer!.tick();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      h._throwBackgroundError();
    }
    final partial = await h.cache!.status(manifest);
    if (partial.complete || partial.verifiedBytes == 0) {
      throw StateError('D did not stop with a verified partial cache');
    }
    if (h.audit.containsGroupContent) {
      throw StateError('Group content appeared on the public seed');
    }
    _setSessionValue(_sessionSeedTypesKey, jsonEncode(h.audit.types));
    _setSessionValue(_sessionSeedContentKey, '0');
    await h.arrive('reload-needed');
    reportQa({
      'ok': true,
      'phase': 'reload',
      'role': 'd',
      'verifiedBytes': partial.verifiedBytes,
      'bytes': manifest.size,
      'digest': manifest.digest,
      'seedContent': h.audit.containsGroupContent,
      'seedFrameTypes': h.audit.types,
    });
    return;
  }

  // B and C validate and cache complementary pieces, then wait as seedless
  // responders until D restarts and the transfer resumes.
  await h.waitUntil(() => h.manifest != null);
  final manifest = h.manifest!;
  h.transfer = _makeTransfer(h, [peers['d']!]);
  h.transfer!.register(manifest);
  await h.waitUntil(
    () async => (await h.cache!.status(manifest)).available.length == 16,
  );
  await h.arrive('seed-ready');
  await h.waitRoles('seed-ready', _roles);
  await h.waitRoles('seed-offline', {'a'});
  await _sendAvailability(h, peers['d']!);
  _phase = 'swarm-responder';
  await h.waitRoles('d-reloaded', {'d'});
  await _sendAvailability(h, peers['d']!);
  await h.waitRoles('d-complete', {'d'});
  h.dComplete = true;
  h.transfer!.close();
  h.transfer = _makeTransfer(h, [peers[h.role == 'b' ? 'c' : 'b']!]);
  h.transfer!.register(manifest);
  await h.waitUntil(
    () async => (await h.cache!.status(manifest)).available.length >= 16,
  );
  final crossPeer = peers[h.role == 'b' ? 'c' : 'b']!;
  _phase = 'swarm-crossfill';
  while (!h.finished) {
    if (_deadline == null || DateTime.now().isAfter(_deadline!)) {
      throw StateError('Timed out during $_phase');
    }
    await h.transfer!.tick();
    final status = await h.cache!.status(manifest);
    if (status.complete) {
      final digest = await _verifyComplete(h, manifest);
      if (digest != manifest.digest) {
        throw StateError('Crossfill digest mismatch');
      }
      h.finished = true;
    } else {
      await h.transport!.connect(crossPeer).catchError((Object _) {});
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    h._throwBackgroundError();
  }
  h.sourceCount = h.transfer!.progressFor(manifest.fileId)?.sourceCount ?? 1;
  await h.arrive('crossfill');
  await h.waitRoles('crossfill', _roles);
  h.sourceCount = h.transfer!.progressFor(manifest.fileId)?.sourceCount ?? 1;
  await _checkHashAndFinish(h, manifest.digest, manifest, group.members.length);
}

Future<SwarmManifest> _inspectFileEvent(
  GroupCryptoBridge crypto,
  String event,
  String groupId,
  int epoch,
  String ownerId,
) async {
  final inspected = await crypto.groupCall('inspect', {'event': event});
  if (inspected['groupId'] != groupId ||
      inspected['sender'] != ownerId ||
      inspected['kind'] != 'file' ||
      inspected['epoch'] != epoch ||
      inspected['payload'] is! String) {
    throw const FormatException('Signed QA file event failed verification');
  }
  final payload = jsonDecode(inspected['payload'] as String);
  if (payload is! Map<String, dynamic>) {
    throw const FormatException('Signed QA file manifest is malformed');
  }
  final manifest = SwarmManifest.fromJson(payload);
  if (manifest.groupId != groupId ||
      manifest.epoch != epoch ||
      manifest.uploaderId != ownerId ||
      manifest.name != _fileName ||
      manifest.size != _fileSize) {
    throw const FormatException('Signed QA manifest binding failed');
  }
  return manifest;
}

SwarmTransfer _makeTransfer(_Harness h, List<String> peers) {
  final transfer = SwarmTransfer(
    h.ownerId,
    cache: h.cache!,
    authorize: (peer, file) async {
      final result = await h.crypto.groupCall('authorize', {
        'peerId': peer,
        'groupId': file.groupId,
        'epoch': file.epoch,
      });
      return result['allowed'] == true;
    },
    peers: (_) => peers.where((id) => id != h.ownerId).toList(),
    isDirect: (peer) => h.transport?.isDirect(peer) == true,
    send: (peer, text) => h.transport!.send(peer, text),
    onComplete: (_) => h.finished = true,
  );
  return transfer;
}

void _listenSwarm(_Harness h) {
  h.frameSubscription?.cancel();
  h.frameSubscription = h.transport!.frames.listen((frame) {
    h.incoming = h.incoming.then((_) => _handleFrame(h, frame)).catchError((
      Object error,
      StackTrace stack,
    ) {
      h.backgroundError = error;
      h.backgroundStack = stack;
    });
  });
}

Future<void> _handleFrame(_Harness h, GroupPeerFrame frame) async {
  h._throwBackgroundError();
  final text = frame.text;
  if (text.startsWith(_qaPrefix)) {
    final value =
        jsonDecode(text.substring(_qaPrefix.length)) as Map<String, dynamic>;
    switch (value['type']) {
      case 'file-event':
        final signed = value['event'] as String;
        final groupId = _sessionValue(_sessionGroupKey)!;
        final group = await h.crypto.groupCall('list', {});
        final views = (group['groups'] as List)
            .map(
              (item) =>
                  GroupView.fromJson(Map<String, dynamic>.from(item as Map)),
            )
            .where((item) => item.groupId == groupId)
            .toList();
        if (views.length != 1) {
          throw StateError('Accepted group state is missing');
        }
        h.manifest = await _inspectFileEvent(
          h.crypto,
          signed,
          groupId,
          views.single.epoch,
          views.single.ownerId,
        );
        h.signedEvent = signed;
        await h.cache!.begin(h.manifest!);
        h.contentPeers[frame.peerId] = h.manifest!.fileId;
        if (h.role == 'd') {
          await h.blobs.saveGroupBlob(
            h.ownerId,
            _resumeKey,
            jsonEncode({
              'groupId': groupId,
              'event': signed,
              'manifest': h.manifest!.toJson(),
            }),
          );
        }
      case 'seed-piece':
        if (h.role != 'b' && h.role != 'c' || h.manifest == null) return;
        if (frame.peerId != h.manifest!.uploaderId ||
            value['fileId'] != h.manifest!.fileId) {
          throw const FormatException('Unexpected QA piece source');
        }
        final index = value['index'],
            part = value['part'],
            count = value['count'];
        final encoded = value['bytes'];
        if (index is! int ||
            index < 0 ||
            index >= h.manifest!.pieceCount ||
            part is! int ||
            count is! int ||
            count < 1 ||
            count > 64 ||
            part < 0 ||
            part >= count ||
            encoded is! String ||
            encoded.length > 12000) {
          throw const FormatException('Invalid QA seed piece part');
        }
        final key = '${h.manifest!.fileId}:$index';
        final assembly = h.pieces.putIfAbsent(
          key,
          () => _SeedPieceAssembly(count),
        );
        if (assembly.count != count || assembly.parts.containsKey(part)) return;
        final data = base64Url.decode(base64Url.normalize(encoded));
        if (data.isEmpty || data.length > swarmPartSize) {
          throw const FormatException('QA piece part exceeded 8 KiB');
        }
        assembly.parts[part] = Uint8List.fromList(data);
        if (part == 0) {
          final proof = value['proof'];
          if (proof is! List || proof.any((entry) => entry is! String)) {
            throw const FormatException('QA piece proof is malformed');
          }
          assembly.proof = proof.cast<String>();
        } else if (value.containsKey('proof')) {
          throw const FormatException('Unexpected QA piece proof');
        }
        if (assembly.parts.length == count && assembly.proof != null) {
          final bytes = BytesBuilder(copy: false);
          for (var partIndex = 0; partIndex < count; partIndex++) {
            final piece = assembly.parts[partIndex];
            if (piece == null) return;
            bytes.add(piece);
          }
          await h.cache!.putPiece(
            h.manifest!,
            index,
            bytes.takeBytes(),
            assembly.proof!,
          );
          h.pieces.remove(key);
          h.receivedPieces++;
        }
      case 'd-complete':
        if (h.role == 'b' || h.role == 'c') h.dComplete = true;
      case 'swarm-frame':
        if (value['frame'] is! String || h.transfer == null) {
          throw const FormatException('Invalid QA swarm wrapper');
        }
        await h.transfer!.receive(frame.peerId, value['frame'] as String);
      default:
        throw const FormatException('Unknown QA control frame');
    }
    return;
  }
  if (text.startsWith('chta-swarm-v1:')) {
    if (h.transfer != null && !(h.paused && h.role == 'd')) {
      await h.transfer!.receive(frame.peerId, text);
    }
  }
}

Future<void> _sendQa(
  GroupTransport transport,
  String peer,
  Map<String, Object?> body,
) async => transport.send(peer, '$_qaPrefix${jsonEncode(body)}');

Future<void> _sendSeedPiece(
  _Harness h,
  String recipient,
  SwarmManifest manifest,
  int index,
  Uint8List bytes,
  List<String> proof,
) async {
  final count = (bytes.length + swarmPartSize - 1) ~/ swarmPartSize;
  for (var part = 0; part < count; part++) {
    final start = part * swarmPartSize;
    final end = (start + swarmPartSize).clamp(0, bytes.length);
    await _sendQa(h.transport!, recipient, {
      'type': 'seed-piece',
      'fileId': manifest.fileId,
      'index': index,
      'part': part,
      'count': count,
      'bytes': base64UrlEncode(bytes.sublist(start, end)),
      if (part == 0) 'proof': proof,
    });
  }
}

Future<void> _sendAvailability(_Harness h, String peer) async {
  final manifest = h.manifest!;
  final status = await h.cache!.status(manifest);
  final bitmap = Uint8List((manifest.pieceCount + 7) ~/ 8);
  for (final index in status.available) {
    bitmap[index ~/ 8] |= 1 << (index % 8);
  }
  await _sendQa(h.transport!, peer, {
    'type': 'swarm-frame',
    'frame':
        'chta-swarm-v1:${jsonEncode({'kind': 'have', 'fileId': manifest.fileId, 'manifest': manifest.identityHash, 'bits': base64UrlEncode(bitmap)})}',
  });
}

Future<void> _announceAvailability(_Harness h, Iterable<String> peers) async {
  for (final peer in peers) {
    await _sendAvailability(h, peer);
  }
}

Future<void> _downloadUntilComplete(_Harness h) async {
  _phase = 'swarm-tick';
  while (true) {
    if (_deadline == null || DateTime.now().isAfter(_deadline!)) {
      throw StateError('Timed out during $_phase');
    }
    await h.transfer!.tick();
    final status = await h.cache!.status(h.manifest!);
    if (status.complete) return;
    await Future<void>.delayed(const Duration(milliseconds: 120));
    h._throwBackgroundError();
  }
}

Future<String> _verifyComplete(_Harness h, SwarmManifest manifest) async {
  final status = await h.cache!.status(manifest);
  if (!status.complete || status.verifiedBytes != manifest.size) {
    throw StateError('Sparse swarm did not complete the verified file');
  }
  final file = await h.cache!.open(manifest);
  final digest = (await sha256.bind(file.openRead()).first).toString();
  if (digest != manifest.digest) throw StateError('Final file digest mismatch');
  return digest;
}

Future<void> _checkHashAndFinish(
  _Harness h,
  String digest,
  SwarmManifest manifest,
  int members,
) async {
  if (members != 4 || digest != manifest.digest) {
    throw StateError('Final four-member swarm proof did not match');
  }
  if (h.role == 'a' || h.role == 'd') {
    await h.waitRoles('crossfill', {'b', 'c'});
  }
  await h.arrive('crossfill');
  await h.waitRoles('crossfill', _roles);
  if (h.audit.containsGroupContent) {
    throw StateError('Group text or file metadata appeared on the public seed');
  }
  reportQa({
    'ok': true,
    'phase': 'done',
    'role': h.role,
    'digest': digest,
    'sourceCount': h.sourceCount,
    'verifiedBytes': manifest.size,
    'bytes': manifest.size,
    'seedContent': h.audit.containsGroupContent,
    'seedFrameTypes': h.audit.types,
  });
  await h.arrive('done');
  await h.waitRoles('done', _roles);
}

extension on _Harness {
  Future<void> _cleanup() async {
    await frameSubscription?.cancel();
    transfer?.close();
    await controller?.close();
    await transport?.close();
    await network?.close();
  }
}
