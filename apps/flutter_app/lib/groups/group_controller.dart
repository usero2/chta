import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../chat/attachment_store.dart';
import '../chat/chat_attachment.dart';
import '../chat/chat_models.dart';
import '../notifications/incoming_notifications.dart';
import 'group_blob_bridge.dart';
import 'group_crypto_bridge.dart';
import 'group_models.dart';
import 'group_transport.dart';
import 'swarm/swarm.dart';

const _docPrefix = 'chta-group-doc-v1:', _ackPrefix = 'chta-group-job-ack-v1:';
const _maxDocument = 4 * 1024 * 1024, _docPart = 8192, _pageMessages = 32;
const _maxOutboxBytes = 16 * 1024 * 1024, _maxHistoryMessages = 10000;

class GroupController extends ChangeNotifier {
  GroupController({
    required this.ownerId,
    required this.crypto,
    required this.blobs,
    required this.attachments,
    required this.displayName,
    this.notifications,
  }) {
    cache = SparseSwarmCache(ownerId, blobs: blobs, attachments: attachments);
    swarm = SwarmTransfer(
      ownerId,
      cache: cache,
      authorize: _authorizeFile,
      peers: _filePeers,
      isDirect: (peer) => _transport?.isDirect(peer) == true,
      send: (peer, text) => _transport!.send(peer, text),
      onComplete: _fileComplete,
    );
    swarm.addListener(_changed);
  }
  final String ownerId;
  final GroupCryptoBridge crypto;
  final GroupBlobBridge blobs;
  final AttachmentStore attachments;
  final String Function() displayName;
  final IncomingNotifications? notifications;
  late final SparseSwarmCache cache;
  late final SwarmTransfer swarm;
  GroupTransport? _transport;
  StreamSubscription<GroupPeerFrame>? _subscription;
  final _groups = <String, GroupView>{};
  final _rooms = <String, List<GroupMessage>>{};
  final _jobs = <String, GroupControlJob>{};
  final _invitations = <String, GroupInvitation>{};
  final _seenControls = <String>{},
      _left = <String>{},
      _completedFiles = <String>{};
  final _deleted = <String, Set<String>>{};
  final _roomGenerations = <String, int>{};
  final _documents = <String, _DocumentAssembly>{};
  final _syncedPeers = <String>{};
  Future<void> _serial = Future.value();
  Timer? _timer;
  bool _closed = false, _ready = false, _pulsing = false;
  int _generation = 0, _queued = 0;
  String? error;
  bool get ready => _ready;
  List<GroupView> get groups => List.unmodifiable(_groups.values);
  List<GroupInvitation> get invitations =>
      List.unmodifiable(_invitations.values);
  int get pendingJobCount => _jobs.length;
  int get pendingJobBytes =>
      _jobs.values.fold(0, (sum, j) => sum + j.encodedBytes);
  GroupView? group(String id) => _groups[id];
  List<GroupMessage> messagesFor(String id) =>
      List.unmodifiable(_rooms[id] ?? const []);
  bool canSend(String id) =>
      _ready &&
      !_closed &&
      !_left.contains(id) &&
      _groups[id]?.closed == false &&
      _groups[id]!.contains(ownerId);
  String? disabledReason(String id) {
    final g = _groups[id];
    if (g == null) return 'Group unavailable';
    if (g.closed) return 'Group closed';
    if (_left.contains(id)) return 'You left this group';
    if (!g.contains(ownerId)) return 'Waiting for group owner';
    return null;
  }

  int onlineCount(String id) =>
      _groups[id]?.members
          .where(
            (m) =>
                m.identityId != ownerId &&
                _transport?.connected(m.identityId) == true,
          )
          .length ??
      0;
  SwarmProgress? progressFor(String id) => swarm.progressFor(id);
  Future<ChatAttachment> openFile(SwarmManifest manifest) =>
      cache.open(manifest);
  List<ConversationView> get conversations => groups.map((g) {
    final last = _rooms[g.groupId]?.lastOrNull;
    return ConversationView(
      id: g.groupId,
      title: g.name,
      preview:
          last?.text ??
          (g.closed
              ? 'Group closed'
              : g.contains(ownerId)
              ? '${g.members.length} members'
              : 'Waiting for group owner'),
      updatedAtMilliseconds: last?.sentAt ?? 0,
      messages: const [],
    );
  }).toList();
  void _check(int generation) {
    if (_closed || generation != _generation) {
      throw StateError('Group identity changed');
    }
  }

  void _changed() {
    if (!_closed) notifyListeners();
  }

