import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../account/account_models.dart';
import 'chat_attachment.dart';
import 'attachment_source.dart';
import 'attachment_ref.dart';
import 'attachment_store.dart';
import 'peer_history_store.dart';

enum DeliveryStatus { pending, sent, delivered, failed }

class PeerMessage {
  PeerMessage({
    required this.id,
    required this.text,
    required this.incoming,
    required this.status,
    int? sentAtMilliseconds,
    this.receivedAtMilliseconds,
    this.attachment,
    this.attachmentRef,
    this.thumbnailRef,
  }) : sentAtMilliseconds =
           sentAtMilliseconds ??
           (incoming ? null : DateTime.now().millisecondsSinceEpoch);

  final String id;
  final String text;
  final bool incoming;
  ChatAttachment? attachment;
  AttachmentRef? attachmentRef;
  AttachmentRef? thumbnailRef;
  bool get hasAttachment => attachment != null || attachmentRef != null;
  final int? sentAtMilliseconds;
  int? receivedAtMilliseconds;
  DeliveryStatus status;

  Map<String, Object?> toJson() => {
    'id': id,
    'text': text,
    'incoming': incoming,
    'status': status.name,
    'sentAtMilliseconds': sentAtMilliseconds,
    'receivedAtMilliseconds': receivedAtMilliseconds,
    if (attachment != null) 'attachment': attachment!.toJson(),
    if (attachmentRef != null) 'attachmentRef': attachmentRef!.toJson(),
    if (thumbnailRef != null) 'thumbnailRef': thumbnailRef!.toJson(),
  };

  factory PeerMessage.fromJson(
    Map<String, dynamic> value, {
    bool legacy = false,
  }) => PeerMessage(
    id: value['id'] as String,
    text: value['text'] as String,
    incoming: value['incoming'] as bool,
    status: DeliveryStatus.values.byName(value['status'] as String),
    thumbnailRef: value['thumbnailRef'] == null
        ? null
        : AttachmentRef.fromJson(value['thumbnailRef'] as Map<String, dynamic>),
    attachmentRef: value['attachmentRef'] == null
        ? null
        : AttachmentRef.fromJson(
            value['attachmentRef'] as Map<String, dynamic>,
          ),
    attachment: value['attachment'] == null
        ? null
        : ChatAttachment.fromJson(value['attachment'] as Map<String, dynamic>),
    sentAtMilliseconds: legacy && value['incoming'] == true
        ? null
        : value['sentAtMilliseconds'] as int?,
    receivedAtMilliseconds: legacy && value['incoming'] == true
        ? value['sentAtMilliseconds'] as int?
        : value['receivedAtMilliseconds'] as int?,
  );
}

class PeerHistory extends ChangeNotifier {
  PeerHistory({this.store, this.attachments});

  final PeerHistoryStore? store;
  final AttachmentStore? attachments;
  final _rooms = <String, List<PeerMessage>>{};
  final _conversationGenerations = <String, int>{};
  final _tombstones = <String, Set<String>>{};
  final _names = <String, String>{};
  final _avatars = <String, String>{};
  Future<void> _writes = Future.value();
  String? _owner;
  int _generation = 0;
  final _thumbnailJobs = <PeerMessage, Future<Uint8List?>>{};
  Object? error;
  bool _disposed = false;

  String? get ownerId => _owner;
  int get loadGeneration => _generation;

  List<PeerMessage> messagesFor(String? peerId) =>
      peerId == null ? const [] : _rooms[peerId] ?? const [];

  Future<void> load(String owner) async {
    final generation = ++_generation;
    _owner = owner;
    _rooms.clear();
    _conversationGenerations.clear();
    _tombstones.clear();
    _names.clear();
    _avatars.clear();
    _thumbnailJobs.clear();
    await _writes;
    final source = await store?.load(owner);
    _checkOwner(owner, generation);
    if (source != null) {
      final value = jsonDecode(source) as Map<String, dynamic>;
      if (value['version'] != 1 &&
          value['version'] != 2 &&
          value['version'] != 3 &&
          value['version'] != 4) {
        throw const FormatException('Unsupported peer history version');
      }
      _names.addAll(
        (value['names'] as Map<String, dynamic>? ?? {}).cast<String, String>(),
      );
      _avatars.addAll(
        (value['avatars'] as Map<String, dynamic>? ?? {})
            .cast<String, String>(),
      );
      _conversationGenerations.addAll(
        (value['conversationGenerations'] as Map<String, dynamic>? ?? {}).map(
          (key, value) => MapEntry(key, value as int),
        ),
      );
      _tombstones.addAll(
        (value['tombstones'] as Map<String, dynamic>? ?? {}).map(
          (key, value) => MapEntry(key, (value as List).cast<String>().toSet()),
        ),
      );
      final rooms = value['rooms'] as Map<String, dynamic>;
      for (final entry in rooms.entries) {
        _rooms[entry.key] = (entry.value as List).map((item) {
          final message = PeerMessage.fromJson(
            item as Map<String, dynamic>,
            legacy: value['version'] == 1,
          );
          // Legacy in-memory transfers cannot resume. Chunked references can.
          if (!((message.attachmentRef?.isChunked ?? false)) &&
              (message.status == DeliveryStatus.pending ||
                  message.status == DeliveryStatus.sent)) {
            message.status = DeliveryStatus.failed;
          }
          return message;
        }).toList();
      }
    }
    error = null;
    if (attachments != null && store != null) {
      final replacements = <PeerMessage, AttachmentRef>{};
      try {
        for (final message in _rooms.values.expand((room) => room)) {
          if (message.attachment != null) {
            replacements[message] = await attachments!.put(
              owner,
              message.attachment!,
            );
            _checkOwner(owner, generation);
          }
        }
        if (replacements.isNotEmpty) {
          // Serialize a candidate without mutating the recoverable legacy source.
          final candidate = _snapshot(replacements: replacements);
          await store!.save(owner, candidate);
          _checkOwner(owner, generation);
          for (final entry in replacements.entries) {
            entry.key.attachmentRef = entry.value;
            entry.key.attachment = null;
          }
        }
      } catch (caught) {
        _checkOwner(owner, generation);
        error = caught;
      }
    }
    if (!_disposed) notifyListeners();
  }

