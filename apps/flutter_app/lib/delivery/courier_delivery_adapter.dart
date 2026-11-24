import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../account/account_models.dart';
import '../chat/chat_attachment.dart';
import '../chat/chunked_attachment_bridge.dart';
import '../chat/peer_history.dart';
import '../courier/courier_builder.dart';
import '../courier/courier_journal.dart';
import '../courier/courier_models.dart';
import '../courier/courier_policy.dart';
import '../courier/courier_receiver.dart';
import '../courier/courier_service.dart';
import '../courier/sender_job.dart';
import '../groups/group_controller.dart';
import '../groups/group_models.dart';
import '../relay/relay_chat.dart';
import 'delivery_envelope.dart';
import 'peer_delivery_sink.dart';
import 'group_delivery_sink.dart';
import 'local_diagnostics.dart';

/// One account-owned offline route. Network navigation never owns this queue.
/// A storage acknowledgement advances to Sent; only the recipient advances to
/// Delivered, after its ordinary encrypted cache and history have committed.
class CourierDeliveryAdapter extends ChangeNotifier {
  CourierDeliveryAdapter({
    required this.service,
    required this.history,
    required this.contacts,
    this.cache,
    this.automatic = true,
    int Function()? clock,
    bool Function()? isCurrent,
  }) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
       _isCurrent = isCurrent ?? (() => true) {
    sink = PeerDeliverySink(
      ownerId: service.ownerId,
      crypto: service.crypto,
      history: history,
      isTrusted: (id) => _contact(id)?.verified == true,
      isCurrent: () => active,
    );
    builder = CourierBuilder(
      jobs: service.jobs,
      crypto: service.crypto,
      budget: service.budget,
      clock: _clock,
    );
    receiver = CourierReceiver(
      ownerId: service.ownerId,
      crypto: service.crypto,
      service: service,
      journal: CourierJournal(
        ownerId: service.ownerId,
        namespace: 'courier_inbox',
        storage: service.storage,
        isCurrent: () => active,
      ),
      cache: cache,
      budget: service.budget,
      authorize: (e) => e.scope.startsWith('group:')
          ? groupSink?.authorize(e) ?? Future.value(false)
          : sink.authorize(e),
      isDeleted: (e) => e.scope.startsWith('group:')
          ? groupSink?.isDeleted(e) ?? true
          : sink.isDeleted(e),
      existingReceivedAt: (e) => e.scope.startsWith('group:')
          ? groupSink?.existingReceivedAt(e) ?? Future.value(null)
          : sink.existingReceivedAt(e),
      cachedEnvelope: (e) => e.scope.startsWith('group:')
          ? groupSink?.cachedEnvelope(e)
          : sink.cachedEnvelope(e),
      referencesFile: sink.referencesFile,
      commit: (received) {
        if (received.envelope.scope.startsWith('group:')) {
          final handler = groupSink;
          if (handler == null) throw StateError('Groups not ready');
          return handler.commit(received);
        }
        return sink.commit(received);
      },
      clock: _clock,
      isCurrent: () => active,
      onProgress: (e, bytes, total) {
        if (active) {
          _incoming[e.authorId] ??= {};
          if (bytes >= total) {
            _incoming[e.authorId]!.remove(e.messageId);
          } else {
            _incoming[e.authorId]![e.messageId] = bytes / total;
          }
          notifyListeners();
        }
      },
    );
  }
  final CourierService service;
  final PeerHistory history;
  final Iterable<ContactView> Function() contacts;
  final ChunkedAttachmentBridge? cache;
  final bool automatic;
  final int Function() _clock;
  final bool Function() _isCurrent;
  late final PeerDeliverySink sink;
  late final CourierBuilder builder;
  late final CourierReceiver receiver;
  GroupDeliverySink? groupSink;
  int _groupCursor = 0;
  final _groupOffsets = <String, int>{};
  void attachGroups(GroupController controller) {
    _guard();
    if (controller.ownerId != service.ownerId) {
      throw StateError('Group identity mismatch');
    }
    if (groupSink?.controller == controller) return;
    groupSink = GroupDeliverySink(
      controller: controller,
      crypto: service.crypto,
      isCurrent: () => active,
    );
    controller.setCourierEnabled(true);
    controller.onGapRepaired = () =>
        service.diagnostics.count(DeliveryMetric.repaired);
    if (automatic) unawaited(pump());
  }