  Future<T> _run<T>(Future<T> Function() action) {
    if (_closed || _queued >= 256) {
      return Future<T>.error(StateError('Group work queue unavailable'));
    }
    final generation = _generation;
    _queued++;
    final result = _serial.catchError((Object _) {}).then((_) async {
      _check(generation);
      return action();
    });
    _serial = result
        .then<void>((_) {})
        .catchError((Object _) {})
        .whenComplete(() => _queued--);
    return result;
  }

  Map<String, dynamic> _map(Object? v) => Map<String, dynamic>.from(v as Map);
  String _roomKey(String id) => sha256.convert(utf8.encode(id)).toString();
  Future<Map<String, dynamic>?> _load(String key) async {
    final generation = _generation;
    final source = await blobs.loadGroupBlob(ownerId, key);
    _check(generation);
    return source == null ? null : _map(jsonDecode(source));
  }

  Future<void> _write(String key, Map<String, Object?> value) async {
    final generation = _generation;
    _check(generation);
    await blobs.saveGroupBlob(ownerId, key, jsonEncode(value));
    _check(generation);
  }

  Future<void> _views() async {
    final generation = _generation;
    final result = await crypto.groupCall('list', {});
    _check(generation);
    _groups.clear();
    for (final item in result['groups'] as List) {
      final view = GroupView.fromJson(_map(item));
      _groups[view.groupId] = view;
    }
  }

  Future<void> _saveIndex({
    Map<String, List<GroupMessage>>? rooms,
    Map<String, GroupControlJob>? jobs,
  }) async {
    final generation = _generation;
    final exported = await crypto.groupCall('export', {});
    _check(generation);
    await _write('groups-index-v1', {
      'version': 1,
      'core': exported['data'],
      'rooms': {
        for (final e in (rooms ?? _rooms).entries) e.key: e.value.length,
      },
      'jobs': (jobs ?? _jobs).keys.toList(),
      'invitations': _invitations.keys.toList(),
      'seen': _seenControls.toList(),
      'left': _left.toList(),
      'completedFiles': _completedFiles.toList(),
      'deleted': {for (final e in _deleted.entries) e.key: e.value.toList()},
      'generations': _roomGenerations,
    });
  }

  Future<void> _saveRoom(String id, {List<GroupMessage>? source}) async {
    final messages = source ?? _rooms[id] ?? const <GroupMessage>[];
    for (var start = 0; start < messages.length; start += _pageMessages) {
      await _write('g-room-${_roomKey(id)}-${start ~/ _pageMessages}', {
        'messages': messages
            .skip(start)
            .take(_pageMessages)
            .map((m) => m.toJson())
            .toList(),
      });
    }
  }