  void _checkOwner(String owner, int generation) {
    if (_disposed || _owner != owner || _generation != generation) {
      throw StateError('Identity changed during attachment access');
    }
  }

  Future<void> addAttachment(String peerId, PeerMessage message) =>
      addAttachments(peerId, [message]);

  Future<void> addAttachments(String peerId, List<PeerMessage> messages) {
    if (messages.any((m) => !m.hasAttachment)) {
      throw ArgumentError('Missing attachment');
    }
    final owner = _owner;
    final generation = _generation;
    if (attachments == null) {
      for (final message in messages) {
        add(peerId, message);
      }
      return flush();
    }
    if (owner == null) throw StateError('Unlock an identity first');
    return _enqueue(() async {
      _checkOwner(owner, generation);
      final newMessages = messages
          .where((m) => !messagesFor(peerId).any((old) => old.id == m.id))
          .toList();
      if (newMessages.isEmpty) return;
      final refs = <AttachmentRef>[];
      // Persist every blob first. A partially cached batch remains a draft.
      for (final message in newMessages) {
        refs.add(
          message.attachmentRef ??
              await attachments!.put(owner, message.attachment!),
        );
        _checkOwner(owner, generation);
      }
      final previous = [for (final message in newMessages) message.attachment];
      for (var i = 0; i < newMessages.length; i++) {
        newMessages[i].attachmentRef = refs[i];
        newMessages[i].attachment = null;
      }
      final room = _rooms.putIfAbsent(peerId, () => []);
      room.addAll(newMessages);
      try {
        await store?.save(owner, _snapshot());
        _checkOwner(owner, generation);
        error = null;
      } catch (caught) {
        room.removeWhere(newMessages.contains);
        for (var i = 0; i < newMessages.length; i++) {
          newMessages[i].attachment = previous[i];
          newMessages[i].attachmentRef = null;
        }
        error = caught;
        rethrow;
      } finally {
        if (!_disposed) notifyListeners();
      }
    });
  }

  Future<ChatAttachment> resolveAttachment(PeerMessage message) async {
    final owner = _owner;
    final generation = _generation;
    if (_disposed || !_rooms.values.any((room) => room.contains(message))) {
      throw StateError('Attachment is unavailable for this identity');
    }
    if (message.attachment != null) return message.attachment!;
    if (owner == null ||
        attachments == null ||
        message.attachmentRef == null ||
        !_rooms.values.any((room) => room.contains(message))) {
      throw StateError('Attachment is unavailable for this identity');
    }
    final result = await attachments!.read(owner, message.attachmentRef!);
    _checkOwner(owner, generation);
    if (!result.isStreamed) return result;
    return ChatAttachment.fromSource(
      name: result.name,
      mimeType: result.mimeType,
      source: _IdentityBoundSource(
        result.source!,
        () => _checkOwner(owner, generation),
      ),
      caption: result.caption,
      groupId: result.groupId,
      groupIndex: result.groupIndex,
      groupCount: result.groupCount,
    );
  }

  Future<Uint8List?> thumbnailFor(
    PeerMessage message, {
    required Future<Uint8List?> Function(ChatAttachment) generate,
  }) => _thumbnailJobs.putIfAbsent(message, () async {
    final owner = _owner;
    final generation = _generation;
    try {
      if (owner == null || attachments == null) {
        return await generate(await resolveAttachment(message));
      }
      if (!_rooms.values.any((room) => room.contains(message))) return null;
      if (message.thumbnailRef != null) {
        try {
          final ref = message.thumbnailRef!;
          if (ref.size > 256 * 1024 || ref.mimeType != 'image/png') {
            throw const FormatException('Invalid thumbnail');
          }
          final file = await attachments!.read(owner, ref);
          _checkOwner(owner, generation);
          return file.bytes;
        } catch (_) {
          _checkOwner(owner, generation);
        }
      }
      final attachment = await resolveAttachment(message);
      if (attachment.isStreamed) return null;
      final bytes = await generate(attachment);
      _checkOwner(owner, generation);
      if (bytes == null || bytes.isEmpty || bytes.length > 256 * 1024) {
        return null;
      }
      final ref = await attachments!.put(
        owner,
        ChatAttachment(
          name: 'preview.png',
          mimeType: 'image/png',
          bytes: bytes,
        ),
      );
      _checkOwner(owner, generation);
      message.thumbnailRef = ref;
      changed();
      return bytes;
    } catch (_) {
      return null;
    } // A preview must never fail the attachment.
  });

