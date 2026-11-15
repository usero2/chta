import 'package:flutter/foundation.dart';

import 'dart:convert';

import 'chat_attachment.dart';
import 'media_batch.dart';

import '../core/core_bridge.dart';
import 'chat_models.dart';

class UnknownConversationException implements Exception {
  const UnknownConversationException(this.conversationId);

  final String conversationId;

  @override
  String toString() => 'Unknown conversation: $conversationId';
}

enum ChatControllerStatus { loading, ready, failed }

class ChatController extends ChangeNotifier {
  ChatController({required this.coreBridge, int Function()? nowMilliseconds})
    : _nowMilliseconds =
          nowMilliseconds ?? (() => DateTime.now().millisecondsSinceEpoch);

  final CoreBridge coreBridge;
  final int Function() _nowMilliseconds;
  List<ConversationView> _conversations = const [];
  String? _selectedConversationId;
  ChatControllerStatus _status = ChatControllerStatus.loading;
  Object? _error;
  Future<void>? _initialization;
  final _localBatches = <String, _LocalBatch>{};
  final _deletedConversations = <String>{};
  bool _sendingBatch = false;

  List<ConversationView> get conversations => _conversations;
  ChatControllerStatus get status => _status;
  Object? get error => _error;

  ConversationView get selectedConversation {
    final selectedId = _selectedConversationId;
    return _conversations.firstWhere(
      (conversation) => conversation.id == selectedId,
      orElse: () => throw StateError('Chat is not ready'),
    );
  }

  Future<void> initialize() => _initialization ??= _load();

  Future<void> reload() {
    _conversations = const [];
    _selectedConversationId = null;
    _status = ChatControllerStatus.loading;
    _initialization = _load();
    return _initialization!;
  }

  Future<void> _load() async {
    try {
      _applySnapshot(await coreBridge.loadSnapshot());
      _status = ChatControllerStatus.ready;
      _error = null;
    } catch (error) {
      _conversations = const [];
      _selectedConversationId = null;
      _status = ChatControllerStatus.failed;
      _error = error;
    }
    notifyListeners();
  }

  void selectConversation(String conversationId) {
    if (!_conversations.any((item) => item.id == conversationId)) {
      throw UnknownConversationException(conversationId);
    }
    if (_selectedConversationId == conversationId) return;

    _selectedConversationId = conversationId;
    notifyListeners();
  }

  Future<bool> sendText(String value) async {
    if (_status != ChatControllerStatus.ready || _conversations.isEmpty) {
      return false;
    }
    try {
      final snapshot = await coreBridge.sendText(
        selectedConversation.id,
        value,
        _nowMilliseconds(),
      );
      _applySnapshot(snapshot);
      _error = null;
      notifyListeners();
      return true;
    } catch (error) {
      _error = error;
      notifyListeners();
      return false;
    }
  }

  Future<bool> sendAttachment(ChatAttachment attachment) =>
      sendText('$localAttachmentPrefix${jsonEncode(attachment.toJson())}');

  Future<bool> sendBatch(String text, List<ChatAttachment> files) async {
    if (_sendingBatch ||
        _status != ChatControllerStatus.ready ||
        _conversations.isEmpty) {
      return false;
    }
    _sendingBatch = true;
    final room = selectedConversation.id;
    try {
      var batch = _localBatches[room];
      if (batch == null ||
          batch.text != text ||
          !listEquals(batch.originals, files)) {
        batch = _LocalBatch(
          text,
          List.of(files),
          prepareMediaBatch(
            text,
            files,
            'local_${DateTime.now().microsecondsSinceEpoch}',
          ),
        );
        _localBatches[room] = batch;
      }
      while (batch.next < batch.prepared.files.length) {
        final file = batch.prepared.files[batch.next];
        _applySnapshot(
          await coreBridge.sendText(
            room,
            '$localAttachmentPrefix${jsonEncode(file.toJson())}',
            _nowMilliseconds(),
          ),
        );
        batch.next++;
        notifyListeners();
      }
      _localBatches.remove(room);
      _error = null;
      return true;
    } catch (caught) {
      _error = caught;
      notifyListeners();
      return false;
    } finally {
      _sendingBatch = false;
    }
  }

  Future<bool> deleteConversation(String id) async {
    if (coreBridge is! ConversationManagementBridge) return false;
    try {
      final snapshot = await (coreBridge as ConversationManagementBridge)
          .deleteConversation(id);
      _deletedConversations.add(id);
      _localBatches.remove(id);
      _applySnapshot(snapshot);
      _error = null;
      notifyListeners();
      return true;
    } catch (caught) {
      _error = caught;
      notifyListeners();
      return false;
    }
  }

  void _applySnapshot(ChatSnapshot snapshot) {
    final previousSelection = _selectedConversationId;
    _conversations = snapshot.conversations
        .where((c) => !_deletedConversations.contains(c.id))
        .toList();
    _selectedConversationId =
        _conversations.any((item) => item.id == previousSelection)
        ? previousSelection
        : _conversations.firstOrNull?.id;
  }
}

class _LocalBatch {
  _LocalBatch(this.text, this.originals, this.prepared);
  final String text;
  final List<ChatAttachment> originals;
  final PreparedMediaBatch prepared;
  int next = 0;
}