  final _preparing = <String, Future<void>>{},
      _depositing = <String>{},
      _checking = <String>{},
      _receiving = <String>{};
  final _queueing = <String, Future<void>>{};
  final _offers = <String, Map<String, CourierOffer>>{},
      _retryAt = <String, int>{},
      _pages = <String, int>{};
  final _incoming = <String, Map<String, double>>{};
  final errors = <String, String>{};
  final _observedJobs = <String, CourierJobStatus>{};
  String? _presented;
  bool _sawSeedQuota = false;
  void _present() {
    if (!active) return;
    final jobs = service.jobs.jobs.toList();
    final current = jobs.map((j) => j.id).toSet();
    _observedJobs.removeWhere((key, _) => !current.contains(key));
    for (final job in jobs) {
      final previous = _observedJobs[job.id];
      if (previous != job.status) {
        final metric = switch (job.status) {
          CourierJobStatus.waitingForNodes => DeliveryMetric.courierWaiting,
          CourierJobStatus.stored => DeliveryMetric.courierDeposited,
          CourierJobStatus.expired => DeliveryMetric.courierExpired,
          _ => null,
        };
        if (metric != null &&
            (previous != null ||
                job.status == CourierJobStatus.waitingForNodes)) {
          service.diagnostics.count(metric);
        }
        _observedJobs[job.id] = job.status;
      }
    }
    final quota = service.seed?.storageUnavailable == true;
    if (quota && !_sawSeedQuota) {
      service.diagnostics.count(DeliveryMetric.seedQuotaUnavailable);
    }
    _sawSeedQuota = quota;
    final snapshot = jsonEncode([
      service.directory.nodes.length,
      for (final j in jobs) [j.id, j.status.name],
      errors,
    ]);
    if (snapshot == _presented) return;
    _presented = snapshot;
    notifyListeners();
  }

  String? labelFor(String peer, PeerMessage message) {
    if (!ready ||
        !message.queuedForDelivery ||
        message.status == DeliveryStatus.delivered) {
      return null;
    }
    final id = message.courierJobId,
        job = id == null ? null : service.jobs.find(id);
    if (job != null) {
      return errors[message.id] ??
          courierStatusLabel(job.status, service.availableDepositRoots);
    }
    if (id != null && errors.containsKey(message.id)) return errors[message.id];
    if (!canQueue(peer)) return 'Offline delivery needs an updated app';
    return null;
  }

  String? groupLabelFor(GroupMessage message) {
    if (!ready || message.recipients.every(message.receipts.containsKey)) {
      return null;
    }
    final jobs = message.courierJobs.entries
        .where((e) => !message.receipts.containsKey(e.key))
        .map((e) => service.jobs.find(e.value))
        .nonNulls
        .toList();
    if (jobs.isEmpty) return errors[message.id];
    final status = jobs
        .firstWhere((job) => !job.terminal, orElse: () => jobs.first)
        .status;
    return courierStatusLabel(status, service.availableDepositRoots);
  }

  Timer? _timer;
  bool _closed = false, _started = false, _pumping = false;
  int _nodeCursor = 0;
  int _depositCursor = 0;
  bool get active =>
      !_closed && _isCurrent() && history.ownerId == service.ownerId;
  bool get ready => active && _started && service.ready;
  int get activePickups => _receiving.length;
  ContactView? _contact(String id) =>
      contacts().where((c) => c.identityId == id).firstOrNull;
  bool canQueue(String peer) =>
      ready &&
      _contact(peer)?.verified == true &&
      _contact(peer)!.capabilities.contains('courier-v1');
  Map<String, double> incomingFor(String? peer) => _incoming[peer] ?? const {};
  void _guard() {
    if (!active) throw StateError('Delivery identity changed');
  }