  Future<void> initialize() => _run(() async {
    if (_ready) return;
    final index = await _load('groups-index-v1');
    if (index != null) {
      if (index['version'] != 1) {
        throw const FormatException('Unsupported saved groups');
      }
      await crypto.groupCall('import', {'data': index['core']});
      _seenControls.addAll((index['seen'] as List? ?? []).cast<String>());
      _left.addAll((index['left'] as List? ?? []).cast<String>());
      _completedFiles.addAll(
        (index['completedFiles'] as List? ?? []).cast<String>(),
      );
      _roomGenerations.addAll(
        _map(index['generations'] ?? {}).cast<String, int>(),
      );
      for (final e in _map(index['deleted'] ?? {}).entries) {
        _deleted[e.key] = (e.value as List).cast<String>().toSet();
      }
      for (final e in _map(index['rooms'] ?? {}).entries) {
        final count = e.value as int;
        if (count < 0 || count > _maxHistoryMessages) {
          throw const FormatException('Saved group history is too large');
        }
        final messages = <GroupMessage>[];
        for (
          var page = 0;
          page < (count + _pageMessages - 1) ~/ _pageMessages;
          page++
        ) {
          final data = await _load('g-room-${_roomKey(e.key)}-$page');
          if (data == null) {
            throw const FormatException('Missing saved group history');
          }
          messages.addAll(
            (data['messages'] as List).map(
              (m) => GroupMessage.fromJson(_map(m)),
            ),
          );
        }
        _rooms[e.key] = messages
            .take(count)
            .where((m) => !(_deleted[e.key]?.contains(m.key) ?? false))
            .toList();
      }
      for (final id in (index['jobs'] as List? ?? []).cast<String>()) {
        final data = await _load('g-job-$id');
        if (data != null) {
          final job = GroupControlJob.fromJson(data);
          _jobs[id] = job;
        }
      }
      for (final id in (index['invitations'] as List? ?? []).cast<String>()) {
        final data = await _load('g-invite-$id');
        if (data != null) {
          final invite = GroupInvitation.fromJson(data);
          if (invite.expiresAt > DateTime.now().millisecondsSinceEpoch) {
            _invitations[id] = invite;
          }
        }
      }
    }
    await _views();
    await _finishLeftMemberships();
    for (final room in _rooms.values) {
      for (final message in room) {
        if (message.manifest != null && !_left.contains(message.groupId)) {
          swarm.register(message.manifest!);
        }
      }
    }
    _ready = true;
    _timer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_pulse()),
    );
    _changed();
  });
  Future<void> attachTransport(GroupTransport transport) async {
    if (_closed) {
      await transport.close();
      return;
    }
    if (_transport != null && _transport != transport) {
      throw StateError('Group transport already attached');
    }
    _transport = transport;
    transport.addListener(_transportChanged);
    _subscription ??= transport.frames.listen((frame) {
      unawaited(
        _run(() => _receive(frame.peerId, frame.text)).catchError((Object _) {
          /* Untrusted/future epochs remain unacknowledged for retry. */
        }),
      );
    });
    await transport.start();
    _transportChanged();
    unawaited(_pulse());
  }

  void _transportChanged() {
    if (_closed) return;
    final online = _transport?.onlinePeers ?? <String>{};
    _syncedPeers.removeWhere((p) => !online.contains(p));
    for (final peer in online.difference(_syncedPeers)) {
      _syncedPeers.add(peer);
      unawaited(
        _run(() async {
          for (final g in groups) {
            if (g.contains(ownerId) &&
                g.contains(peer) &&
                !_left.contains(g.groupId)) {
              await _queueStates(g, [peer]);
            }
          }
          await _saveIndex();
        }).catchError((Object _) {}),
      );
    }
    _changed();
  }

  Future<void> _pulse() async {
    if (_closed || !_ready || _pulsing) return;
    _pulsing = true;
    try {
      for (final room in _rooms.values.toList()) {
        for (final message in room.toList()) {
          final m = message.manifest;
          if (m != null &&
              swarm.progressFor(m.fileId)?.complete == true &&
              !_completedFiles.contains(m.fileId) &&
              canSend(m.groupId)) {
            _fileComplete(m);
          }
        }
      }
      final peers = <String>{
        for (final g in groups)
          if (canSend(g.groupId)) ...g.members.map((m) => m.identityId),
        ..._jobs.values.map((j) => j.peerId),
      }..remove(ownerId);
      final transport = _transport;
      if (transport != null) {
        for (final peer in peers) {
          try {
            await transport.connect(peer);
          } catch (_) {}
          if (_closed) return;
        }
        for (final job in _jobs.values.toList()) {
          if (!transport.connected(job.peerId) ||
              DateTime.now().millisecondsSinceEpoch - job.lastSent < 5000) {
            continue;
          }
          job.lastSent = DateTime.now().millisecondsSinceEpoch;
          try {
            await _sendDocument(job);
          } catch (_) {}
          if (_closed) return;
        }
        await swarm.tick();
      }
    } finally {
      _pulsing = false;
    }
  }

  String _jobKey(String peer, Map<String, dynamic> body) {
    if (body['type'] == 'states') return '$peer:states:${body['groupId']}';
    if (body['type'] == 'event') {
      final event = _map(jsonDecode(body['source'] as String));
      return '$peer:event:${event['groupId']}:${event['sender']}:${event['id']}';
    }
    return '$peer:${body['type']}:${sha256.convert(utf8.encode(jsonEncode(body)))}';
  }

  Future<GroupControlJob> _makeJob(
    String peer,
    Map<String, dynamic> body,
  ) async {
    final job = GroupControlJob(id: groupRandomId(), peerId: peer, body: body);
    if (job.encodedBytes > _maxDocument) {
      throw const FormatException('Group document too large');
    }
    await _write('g-job-${job.id}', job.toJson());
    return job;
  }

  Future<void> _job(String peer, Map<String, dynamic> body) async {
    final old = _jobs.values
        .where((j) => _jobKey(j.peerId, j.body) == _jobKey(peer, body))
        .firstOrNull;
    if (old != null && jsonEncode(old.body) == jsonEncode(body)) return;
    final candidate = GroupControlJob(
      id: groupRandomId(),
      peerId: peer,
      body: body,
    );
    if (_jobs.length - (old == null ? 0 : 1) >= 1024 ||
        pendingJobBytes - (old?.encodedBytes ?? 0) + candidate.encodedBytes >
            _maxOutboxBytes) {
      throw StateError('Group outbox is full');
    }
    if (candidate.encodedBytes > _maxDocument) {
      throw const FormatException('Group document too large');
    }
    await _write('g-job-${candidate.id}', candidate.toJson());
    final jobs = {..._jobs};
    if (old != null) jobs.remove(old.id);
    jobs[candidate.id] = candidate;
    await _saveIndex(jobs: jobs);
    _jobs.clear();
    _jobs.addAll(jobs);
    if (old != null) {
      unawaited(
        blobs
            .deleteGroupBlob(ownerId, 'g-job-${old.id}')
            .catchError((Object _) {}),
      );
    }
  }

  Future<void> _sendDocument(GroupControlJob job) async {
    final generation = _generation;
    final data = utf8.encode(job.encoded);
    final count = (data.length + _docPart - 1) ~/ _docPart;
    for (var i = 0; i < count; i++) {
      _check(generation);
      if (_jobs[job.id] != job) return;
      final end = ((i + 1) * _docPart).clamp(0, data.length);
      await _transport!.send(
        job.peerId,
        '$_docPrefix${jsonEncode({'id': job.id, 'i': i, 'n': count, 'data': base64Encode(data.sublist(i * _docPart, end))})}',
      );
    }
  }

  Future<String> createGroup(String name, List<String> peers) => _run(() async {
    if (!_ready ||
        peers.toSet().length != peers.length ||
        peers.length > 15 ||
        peers.contains(ownerId)) {
      throw const FormatException('Choose up to 15 friends');
    }
    final generation = _generation;
    final result = await crypto.groupCall('create', {
      'name': name.trim(),
      'displayName': _name,
      'now': DateTime.now().millisecondsSinceEpoch,
    });
    _check(generation);
    await _views();
    final gid = _groups.values
        .firstWhere(
          (g) =>
              g.states.lastOrNull == result['state'] ||
              g.groupId == jsonDecode(result['state'] as String)['groupId'],
        )
        .groupId;
    _rooms.putIfAbsent(gid, () => []);
    await _saveIndex();
    error = null;
    for (final peer in peers) {
      try {
        await _invite(gid, peer);
      } catch (_) {
        error = 'Group created. Retry invitations from Group details.';
      }
    }
    _changed();
    unawaited(_pulse());
    return gid;
  });
  String get _name =>
      displayName().trim().isEmpty ? 'Member' : displayName().trim();
  Future<void> _invite(String gid, String peer) async {
    final result = await crypto.groupCall('invite', {
      'groupId': gid,
      'peerId': peer,
      'now': DateTime.now().millisecondsSinceEpoch,
    });
    await _job(peer, {'type': 'invite', 'source': result['invite']});
  }

  Future<void> invite(String gid, String peer) => _run(() async {
    await _invite(gid, peer);
    await _saveIndex();
    _changed();
    unawaited(_pulse());
  });
  Future<void> acceptInvitation(String id) => _run(() async {
    final invite = _invitations[id];
    if (invite == null) return;
    final result = await crypto.groupCall('accept', {
      'invite': invite.source,
      'displayName': _name,
      'now': DateTime.now().millisecondsSinceEpoch,
    });
    await _job(invite.ownerId, {
      'type': 'receipt',
      'source': result['receipt'],
    });
    _invitations.remove(id);
    await _views();
    _rooms.putIfAbsent(invite.groupId, () => []);
    await _saveIndex();
    _changed();
    unawaited(_pulse());
  });
  Future<void> declineInvitation(String id) => _run(() async {
    _invitations.remove(id);
    await _saveIndex();
    _changed();
  });
  Future<void> _queueStates(
    GroupView group,
    Iterable<String> recipients,
  ) async {
    for (final peer in recipients.toSet()) {
      if (peer != ownerId) {
        await _job(peer, {
          'type': 'states',
          'groupId': group.groupId,
          'states': group.states,
        });
      }
    }
  }

  Future<void> removeMember(String gid, String peer) => _run(() async {
    final old = _groups[gid]!;
    await crypto.groupCall('remove', {
      'groupId': gid,
      'peerId': peer,
      'now': DateTime.now().millisecondsSinceEpoch,
    });
    await _views();
    await _queueStates(_groups[gid]!, old.members.map((m) => m.identityId));
    await _saveIndex();
    _changed();
    unawaited(_pulse());
  });
  Future<void> leaveGroup(String gid) => _run(() async {
    final old = _groups[gid]!;
    if (!old.contains(ownerId)) {
      _left.add(gid);
      _cancelGroupJobs(gid);
      await _saveIndex();
      _changed();
      return;
    }
    final result = await crypto.groupCall('leave', {
      'groupId': gid,
      'now': DateTime.now().millisecondsSinceEpoch,
    });
    if (result['state'] is String) {
      await _views();
      await _queueStates(_groups[gid]!, old.members.map((m) => m.identityId));
    } else {
      await _job(old.ownerId, {'type': 'event', 'source': result['event']});
    }
    _left.add(gid);
    _cancelGroupJobs(gid, keepMembership: true);
    await _saveIndex();
    _changed();
    unawaited(_pulse());
  });
  Future<void> _finishLeftMemberships() async {
    for (final gid in _left.toList()) {
      final g = _groups[gid];
      if (g == null ||
          g.closed ||
          g.ownerId == ownerId ||
          !g.contains(ownerId)) {
        continue;
      }
      final pendingLeave = _jobs.values.any((j) {
        try {
          final event = _map(jsonDecode(j.body['source'] as String));
          return j.body['type'] == 'event' &&
              event['groupId'] == gid &&
              event['kind'] == 'leave';
        } catch (_) {
          return false;
        }
      });
      if (pendingLeave) continue;
      final result = await crypto.groupCall('leave', {
        'groupId': gid,
        'now': DateTime.now().millisecondsSinceEpoch,
      });
      await _job(g.ownerId, {'type': 'event', 'source': result['event']});
    }
  }

  Future<bool> sendText(String gid, String text) async {
    if (_closed || text.trim().isEmpty) return false;
    try {
      return await _run(() async {
        await _post(gid, 'message', {'text': text.trim()});
        return true;
      });
    } catch (_) {
      if (!_closed) {
        error = 'Could not save the message.';
        _changed();
      }
      return false;
    }
  }

  Future<bool> sendBatch(
    String gid,
    String caption,
    List<ChatAttachment> files,
  ) async {
    if (!canSend(gid)) return false;
    final generation = _generation, roomGeneration = _roomGenerations[gid] ?? 0;
    try {
      if (files.length > 5) {
        throw const FormatException('Attach up to five files');
      }
      if (files.isEmpty) return await sendText(gid, caption);
      for (var index = 0; index < files.length; index++) {
        final g = _groups[gid]!;
        final file = files[index].withPresentation(
          caption: index == 0 ? caption : files[index].caption,
        );
        final manifest = await cache.importFile(
          groupId: gid,
          epoch: g.epoch,
          uploaderId: ownerId,
          fileId: groupRandomId(),
          file: file,
        );
        _check(generation);
        if ((_roomGenerations[gid] ?? 0) != roomGeneration) return false;
        await _run(() => _post(gid, 'file', manifest.toJson()));
      }
      return true;
    } catch (_) {
      if (!_closed) {
        error = 'Could not prepare the attachment.';
        _changed();
      }
      return false;
    }
  }

  Future<void> _post(
    String gid,
    String kind,
    Map<String, Object?> payload,
  ) async {
    if (!canSend(gid)) throw StateError('Group unavailable');
    final g = _groups[gid]!,
        recipients = g.members
            .map((m) => m.identityId)
            .where((id) => id != ownerId)
            .toList();
    if ((_rooms[gid]?.length ?? 0) >= _maxHistoryMessages) {
      throw StateError('Local group history is full');
    }
    if (kind == 'file' && payload['epoch'] != g.epoch) {
      throw StateError('Group membership changed; send the attachment again');
    }
    if (_jobs.length + recipients.length > 1024) {
      throw StateError('Group outbox is full');
    }
    final id = groupRandomId();
    final signed = await crypto.groupCall('sign', {
      'groupId': gid,
      'id': id,
      'kind': kind,
      'payload': jsonEncode(payload),
      'now': DateTime.now().millisecondsSinceEpoch,
    });
    final event = signed['event'] as String;
    final time = (jsonDecode(event) as Map)['sentAt'] as int;
    final manifest = kind == 'file'
        ? SwarmManifest.fromJson(Map<String, dynamic>.from(payload))
        : null;
    final m = GroupMessage(
      id: id,
      groupId: gid,
      senderId: ownerId,
      senderName: _name,
      text: manifest?.caption ?? manifest?.name ?? payload['text'] as String,
      event: event,
      sentAt: time,
      recipients: recipients,
      manifest: manifest,
    );
    final estimate = recipients
        .map(
          (peer) => GroupControlJob(
            id: '0' * 32,
            peerId: peer,
            body: {'type': 'event', 'source': event},
          ),
        )
        .toList();
    if (pendingJobBytes +
            estimate.fold<int>(0, (sum, j) => sum + j.encodedBytes) >
        _maxOutboxBytes) {
      throw StateError('Group outbox is full');
    }
    final staged = <GroupControlJob>[];
    try {
      for (final peer in recipients) {
        staged.add(await _makeJob(peer, {'type': 'event', 'source': event}));
      }
      final room = [...?_rooms[gid], m],
          rooms = {..._rooms, gid: room},
          jobs = {..._jobs, for (final j in staged) j.id: j};
      await _saveRoom(gid, source: room);
      await _saveIndex(rooms: rooms, jobs: jobs);
      _rooms[gid] = room;
      _jobs.addAll({for (final j in staged) j.id: j});
    } catch (_) {
      for (final j in staged) {
        unawaited(
          blobs
              .deleteGroupBlob(ownerId, 'g-job-${j.id}')
              .catchError((Object _) {}),
        );
      }
      rethrow;
    }
    if (manifest != null) swarm.register(manifest);
    error = null;
    _changed();
    unawaited(_pulse());
  }

  Future<void> _receive(String peer, String text) async {
    if (text.startsWith(_ackPrefix)) {
      final id = text.substring(_ackPrefix.length),
          job = _jobs[text.substring(_ackPrefix.length)];
      if (job?.peerId == peer) {
        _jobs.remove(id);
        await _saveIndex();
        unawaited(
          blobs.deleteGroupBlob(ownerId, 'g-job-$id').catchError((Object _) {}),
        );
        _changed();
      }
      return;
    }
    if (text.startsWith('chta-swarm-v1:')) {
      await swarm.receive(peer, text);
      return;
    }
    if (!text.startsWith(_docPrefix) || utf8.encode(text).length > 16384) {
      return;
    }
    final p = _map(jsonDecode(text.substring(_docPrefix.length)));
    final id = p['id'], index = p['i'], count = p['n'], encoded = p['data'];
    if (p.length != 4 ||
        id is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(id) ||
        index is! int ||
        count is! int ||
        count < 1 ||
        count > 512 ||
        index < 0 ||
        index >= count ||
        encoded is! String ||
        encoded.length > 10924) {
      throw const FormatException('Invalid group document part');
    }
    final bytes = base64Decode(encoded);
    if (bytes.length > _docPart ||
        index < count - 1 && bytes.length != _docPart) {
      throw const FormatException('Invalid document size');
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    _documents.removeWhere((_, d) => now - d.started > 30000);
    final key = '$peer:$id';
    var doc = _documents[key];
    if (doc == null) {
      if (_documents.length >= 4) throw StateError('Group document queue full');
      doc = _DocumentAssembly(count, now);
      _documents[key] = doc;
    }
    if (doc.parts.length != count) {
      throw const FormatException('Conflicting document parts');
    }
    if (doc.parts[index] != null && !listEquals(doc.parts[index], bytes)) {
      throw const FormatException('Conflicting duplicate part');
    }
    doc.parts[index] = bytes;
    if (doc.parts.any((p) => p == null)) return;
    _documents.remove(key);
    final data = BytesBuilder(copy: false);
    for (final part in doc.parts) {
      data.add(part!);
    }
    if (data.length > _maxDocument) {
      throw const FormatException('Group document too large');
    }
    final body = _map(jsonDecode(utf8.decode(data.takeBytes())));
    if (body['v'] != 1 || body['jobId'] != id) {
      throw const FormatException('Invalid group document');
    }
    if (!_seenControls.contains(key)) {
      await _control(peer, body);
      _seenControls.add(key);
      if (_seenControls.length > 8192) {
        _seenControls.remove(_seenControls.first);
      }
      _changed();
    }
    await _saveIndex();
    await _transport?.send(peer, '$_ackPrefix$id');
  }

  Future<void> _control(String peer, Map<String, dynamic> body) async {
    switch (body['type']) {
      case 'invite':
        final source = body['source'] as String;
        final info = await crypto.groupCall('inspectInvite', {
          'invite': source,
          'now': DateTime.now().millisecondsSinceEpoch,
        });
        if (info['ownerId'] != peer) {
          throw const FormatException('Wrong invitation owner');
        }
        final id = sha256
            .convert(utf8.encode(source))
            .toString()
            .substring(0, 32);
        if (_invitations.length >= 32 && !_invitations.containsKey(id)) {
          throw StateError('Too many group invitations');
        }
        final invite = GroupInvitation(
          id: id,
          source: source,
          groupId: info['groupId'] as String,
          name: info['name'] as String,
          ownerId: peer,
          expiresAt: info['expiresAt'] as int,
        );
        await _write('g-invite-$id', invite.toJson());
        _invitations[id] = invite;
      case 'receipt':
        final source = body['source'] as String;
        String? gid;
        try {
          final added = await crypto.groupCall('add', {
            'receipt': source,
            'now': DateTime.now().millisecondsSinceEpoch,
          });
          gid = _map(jsonDecode(added['state'] as String))['groupId'] as String;
        } catch (_) {
          final receipt = _map(jsonDecode(source)),
              invite = _map(jsonDecode(receipt['invite'] as String)),
              state = _map(jsonDecode(invite['state'] as String));
          gid = state['groupId'] as String;
          final existing = _groups[gid];
          if (existing == null ||
              existing.ownerId != ownerId ||
              !existing.contains(peer)) {
            rethrow;
          }
        }
        await _views();
        final g = _groups[gid]!;
        await _queueStates(g, g.members.map((m) => m.identityId));
      case 'states':
        final gid = body['groupId'] as String, old = _groups[body['groupId']];
        if (old == null || !old.contains(peer) && old.ownerId != peer) {
          throw const FormatException('Unknown group state sender');
        }
        final states = (body['states'] as List).cast<String>();
        if (states.length > 256) {
          throw const FormatException('Group chain too long');
        }
        for (final state in states) {
          if (old.states.contains(state)) continue;
          await crypto.groupCall('apply', {'state': state});
        }
        await _views();
        _rooms.putIfAbsent(gid, () => []);
        if (!canSend(gid)) _cancelGroupJobs(gid);
        await _finishLeftMemberships();
      case 'event':
        await _event(peer, body['source'] as String);
      default:
        throw const FormatException('Unsupported group control');
    }
  }

  Future<void> _event(String peer, String source) async {
    final e = await crypto.groupCall('inspect', {'event': source});
    final gid = e['groupId'] as String,
        sender = e['sender'] as String,
        id = e['id'] as String;
    if (sender != peer || _left.contains(gid)) {
      throw const FormatException('Group event sender mismatch');
    }
    final payload = _map(jsonDecode(e['payload'] as String));
    final g = _groups[gid]!;
    if (e['kind'] == 'ack') {
      final m = _rooms[gid]
          ?.where(
            (m) =>
                m.id == payload['messageId'] &&
                m.senderId == payload['senderId'],
          )
          .firstOrNull;
      if (m != null &&
          m.senderId == ownerId &&
          m.recipients.contains(peer) &&
          payload['receivedAt'] is int) {
        m.receipts.putIfAbsent(peer, () => payload['receivedAt'] as int);
        await _saveRoom(gid);
      }
      return;
    }
    if (e['kind'] == 'leave') {
      if (g.ownerId == ownerId) {
        final old = g;
        await crypto.groupCall('remove', {
          'groupId': gid,
          'peerId': peer,
          'now': DateTime.now().millisecondsSinceEpoch,
        });
        await _views();
        await _queueStates(_groups[gid]!, old.members.map((m) => m.identityId));
      }
      return;
    }
    final key = '$sender:$id';
    if (_deleted[gid]?.contains(key) == true) return;
    final room = _rooms.putIfAbsent(gid, () => []);
    final existing = room.where((m) => m.key == key).firstOrNull;
    GroupMessage message;
    if (existing != null) {
      message = existing;
    } else {
      final manifest = e['kind'] == 'file'
          ? SwarmManifest.fromJson(payload)
          : null;
      if (manifest != null &&
          (manifest.groupId != gid ||
              manifest.uploaderId != sender ||
              manifest.epoch != e['epoch'])) {
        throw const FormatException('Manifest group binding mismatch');
      }
      if (manifest == null &&
          (payload.length != 1 || payload['text'] is! String)) {
        throw const FormatException('Invalid group message');
      }
      message = GroupMessage(
        id: id,
        groupId: gid,
        senderId: sender,
        senderName: g.nameFor(sender),
        text: manifest?.caption ?? manifest?.name ?? payload['text'] as String,
        event: source,
        sentAt: e['sentAt'] as int,
        receivedAt: DateTime.now().millisecondsSinceEpoch,
        recipients: const [],
        manifest: manifest,
      );
      if (room.length >= _maxHistoryMessages) {
        throw StateError('Local group history is full');
      }
      room.add(message);
    }
    await _saveRoom(gid);
    await _saveIndex();
    if (message.manifest != null) {
      swarm.register(message.manifest!);
      if (_completedFiles.contains(message.manifest!.fileId)) {
        await _receipt(message);
      }
    } else {
      await _receipt(message);
      await notifications?.notifyIncoming(
        peerId: gid,
        displayName: '${g.name} · ${message.senderName}',
        messageId: key,
      );
    }
  }

  Future<void> _receipt(GroupMessage message) async {
    if (!canSend(message.groupId)) return;
    final signed = await crypto.groupCall('sign', {
      'groupId': message.groupId,
      'id': 'ack-${message.id}',
      'kind': 'ack',
      'payload': jsonEncode({
        'messageId': message.id,
        'senderId': message.senderId,
        'receivedAt': DateTime.now().millisecondsSinceEpoch,
      }),
      'now': DateTime.now().millisecondsSinceEpoch,
    });
    await _job(message.senderId, {'type': 'event', 'source': signed['event']});
  }

  Future<bool> _authorizeFile(String peer, SwarmManifest m) async {
    if (_closed || _left.contains(m.groupId) || !canSend(m.groupId)) {
      return false;
    }
    final result = await crypto.groupCall('authorize', {
      'peerId': peer,
      'groupId': m.groupId,
      'epoch': m.epoch,
    });
    return !_closed && result['allowed'] == true;
  }

  List<String> _filePeers(SwarmManifest m) =>
      _groups[m.groupId]?.members
          .map((m) => m.identityId)
          .where((id) => id != ownerId && _transport?.connected(id) == true)
          .toList() ??
      [];
  void _fileComplete(SwarmManifest manifest) {
    if (_closed || _completedFiles.contains(manifest.fileId)) return;
    unawaited(
      _run(() async {
        if (_completedFiles.contains(manifest.fileId)) return;
        final message = _rooms[manifest.groupId]
            ?.where((m) => m.manifest?.fileId == manifest.fileId)
            .firstOrNull;
        if (message == null) return;
        _completedFiles.add(manifest.fileId);
        try {
          if (message.senderId != ownerId) {
            await _receipt(message);
          }
          await _saveIndex();
        } catch (_) {
          _completedFiles.remove(manifest.fileId);
          rethrow;
        }
        _changed();
        if (message.senderId != ownerId) {
          await notifications?.notifyIncoming(
            peerId: manifest.groupId,
            displayName:
                '${_groups[manifest.groupId]?.name ?? 'Group'} · ${message.senderName}',
            messageId: message.key,
            fileName: manifest.name,
            kind: IncomingNotificationKind.file,
          );
        }
      }).catchError((Object _) {}),
    );
  }

  void _cancelGroupJobs(String gid, {bool keepMembership = false}) {
    _jobs.removeWhere((_, job) {
      try {
        final type = job.body['type'];
        if (type == 'states') {
          return job.body['groupId'] == gid &&
              !(keepMembership && _groups[gid]?.closed == true);
        }
        if (type == 'event') {
          final event = _map(jsonDecode(job.body['source'] as String));
          return event['groupId'] == gid &&
              !(keepMembership && event['kind'] == 'leave');
        }
        var invite = _map(jsonDecode(job.body['source'] as String));
        if (type == 'receipt') {
          invite = _map(jsonDecode(invite['invite'] as String));
        }
        return _map(jsonDecode(invite['state'] as String))['groupId'] == gid;
      } catch (_) {
        return false;
      }
    });
  }

  Future<void> clearConversation(String gid) => _run(() async {
    _roomGenerations[gid] = (_roomGenerations[gid] ?? 0) + 1;
    final deleted = _deleted.putIfAbsent(gid, () => {});
    deleted.addAll((_rooms[gid] ?? []).map((m) => m.key));
    _rooms[gid] = [];
    _cancelGroupJobs(gid);
    await _saveIndex();
    _changed();
  });
  Future<void> flush() => _serial;
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _generation++;
    _timer?.cancel();
    await _subscription?.cancel();
    _transport?.removeListener(_transportChanged);
    await _transport?.close();
    swarm.removeListener(_changed);
    swarm.close();
    _documents.clear();
    await _serial;
    super.dispose();
  }
}

class _DocumentAssembly {
  _DocumentAssembly(int count, this.started)
    : parts = List<Uint8List?>.filled(count, null);
  final int started;
  final List<Uint8List?> parts;
}
