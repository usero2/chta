import 'dart:async';

import '../chat/chat_attachment.dart';
import '../chat/peer_history.dart';
import 'incoming_notifications.dart';

class PeerHistoryNotifications {
  /// Bind after the initial history load. Rehydration only updates the baseline;
  /// resumed pending files may notify when they finish during this session.
  PeerHistoryNotifications({
    required this.history,
    required this.notifications,
  }) {
    _baseline();
    history.addListener(_changed);
  }
  final PeerHistory history;
  final IncomingNotifications notifications;
  final _completed = <(String, String)>{};
  final _pending = <(String, String)>{};
  int _generation = -1;
  bool _disposed = false;

  void _baseline() {
    _generation = history.loadGeneration;
    _completed.clear();
    _pending.clear();
    for (final contact in history.withSavedConversations(const [])) {
      for (final message in history.messagesFor(contact.identityId)) {
        if (message.status == DeliveryStatus.delivered) {
          _completed.add((contact.identityId, message.id));
        }
      }
    }
  }

  void _changed() {
    if (_disposed || history.ownerId != notifications.identityId) return;
    if (_generation != history.loadGeneration) {
      _baseline();
      return;
    }
    for (final contact in history.withSavedConversations(const [])) {
      for (final message in history.messagesFor(contact.identityId)) {
        final key = (contact.identityId, message.id);
        if (!message.incoming ||
            !message.isVisible ||
            message.repaired ||
            message.status != DeliveryStatus.delivered ||
            message.id.startsWith('cht-control-') ||
            message.id.startsWith('chtatt1_') ||
            _completed.contains(key) ||
            !_pending.add(key)) {
          continue;
        }
        unawaited(
          _deliver(
            contact.identityId,
            contact.displayName,
            message,
            _generation,
          ),
        );
      }
    }
  }

  Future<void> _deliver(
    String peerId,
    String name,
    PeerMessage message,
    int generation,
  ) async {
    final key = (peerId, message.id);
    try {
      await history.flush();
      if (_disposed ||
          generation != history.loadGeneration ||
          history.ownerId != notifications.identityId ||
          history.error != null ||
          message.status != DeliveryStatus.delivered) {
        return;
      }
      if (history.presentationFor(peerId, message.id)?.deleted == true) return;
      _completed.add(key);
      final mimeType =
          message.attachmentRef?.mimeType ?? message.attachment?.mimeType;
      await notifications.notifyIncoming(
        peerId: peerId,
        displayName: name,
        messageId: message.id,
        kind: message.hasAttachment
            ? IncomingNotificationKind.file
            : IncomingNotificationKind.message,
        fileName: message.attachmentRef?.name ?? message.attachment?.name,
        messageText: message.hasAttachment
            ? null
            : history.presentationFor(peerId, message.id)?.text,
        markdownSize: message.attachmentRef?.size ?? message.attachment?.size,
        loadMarkdown: mimeType?.toLowerCase() == ChatAttachment.markdownMimeType
            ? () => history.resolveAttachment(message)
            : null,
      );
    } finally {
      if (generation == _generation) _pending.remove(key);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    history.removeListener(_changed);
  }
}