  bool _owns(String peer, PeerMessage message) =>
      active &&
      !message.incoming &&
      message.queuedForDelivery &&
      !message.deliveryPaused &&
      _contact(peer)?.verified == true &&
      history.messagesFor(peer).contains(message);
  Future<void> start() async {
    _guard();
    if (_started) return;
    await service.start();
    await receiver.initialize();
    _guard();
    _started = true;
    if (automatic) {
      _timer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => unawaited(pump()),
      );
      unawaited(pump());
    }
  }

  Future<DeliveryEnvelope> envelopeFor(String peer, PeerMessage message) async {
    _guard();
    final saved = message.deliveryEnvelope;
    if (saved != null) {
      final e = DeliveryEnvelope.fromJson(saved);
      if (e.authorId != service.ownerId ||
          e.messageId != message.id ||
          e.scope != directDeliveryScope(service.ownerId, peer) ||
          e.sentAt != message.sentAtMilliseconds) {
        throw const FormatException('Delivery proof mismatch');
      }
      return e;
    }
    final payload = <String, Object?>{'text': message.text};
    var kind = 'text';
    if (message.hasAttachment) {
      final file = await history.resolveAttachment(message);
      _guard();
      final hash =
          message.attachmentRef?.digest ??
          (await sha256.bind(file.openRead()).first).toString();
      _guard();
      kind = ['image', 'video', 'audio'].contains(file.kind)
          ? file.kind
          : 'file';
      payload['file'] = {
        'name': file.name,
        'mime': file.mimeType,
        'size': file.size,
        'digest': hash,
        'caption': ?file.caption,
        'groupId': ?file.groupId,
        'groupIndex': ?file.groupIndex,
        'groupCount': ?file.groupCount,
      };
    }
    final e = await DeliveryEnvelope.create(
      service.crypto,
      scope: directDeliveryScope(service.ownerId, peer),
      messageId: message.id,
      sentAt: message.sentAtMilliseconds!,
      kind: kind,
      payload: payload,
    );
    _guard();
    if (!_owns(peer, message)) throw StateError('Message changed');
    message.deliveryEnvelope = e.toJson();
    history.changed(peer);
    await history.flush();
    _guard();
    if (history.error != null) {
      throw StateError('Could not save delivery proof');
    }
    return e;
  }

  Future<String> liveText(String peer, PeerMessage message) async {
    if (_contact(peer)?.capabilities.contains('delivery-v2') != true) {
      return message.text;
    }
    final e = await envelopeFor(peer, message), wire = e.toWire();
    // Noise message limits include the signature. Oversized legacy text retains
    // its existing live path; the protected envelope remains available offline.
    return RelayChat.messageFits(wire) ? wire : message.text;
  }

  Future<void> queue(String peer, PeerMessage message) {
    final key = '$peer\u0000${message.id}', old = _queueing[key];
    if (old != null) return old;
    if (_queueing.length >= 2) {
      return Future.error(StateError('Offline preparation busy'));
    }
    final work = _queue(peer, message);
    _queueing[key] = work;
    unawaited(
      work.then<void>(
        (_) {
          _queueing.remove(key);
        },
        onError: (Object _, StackTrace _) {
          _queueing.remove(key);
        },
      ),
    );
    return work;
  }

  Future<void> _queue(String peer, PeerMessage message) async {
    _guard();
    if (!canQueue(peer) || !_owns(peer, message)) {
      throw StateError('Offline delivery unavailable for this friend');
    }
    final preparationKey = '$peer\u0000${message.id}';
    if (_preparing.containsKey(preparationKey) || _preparing.length >= 2) {
      return;
    }
    final jobId = message.courierJobId ?? RelayChat.randomId();
    message.courierJobId = jobId;
    history.changed(peer);
    await history.flush();
    _guard();
    if (history.error != null || !_owns(peer, message)) {
      throw StateError('Could not save offline intent');
    }
    final old = service.jobs.find(jobId);
    if (old?.status == CourierJobStatus.paused) {
      await service.jobs.resume(jobId);
    }
    if (old?.terminal == true) {
      errors[message.id] = old!.status == CourierJobStatus.expired
          ? 'Offline delivery expired'
          : 'Offline delivery stopped';
      return;
    }
    if (old?.manifest != null) {
      if (automatic) unawaited(pump());
      return;
    }
    // Queueing returns promptly. Hashing/preparation never blocks the live
    // Router timeout or another conversation's text lane.
    final work = () async {
      try {
        final e = await envelopeFor(peer, message);
        if (!_owns(peer, message)) return;
        final ChatAttachment? file = message.hasAttachment
            ? await history.resolveAttachment(message)
            : null;
        await builder.prepare(
          id: jobId,
          peerId: peer,
          envelope: e,
          file: file,
          isCurrent: () => _owns(peer, message),
        );
        if (!_owns(peer, message)) return;
        await service.jobs.allocate(
          jobId,
          service.directory.nodes
              .where((n) => n.ownerId != service.ownerId)
              .toList(),
        );
        errors.remove(message.id);
      } catch (_) {
        if (active) errors[message.id] = 'Could not prepare offline delivery';
      }
    }();
    _preparing[preparationKey] = work;
    unawaited(
      work.whenComplete(() {
        _preparing.remove(preparationKey);
        if (active) {
          notifyListeners();
          if (automatic) unawaited(pump());
        }
      }),
    );
  }

  Future<void> settlePreparations() async {
    while (_queueing.isNotEmpty || _preparing.isNotEmpty) {
      await Future.wait([..._queueing.values, ..._preparing.values]);
    }
  }

  Future<int> receiveLive(
    String peer,
    String id,
    String wire,
    int? sentAt,
    int receivedAt,
  ) async {
    _guard();
    final e = DeliveryEnvelope.fromWire(wire);
    if (e.authorId != peer ||
        e.messageId != id ||
        e.sentAt != sentAt ||
        e.payload['file'] != null) {
      throw const FormatException('Live delivery binding mismatch');
    }
    await sink.verify(e);
    final previous = await sink.existingReceivedAt(e);
    _guard();
    if (previous != null) return previous;
    await sink.commit(CourierReceived(e, receivedAt));
    return (await sink.existingReceivedAt(e))!;
  }

  Future<void> delivered(String peer, String id, int receivedAt) async {
    _guard();
    final m = history
        .messagesFor(peer)
        .where((m) => m.id == id && !m.incoming)
        .firstOrNull;
    if (m == null) return;
    history.setStatus(
      peer,
      id,
      DeliveryStatus.delivered,
      receivedAtMilliseconds: receivedAt,
    );
    await history.flush();
    _guard();
    if (history.error != null) throw StateError('Could not save receipt');
    final jid = m.courierJobId;
    if (jid != null) await service.forgetDelivered(jid);
    errors.remove(id);
  }

  Future<void> pause(
    String peer,
    PeerMessage message, {
    required bool cancel,
  }) async {
    final id = message.courierJobId;
    if (id == null) return;
    service.transport.cancelJob(id);
    if (service.jobs.find(id) != null) {
      if (cancel) {
        await service.cancel(id);
      } else {
        await service.jobs.pause(id);
      }
    }
  }

  /// A small rotating work set, independent of chat screens and live polling.
  Future<void> pump() async {
    if (!ready || _pumping) return;
    _pumping = true;
    try {
      final now = _clock();
      for (final key in _offers.keys.toList()) {
        _offers[key]!.removeWhere(
          (_, o) =>
              (o.item['expiresAt'] as int) <= now || !o.node.eligible(now),
        );
        if (_offers[key]!.isEmpty) _offers.remove(key);
      }
      _retryAt.removeWhere((_, at) => at + 86400000 < now);
      final jobs = service.jobs.jobs;
      final start = jobs.isEmpty ? 0 : _depositCursor % jobs.length;
      _depositCursor = start + 2;
      for (final job in [...jobs.skip(start), ...jobs.take(start)]) {
        if (job.scope.startsWith('group:')) {
          await _groupJob(job);
          continue;
        }
        if (!job.scope.startsWith('direct:')) continue;
        final m = history
            .messagesFor(job.peerId)
            .where((m) => m.id == job.messageId && !m.incoming)
            .firstOrNull;
        if (m == null || _contact(job.peerId)?.verified != true) {
          if (!job.terminal) await service.cancel(job.id);
          continue;
        }
        if (m.status == DeliveryStatus.delivered) {
          if (_depositing.contains(job.id)) service.transport.cancelJob(job.id);
          await history.flush();
          if (!active) return;
          if (history.error != null) {
            history.changed(job.peerId);
            continue;
          }
          if (!history.messagesFor(job.peerId).contains(m)) continue;
          await service.forgetDelivered(job.id);
          continue;
        }
        if (m.deliveryPaused || !m.queuedForDelivery) {
          service.transport.cancelJob(job.id);
          if (!job.terminal && job.status != CourierJobStatus.paused) {
            await service.jobs.pause(job.id);
          }
          continue;
        }
        if (job.status == CourierJobStatus.delivered &&
            job.receivedAt != null) {
          await delivered(job.peerId, m.id, job.receivedAt!);
          continue;
        }
        if (job.status == CourierJobStatus.stored &&
            m.status == DeliveryStatus.pending) {
          history.setStatus(job.peerId, m.id, DeliveryStatus.sent);
        }
        _scheduleDeposit(job, () => _owns(job.peerId, m));
      }
      _queueGroups();
      final nodes = service.directory.nodes
          .where(service.transport.canReach)
          .toList();
      if (nodes.isNotEmpty) {
        final count = nodes.length < 2 ? nodes.length : 2;
        for (var i = 0; i < count; i++) {
          final node = nodes[(_nodeCursor + i) % nodes.length];
          if (_checking.length >= 2 || !_checking.add(node.nodeId)) continue;
          unawaited(
            _check(node)
                .catchError((Object _) {})
                .whenComplete(() => _checking.remove(node.nodeId)),
          );
        }
        _nodeCursor = (_nodeCursor + count) % nodes.length;
      }
      for (final entry in _offers.entries.toList()) {
        if (_receiving.length >= 2) break;
        if ((_retryAt[entry.key] ?? 0) > now || !_receiving.add(entry.key)) {
          continue;
        }
        final offers = entry.value.values.toList();
        unawaited(
          _receiveOffers(offers).catchError((Object _) {}).whenComplete(() {
            _receiving.remove(entry.key);
            _retryAt[entry.key] = _clock() + 10000;
          }),
        );
      }
      await receiver.expire();
    } catch (_) {
      if (active) service.diagnostics.count(DeliveryMetric.failure);
    } finally {
      _pumping = false;
      _present();
    }
  }

  Future<void> _check(CourierNode node) async {
    for (final bucket in [
      _clock() ~/ CourierPolicy.retentionMilliseconds,
      (_clock() ~/ CourierPolicy.retentionMilliseconds) - 1,
    ]) {
      if (bucket < 0 || !ready) return;
      // Each page is bounded and advances on the next pass; never drain a busy
      // host in one loop and starve other Couriers.
      final key = '${node.nodeId}:$bucket', cursor = _pages[key] ?? 0;
      final list = await service.pickup(node, bucket: bucket, cursor: cursor);
      _guard();
      _pages[key] = list.length == 16 ? cursor + 16 : 0;
      for (final item in list) {
        final key = CourierReceiver.keyFor(item);
        if (!_offers.containsKey(key) && _offers.length >= 128) continue;
        final entries = _offers.putIfAbsent(key, () => {});
        if (entries.length < 64 || entries.containsKey(node.nodeId)) {
          entries[node.nodeId] = CourierOffer(node, item);
        }
      }
      final rkey = 'r:$key',
          rcursor = _pages[rkey] ?? 0,
          receipts = await service.receipts(node, bucket, cursor: rcursor);
      _guard();
      var removed = 0;
      for (final receipt in receipts) {
        final body = receipt['body'];
        if (body is! Map || body['jobId'] is! String) continue;
        final job = service.jobs.find(body['jobId'] as String);
        if (job == null) continue;
        if (job.scope.startsWith('group:') && groupSink == null) continue;
        await service.jobs.recordReceipt(job.id, receipt);
        _guard();
        final verified = service.jobs.find(job.id)!;
        if (job.scope.startsWith('group:')) {
          final gid = job.scope.substring(0, job.scope.lastIndexOf(':'));
          await groupSink!.controller.recordCourierReceipt(
            gid,
            job.messageId,
            job.peerId,
            verified.receivedAt!,
          );
          await service.forgetDelivered(job.id);
        } else {
          await delivered(job.peerId, job.messageId, verified.receivedAt!);
        }
        await service.acknowledgeReceipt(node, receipt, bucket);
        removed++;
      }
      _pages[rkey] = receipts.length == 16 ? (rcursor + 16 - removed) : 0;
    }
    if (_pages.length > 1024) {
      final keep = service.directory.nodes.map((n) => n.nodeId).toSet();
      _pages.removeWhere((k, _) => !keep.any(k.contains));
    }
  }

  Future<void> _receiveOffers(List<CourierOffer> offers) async {
    try {
      final receipt = await receiver.receive(offers);
      _guard();
      if (receipt == null) return;
      var acked = false;
      for (final offer in offers) {
        try {
          await service.depositReceipt(offer.node, receipt);
          acked = true;
        } catch (_) {
          _guard();
        }
      }
      if (acked) {
        await receiver.confirmed(offers.first.item);
        service.diagnostics.count(DeliveryMetric.courierPickedUp);
        _offers.remove(CourierReceiver.keyFor(offers.first.item));
      }
    } finally {
      if (active) {
        for (final progress in _incoming.values) {
          progress.removeWhere((_, v) => v >= 1);
        }
        notifyListeners();
      }
    }
  }

  GroupMessage? _groupMessage(CourierSenderJob job) {
    final gid = job.scope.substring(0, job.scope.lastIndexOf(':'));
    return groupSink?.controller
        .messagesFor(gid)
        .where((m) => m.id == job.messageId && m.senderId == service.ownerId)
        .firstOrNull;
  }

  bool _groupOwns(GroupMessage m, String peer) {
    final c = groupSink?.controller;
    return active &&
        c != null &&
        c.canSend(m.groupId) &&
        c.group(m.groupId)?.contains(peer) == true &&
        m.recipients.contains(peer) &&
        !m.receipts.containsKey(peer) &&
        c.messagesFor(m.groupId).contains(m) &&
        !c.isDeletedDelivery(m.groupId, m.senderId, m.id, m.sentAt);
  }

  Future<void> _groupJob(CourierSenderJob job) async {
    final handler = groupSink;
    if (handler == null || !handler.active) return;
    final m = _groupMessage(job), c = handler.controller;
    if (m == null) {
      if (!job.terminal) await service.cancel(job.id);
      return;
    }
    if (m.receipts.containsKey(job.peerId)) {
      // The live receipt handler may still be saving or may roll its change
      // back. Keep the encrypted sender job until that write settles.
      await c.flush();
      if (!active || !m.receipts.containsKey(job.peerId)) return;
      service.transport.cancelJob(job.id);
      await service.forgetDelivered(job.id);
      return;
    }
    if (!_groupOwns(m, job.peerId)) {
      service.transport.cancelJob(job.id);
      if (!job.terminal) await service.cancel(job.id);
      return;
    }
    if (job.status == CourierJobStatus.delivered && job.receivedAt != null) {
      await c.recordCourierReceipt(
        m.groupId,
        m.id,
        job.peerId,
        job.receivedAt!,
      );
      await service.forgetDelivered(job.id);
      return;
    }
    _scheduleDeposit(job, () => _groupOwns(m, job.peerId));
  }

  void _scheduleDeposit(CourierSenderJob job, bool Function() current) {
    if (job.terminal ||
        job.status == CourierJobStatus.stored ||
        job.manifest == null ||
        job.status == CourierJobStatus.paused ||
        _depositing.length >= 2 ||
        !_depositing.add(job.id)) {
      return;
    }
    unawaited(
      service
          .deposit(job.id, isCurrent: current)
          .catchError((Object _) => 0)
          .whenComplete(() {
            _depositing.remove(job.id);
            _present();
          }),
    );
  }

  void _queueGroups() {
    final c = groupSink?.controller;
    if (c == null || !c.active || _preparing.length >= 2) return;
    final pending = <(GroupMessage, String)>[];
    final views = c.groups;
    if (views.isEmpty) return;
    _groupOffsets.removeWhere((id, _) => !views.any((g) => g.groupId == id));
    final g = views[_groupCursor % views.length];
    _groupCursor = (_groupCursor + 1) % views.length;
    if (c.canSend(g.groupId)) {
      final offset = _groupOffsets[g.groupId] ?? 0,
          page = c.deliveryPage(g.groupId, offset);
      _groupOffsets[g.groupId] = page.length == 32 ? offset + 32 : 0;
      for (final m in page) {
        if (m.senderId != service.ownerId) continue;
        for (final peer in m.recipients) {
          if ((canQueue(peer) || c.supportsCourier(peer)) &&
              _groupOwns(m, peer) &&
              (m.courierJobs[peer] == null ||
                  service.jobs.find(m.courierJobs[peer]!)?.manifest == null)) {
            pending.add((m, peer));
          }
        }
      }
    }
    if (pending.isEmpty) return;
    for (var i = 0; i < pending.length && i < 2; i++) {
      final entry = pending[i],
          m = entry.$1,
          peer = entry.$2,
          key = '${m.groupId}:${m.id}:$peer';
      if (_preparing.length >= 2 || _preparing.containsKey(key)) continue;
      final work = _prepareGroup(m, peer).catchError((Object _) {
        if (active) errors[m.id] = 'Could not prepare group offline delivery';
      });
      _preparing[key] = work;
      unawaited(
        work.whenComplete(() {
          _preparing.remove(key);
          if (active) notifyListeners();
        }),
      );
    }
  }

  Future<void> _prepareGroup(GroupMessage m, String peer) async {
    final c = groupSink!.controller;
    if (!_groupOwns(m, peer)) return;
    final raw = Map<String, Object?>.from(jsonDecode(m.event) as Map),
        epoch = raw['epoch'] as int;
    DeliveryEnvelope e;
    if (m.deliveryEnvelope != null) {
      e = DeliveryEnvelope.fromJson(m.deliveryEnvelope!);
    } else {
      final file = m.manifest;
      e = await DeliveryEnvelope.create(
        service.crypto,
        scope: '${m.groupId}:$epoch',
        messageId: m.id,
        sentAt: m.sentAt,
        kind: 'group',
        payload: {
          'groupEvent': m.event,
          'text': m.text,
          if (file != null)
            'file': {
              'name': file.name,
              'mime': file.mimeType,
              'size': file.size,
              'digest': file.digest,
              'caption': ?file.caption,
            },
        },
      );
      await c.saveDeliveryMetadata(m, envelope: e.toJson());
    }
    if (!_groupOwns(m, peer)) return;
    final id = m.courierJobs[peer] ?? RelayChat.randomId();
    await c.saveDeliveryMetadata(m, peer: peer, jobId: id);
    if (!_groupOwns(m, peer) || service.jobs.find(id)?.terminal == true) return;
    final file = m.manifest == null ? null : await c.openFile(m.manifest!);
    await builder.prepare(
      id: id,
      peerId: peer,
      envelope: e,
      file: file,
      isCurrent: () => _groupOwns(m, peer),
    );
    if (!_groupOwns(m, peer)) return;
    await service.jobs.allocate(
      id,
      service.directory.nodes
          .where((n) => n.ownerId != service.ownerId)
          .toList(),
    );
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    groupSink?.controller.onGapRepaired = null;
    _timer?.cancel();
    receiver.close();
    await service.close();
    dispose();
  }
}
