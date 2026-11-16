import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../account/account_bridge.dart';
import '../account/account_models.dart';
import '../groups/group_blob_bridge.dart';
import 'contact_request_bridge.dart';
import 'contact_request_transport.dart';

enum ContactRequestStatus { pending, received, accepted, declined }

class ContactRequest {
  const ContactRequest({
    required this.peerId,
    required this.requestId,
    required this.cardJson,
    required this.contact,
    required this.status,
    required this.createdAt,
  });
  final String peerId, requestId, cardJson;
  final ContactView contact;
  final ContactRequestStatus status;
  final int createdAt;
  String get id => '$peerId/$requestId';
  ContactRequest withStatus(ContactRequestStatus value) => ContactRequest(
    peerId: peerId,
    requestId: requestId,
    cardJson: cardJson,
    contact: contact,
    status: value,
    createdAt: createdAt,
  );
  Map<String, Object?> toJson() => {
    'peerId': peerId,
    'requestId': requestId,
    'cardJson': cardJson,
    'status': status.name,
    'createdAt': createdAt,
  };
}

class _State {
  _State({
    Map<String, ContactRequest>? outbox,
    Map<String, ContactRequest>? inbox,
    Map<String, ContactRequest>? decisions,
  }) : outbox = outbox ?? {},
       inbox = inbox ?? {},
       decisions = decisions ?? {};
  final Map<String, ContactRequest> outbox, inbox, decisions;
  _State copy() => _State(
    outbox: Map.of(outbox),
    inbox: Map.of(inbox),
    decisions: Map.of(decisions),
  );
}

class ContactRequestController extends ChangeNotifier {
  ContactRequestController({
    required this.ownerId,
    required this.account,
    required this.crypto,
    required this.blobs,
    required this.displayName,
    this.avatar,
    this.relayUrls,
    this.onTrustedContact,
    this.onAcceptedRoutes,
    this.onIncoming,
    this.retryEvery = const Duration(seconds: 15),
    this.clock,
    this.idFactory,
  });
  final String ownerId;
  final AccountBridge account;
  final ContactRequestBridge crypto;
  final GroupBlobBridge blobs;
  final String Function() displayName;
  final String Function()? avatar;
  final List<String> Function()? relayUrls;
  final Future<void> Function(ContactView)? onTrustedContact;
  final Future<void> Function(List<String>)? onAcceptedRoutes;
  final Future<void> Function(ContactRequest)? onIncoming;
  final Duration retryEvery;
  final int Function()? clock;
  final String Function()? idFactory;
  bool ready = false;
  String? error;
  static const _key = 'contact-requests-v1';
  _State _state = _State();
  ContactRequestTransport? _transport;
  StreamSubscription<Map<String, Object?>>? _subscription;
  Timer? _timer;
  Future<void> _tail = Future.value();
  bool _closed = false;
  int _queued = 0, _cursor = 0;
  final _nextTry = <String, int>{}, _seen = <String, int>{};
  int get _now => clock?.call() ?? DateTime.now().millisecondsSinceEpoch;
  List<ContactRequest> get incoming => List.unmodifiable(_state.inbox.values);
  ContactRequestStatus? statusFor(String peerId) =>
      _state.outbox[peerId]?.status;
  String? labelFor(String peerId) => switch (statusFor(peerId)) {
    ContactRequestStatus.pending => 'Request pending',
    ContactRequestStatus.received => 'Waiting for approval',
    ContactRequestStatus.declined => 'Request declined',
    _ => null,
  };
  Future<bool> _owned() async {
    if (_closed) return false;
    try {
      return (await account.identity()).id == ownerId && !_closed;
    } catch (_) {
      return false;
    }
  }

  Future<void> _requireOwner() async {
    if (!await _owned()) throw StateError('Contact request identity changed');
  }

  void _notify() {
    if (!_closed) notifyListeners();
  }

  Future<T> _run<T>(Future<T> Function() action) {
    final work = _tail.then((_) async {
      await _requireOwner();
      return action();
    });
    _tail = work.then<void>((_) {}).catchError((Object _) {
      if (!_closed) {
        error = 'Could not save friend request. Retry.';
        _notify();
      }
    });
    return work;
  }