  Future<void> _enqueue(Future<void> Function() operation) {
    final pending = _writes.then((_) => operation());
    _writes = pending.then(
      (_) {},
      onError: (Object caught) {
        error = caught;
      },
    );
    return pending;
  }

  String _snapshot({Map<PeerMessage, AttachmentRef> replacements = const {}}) =>
      jsonEncode({
        'version': 4,
        'names': _names,
        'avatars': _avatars,
        'conversationGenerations': _conversationGenerations,
        'tombstones': _tombstones.map(
          (key, values) => MapEntry(key, values.toList()),
        ),
        'rooms': _rooms.map(
          (id, messages) => MapEntry(
            id,
            messages.map((message) {
              final value = message.toJson();
              if (replacements.containsKey(message)) {
                value.remove('attachment');
                value['attachmentRef'] = replacements[message]!.toJson();
              }
              return value;
            }).toList(),
          ),
        ),
      });

  List<ContactView> withSavedConversations(List<ContactView> contacts) => [
    ...contacts.map(withCachedAvatar),
    for (final id in {..._names.keys, ..._rooms.keys})
      if (!contacts.any((contact) => contact.identityId == id))
        ContactView(
          identityId: id,
          displayName: _names[id] ?? id,
          fingerprint: '',
          verified: false,
          avatarBase64: _avatars[id] ?? '',
        ),
  ];

  ContactView withCachedAvatar(ContactView contact) =>
      _avatars.containsKey(contact.identityId)
      ? contact.withAvatar(_avatars[contact.identityId]!)
      : contact;

  void rememberContacts(List<ContactView> contacts) {
    var updated = false;
    for (final contact in contacts) {
      if (_names[contact.identityId] != contact.displayName ||
          _avatars[contact.identityId] != contact.avatarBase64) {
        _names[contact.identityId] = contact.displayName;
        _avatars[contact.identityId] = contact.avatarBase64;
        updated = true;
      }
    }
    if (updated) changed();
  }

  int conversationGeneration(String peerId) =>
      _conversationGenerations[peerId] ?? 0;

  Future<void> clearConversation(String peerId) {
    final generation = conversationGeneration(peerId) + 1;
    _conversationGenerations[peerId] = generation;
    final messages = _rooms.remove(peerId) ?? const <PeerMessage>[];
    _tombstones
        .putIfAbsent(peerId, () => <String>{})
        .addAll(messages.map((message) => message.id));
    final owner = _owner;
    final loadGeneration = _generation;
    return _enqueue(() async {
      if (owner != null) _checkOwner(owner, loadGeneration);
      if (owner != null && store != null) await store!.save(owner, _snapshot());
      if (owner != null) _checkOwner(owner, loadGeneration);
      error = null;
      if (!_disposed) notifyListeners();
    });
  }

  void add(String peerId, PeerMessage message, {int? expectedGeneration}) {
    if (expectedGeneration != null &&
        expectedGeneration != conversationGeneration(peerId)) {
      return;
    }
    if (_tombstones[peerId]?.contains(message.id) == true) return;
    final messages = _rooms.putIfAbsent(peerId, () => []);
    if (messages.any((item) => item.id == message.id)) return;
    messages.add(message);
    changed();
  }

  void setStatus(
    String peerId,
    String messageId,
    DeliveryStatus status, {
    int? receivedAtMilliseconds,
  }) {
    for (final message in messagesFor(peerId)) {
      if (message.id != messageId) continue;
      // A late sent event must not downgrade a delivered message.
      if (message.status != DeliveryStatus.delivered) message.status = status;
      if (receivedAtMilliseconds != null) {
        message.receivedAtMilliseconds ??= receivedAtMilliseconds;
      }
      changed();
      return;
    }
  }

  void changed() {
    final owner = _owner;
    final generation = _generation;
    if (owner != null && store != null) {
      _writes = _writes.then((_) async {
        if (_owner != owner || generation != _generation || _disposed) return;
        try {
          await store!.save(owner, _snapshot());
          error = null;
        } catch (caught) {
          error = caught;
        }
        if (!_disposed) notifyListeners();
      });
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> flush() => _writes;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class _IdentityBoundSource implements AttachmentSource {
  _IdentityBoundSource(this.delegate, this.checkOwner);
  final AttachmentSource delegate;
  final void Function() checkOwner;
  @override
  int get length => delegate.length;
  @override
  String get key => delegate.key;
  @override
  Stream<List<int>> openRead({int start = 0, int? end}) async* {
    checkOwner();
    await for (final chunk in delegate.openRead(start: start, end: end)) {
      checkOwner();
      yield chunk;
    }
    checkOwner();
  }
}