  Future<ContactRequest> _record(Map<String, dynamic> value) async {
    final peer = value['peerId'],
        id = value['requestId'],
        raw = value['cardJson'],
        created = value['createdAt'];
    if (peer is! String ||
        !RegExp(r'^did:cht:[0-9a-f]{64}$').hasMatch(peer) ||
        peer == ownerId ||
        id is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(id) ||
        raw is! String ||
        utf8.encode(raw).length > 8192 ||
        created is! int ||
        created < 0) {
      throw const FormatException('Invalid saved contact request');
    }
    final contact = await account.inspectContactCard(raw);
    await _requireOwner();
    if (contact.identityId != peer) {
      throw const FormatException('Contact request card mismatch');
    }
    return ContactRequest(
      peerId: peer,
      requestId: id,
      cardJson: raw,
      contact: contact,
      status: ContactRequestStatus.values.byName(value['status'] as String),
      createdAt: created,
    );
  }

  Future<void> initialize() => _run(() async {
    if (ready) return;
    final source = await blobs.loadGroupBlob(ownerId, _key);
    await _requireOwner();
    final next = _State();
    if (source != null) {
      if (utf8.encode(source).length > 4 * 1024 * 1024) {
        throw const FormatException('Request state too large');
      }
      final value = jsonDecode(source) as Map;
      if (value['version'] != 1 || value['ownerId'] != ownerId) {
        throw const FormatException('Request owner mismatch');
      }
      for (final entry in [
        ('outbox', next.outbox, 64),
        ('inbox', next.inbox, 64),
        ('decisions', next.decisions, 256),
      ]) {
        final list = value[entry.$1] as List;
        if (list.length > entry.$3) {
          throw const FormatException('Too many requests');
        }
        for (final item in list) {
          final record = await _record(Map<String, dynamic>.from(item as Map));
          final id = entry.$1 == 'outbox' ? record.peerId : record.id;
          if (entry.$2.containsKey(id)) {
            throw const FormatException('Duplicate saved request');
          }
          if (entry.$1 == 'inbox' &&
              record.status != ContactRequestStatus.pending) {
            throw const FormatException('Invalid pending decision');
          }
          entry.$2[id] = record;
        }
      }
    }
    _state = next;
    ready = true;
    error = null;
    _notify();
    if (retryEvery > Duration.zero) {
      _timer = Timer.periodic(retryEvery, (_) => _wake());
    }
    _wake();
  });
  void attach(ContactRequestTransport transport) {
    if (_closed || identical(transport, _transport)) return;
    _transport?.removeListener(_wake);
    unawaited(_subscription?.cancel());
    _transport = transport;
    transport.addListener(_wake);
    _subscription = transport.contactRequests.listen((packet) {
      if (_closed || _queued >= 16) return;
      _queued++;
      unawaited(
        _run(() => _receive(packet))
            .catchError((Object _) {})
            .whenComplete(() => _queued--),
      );
    });
    _wake();
  }

  void _wake() {
    if (!_closed && ready) unawaited(pulse().catchError((Object _) {}));
  }

  Future<void> _save(_State next) async {
    final data = jsonEncode({
      'version': 1,
      'ownerId': ownerId,
      'outbox': next.outbox.values.map((r) => r.toJson()).toList(),
      'inbox': next.inbox.values.map((r) => r.toJson()).toList(),
      'decisions': next.decisions.values.map((r) => r.toJson()).toList(),
    });
    if (utf8.encode(data).length > 4 * 1024 * 1024) {
      throw StateError('Request state is full');
    }
    await _requireOwner();
    await blobs.saveGroupBlob(ownerId, _key, data);
    await _requireOwner();
    _state = next;
    error = null;
    _notify();
  }

  Future<void> request(String peerId) => _run(() async {
    if (!ready) throw StateError('Requests are loading');
    final authorized = (await account.contacts()).any(
      (c) => c.identityId == peerId && c.verified,
    );
    await _requireOwner();
    if (!authorized) {
      throw StateError('Confirm this contact before sending a request');
    }
    final existing = _state.outbox[peerId];
    if (existing != null && existing.status != ContactRequestStatus.declined) {
      await _send(existing, 'request');
      return;
    }
    final value = await crypto.contactRequestCall('peer', {'peerId': peerId});
    await _requireOwner();
    final raw = value['cardJson'] as String;
    final contact = await account.inspectContactCard(raw);
    await _requireOwner();
    if (contact.identityId != peerId || peerId == ownerId) {
      throw StateError('Invalid request recipient');
    }
    final next = _state.copy();
    if (next.outbox.length >= 64) {
      final completed = next.outbox.values
          .where((r) => r.status == ContactRequestStatus.declined)
          .firstOrNull;
      if (completed == null) throw StateError('Too many pending requests');
      next.outbox.remove(completed.peerId);
    }
    final id =
        idFactory?.call() ??
        List.generate(
          16,
          (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join();
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(id)) {
      throw StateError('Invalid request ID');
    }
    final record = ContactRequest(
      peerId: peerId,
      requestId: id,
      cardJson: raw,
      contact: contact,
      status: ContactRequestStatus.pending,
      createdAt: _now,
    );
    next.outbox[peerId] = record;
    await _save(next);
    await _send(record, 'request');
  });
  Future<void> _send(ContactRequest record, String kind) async {
    final transport = _transport;
    if (transport?.registered != true || !await _owned()) return;
    try {
      final sealed = await crypto.contactRequestCall('seal', {
        'peerCard': record.cardJson,
        'requestId': record.requestId,
        'kind': kind,
        'displayName': displayName(),
        'avatar': avatar?.call() ?? '',
        'relayUrls': relayUrls?.call() ?? <String>[],
        'now': _now,
      });
      if (!await _owned() ||
          !identical(transport, _transport) ||
          transport!.registered != true) {
        return;
      }
      await transport.sendContactRequest(
        Map<String, Object?>.from(sealed['envelope'] as Map),
      );
    } catch (_) {
      /* A durable request/decision is retried; network failure is not a decline. */
    }
  }

  Future<void> _learnRoutes(ContactView contact) async {
    if (contact.relayUrls.isEmpty || !await _owned()) return;
    try {
      await onAcceptedRoutes?.call(contact.relayUrls);
    } catch (_) {
      // A temporary route failure must not reverse an already saved decision.
    }
  }

  Future<void> pulse({bool force = false}) => _run(() async {
    if (!ready || _transport?.registered != true || !await _owned()) return;
    final authorized = (await account.contacts())
        .where((c) => c.verified)
        .map((c) => c.identityId)
        .toSet();
    await _requireOwner();
    if (_state.outbox.keys.any((peer) => !authorized.contains(peer))) {
      final next = _state.copy();
      next.outbox.removeWhere((peer, _) => !authorized.contains(peer));
      await _save(next);
    }
    final pending = _state.outbox.values
        .where((r) => r.status != ContactRequestStatus.declined)
        .toList();
    if (pending.isEmpty) return;
    var sent = 0;
    for (var i = 0; i < pending.length && sent < 2; i++) {
      final record = pending[(_cursor + i) % pending.length];
      if (!force && (_nextTry[record.id] ?? 0) > _now) continue;
      _nextTry[record.id] =
          _now +
          (record.status == ContactRequestStatus.received ? 60000 : 30000);
      await _send(record, 'request');
      sent++;
    }
    _cursor = (_cursor + 2) % pending.length;
  });
  Future<void> _receive(Map<String, Object?> envelope) async {
    if (!ready) return;
    Map<String, Object?> opened;
    try {
      opened = await crypto.contactRequestCall('inspect', {
        'source': jsonEncode(envelope),
        'now': _now,
      });
    } catch (_) {
      return;
    }
    await _requireOwner();
    final peer = opened['peerId'] as String,
        id = opened['requestId'] as String,
        kind = opened['kind'] as String;
    final packet = opened['packetId'] as String, key = '$peer/$id';
    _seen.removeWhere((_, until) => until <= _now);
    if (_seen.containsKey('$peer/$packet')) return;
    if (_seen.length >= 512) return;
    final raw = opened['cardJson'] as String;
    final contact = await account.inspectContactCard(raw);
    await _requireOwner();
    if (contact.identityId != peer ||
        peer == ownerId ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(id)) {
      return;
    }
    final record = ContactRequest(
      peerId: peer,
      requestId: id,
      cardJson: raw,
      contact: contact,
      status: ContactRequestStatus.pending,
      createdAt: _now,
    );
    if (kind == 'request') {
      final known = (await account.contacts())
          .where((c) => c.identityId == peer && c.verified)
          .firstOrNull;
      await _requireOwner();
      final decision = _state.decisions[key];
      if (decision != null &&
          decision.status == ContactRequestStatus.declined &&
          known == null) {
        await _send(decision, decision.status.name);
        return;
      }
      final next = _state.copy();
      if (known != null) {
        final accepted = record.withStatus(ContactRequestStatus.accepted);
        next.inbox.removeWhere((_, r) => r.peerId == peer);
        _decision(next, accepted);
        await _save(next);
        await _learnRoutes(contact);
        await _send(accepted, 'accepted');
        return;
      }
      final old = _state.inbox[key];
      if (old != null) {
        await _send(old, 'received');
        return;
      }
      if (next.inbox.length >= 64 ||
          next.inbox.values.any((r) => r.peerId == peer)) {
        return;
      }
      next.inbox[key] = record;
      next.decisions.remove(key);
      await _save(next);
      _seen['$peer/$packet'] = _now + 120000;
      await _send(record, 'received');
      await onIncoming?.call(record);
      return;
    }
    final outgoing = _state.outbox[peer];
    if (outgoing == null || outgoing.requestId != id) return;
    final next = _state.copy();
    switch (kind) {
      case 'received':
        if (outgoing.status == ContactRequestStatus.declined) return;
        next.outbox[peer] = outgoing.withStatus(ContactRequestStatus.received);
      case 'declined':
        next.outbox[peer] = outgoing.withStatus(ContactRequestStatus.declined);
      case 'accepted':
        next.outbox.remove(peer);
      default:
        return;
    }
    await _save(next);
    _seen['$peer/$packet'] = _now + 120000;
    if (kind == 'accepted') {
      final known = (await account.contacts())
          .where((c) => c.identityId == peer && c.verified)
          .firstOrNull;
      await _requireOwner();
      if (known != null) {
        await _learnRoutes(contact);
        await _requireOwner();
        await onTrustedContact?.call(known);
      }
    }
  }

  void _decision(_State next, ContactRequest record) {
    if (next.decisions.length >= 256 &&
        !next.decisions.containsKey(record.id)) {
      next.decisions.remove(next.decisions.keys.first);
    }
    next.decisions[record.id] = record;
  }

  Future<ContactView> accept(String id, {String alias = ''}) => _run(() async {
    final record = _state.inbox[id];
    if (record == null) throw StateError('Request no longer pending');
    var known = (await account.contacts())
        .where((c) => c.identityId == record.peerId)
        .firstOrNull;
    await _requireOwner();
    if (known == null) {
      await account.addContact(record.cardJson, alias);
      await _requireOwner();
    }
    await account.markContactVerified(record.peerId);
    await _requireOwner();
    known = (await account.contacts()).firstWhere(
      (c) => c.identityId == record.peerId,
    );
    await _requireOwner();
    final next = _state.copy(),
        accepted = record.withStatus(ContactRequestStatus.accepted);
    next.inbox.remove(id);
    _decision(next, accepted);
    await _save(next);
    await _learnRoutes(record.contact);
    await _send(accepted, 'accepted');
    await onTrustedContact?.call(known);
    return known;
  });
  Future<void> decline(String id) => _run(() async {
    final record = _state.inbox[id];
    if (record == null) return;
    final next = _state.copy(),
        declined = record.withStatus(ContactRequestStatus.declined);
    next.inbox.remove(id);
    _decision(next, declined);
    await _save(next);
    await _send(declined, 'declined');
  });
  Future<void> flush() => _tail;
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    _transport?.removeListener(_wake);
    await _subscription?.cancel();
    await _tail;
    dispose();
  }
}
