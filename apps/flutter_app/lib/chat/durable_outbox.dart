import 'dart:async';

import 'peer_history.dart';
import 'resumable_attachment_transfer.dart';

/// Delivery intent and message/cache references share the encrypted history
/// transaction. No second file can get out of step with the conversation.
class DurableOutbox {
  DurableOutbox({
    required this.ownerId,
    required this.history,
    required this.isReady,
    required this.send,
    int Function()? clock,
  }) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);
  final String ownerId;
  final PeerHistory history;
  final bool Function(String peer) isReady;
  final Future<void> Function(String peer, PeerMessage message) send;
  final int Function() _clock;
  final _running = <String>{}, _runningPeers = <String>{};
  final _runningFiles = <String>{}, _runningTexts = <String>{};
  final _nextAttempt = <String, int>{};
  bool _closed = false;
  bool get _active => !_closed && history.ownerId == ownerId;
  String _key(String peer, String id) => '$peer\u0000$id';

  Future<void> enqueue(String peer, PeerMessage message) async {
    if (!_active || message.incoming) throw StateError('Identity changed');
    final existing = history
        .messagesFor(peer)
        .where((m) => m.id == message.id)
        .firstOrNull;
    if (existing != null && !identical(existing, message)) {
      throw StateError('Message ID exists');
    }
    if (message.status == DeliveryStatus.delivered) return;
    message.queuedForDelivery = true;
    message.deliveryPaused = false;
    message.failureReason = null;
    message.status = DeliveryStatus.pending;
    if (existing == null) {
      if (message.hasAttachment) {
        await history.addAttachment(peer, message);
      } else {
        history.add(peer, message);
      }
    }
    history.changed(peer);
    await history.flush();
    if (!_active) throw StateError('Identity changed');
    if (history.error != null) throw StateError('Could not save message');
    _nextAttempt.remove(_key(peer, message.id));
    pump();
  }

  void pump() {
    if (!_active || history.error != null) return;
    final pending = history.queuedMessages.toList();
    final retained = pending.map((e) => _key(e.key, e.value.id)).toSet();
    _nextAttempt.removeWhere((key, _) => !retained.contains(key));
    for (final entry in pending) {
      final peer = entry.key,
          message = entry.value,
          key = _key(peer, message.id);
      final budget = message.hasAttachment ? _runningFiles : _runningTexts;
      if (budget.length >= 4 || message.deliveryPaused) continue;
      final lane = '$peer\u0000${message.hasAttachment ? "file" : "text"}';
      if (_runningPeers.contains(lane) ||
          _running.contains(key) ||
          (_nextAttempt[key] ?? 0) > _clock() ||
          !isReady(peer)) {
        continue;
      }
      final generation = history.loadGeneration,
          room = history.conversationGeneration(peer);
      _running.add(key);
      budget.add(key);
      _runningPeers.add(lane);
      unawaited(() async {
        try {
          // A storage failure from an intervening history update must prevent
          // transmitting work that only exists in memory.
          await history.flush();
          if (!_active ||
              generation != history.loadGeneration ||
              room != history.conversationGeneration(peer) ||
              history.error != null ||
              !message.queuedForDelivery ||
              message.deliveryPaused ||
              !history.messagesFor(peer).contains(message) ||
              !isReady(peer)) {
            return;
          }
          await send(peer, message);
        } on TransferRejected catch (failure) {
          if (_active &&
              generation == history.loadGeneration &&
              room == history.conversationGeneration(peer) &&
              history.messagesFor(peer).contains(message) &&
              message.queuedForDelivery &&
              !message.deliveryPaused &&
              message.status != DeliveryStatus.delivered) {
            message.queuedForDelivery = false;
            message.status = DeliveryStatus.failed;
            message.failureReason = failure.message;
            history.changed(peer);
            await history.flush();
          }
        } catch (_) {
          // Retain intent. A route failure is waiting, not permanent message loss.
        } finally {
          _running.remove(key);
          budget.remove(key);
          _runningPeers.remove(lane);
          _nextAttempt[key] = _clock() + 10000;
        }
      }());
    }
  }

  Future<void> acknowledge(String peer, String id, int receivedAt) async {
    if (!_active) return;
    history.setStatus(
      peer,
      id,
      DeliveryStatus.delivered,
      receivedAtMilliseconds: receivedAt,
    );
    await history.flush();
    if (_active && history.error == null) _nextAttempt.remove(_key(peer, id));
  }

  void retryNow(String peer) {
    _nextAttempt.removeWhere((key, _) => key.startsWith('$peer\u0000'));
    pump();
  }

  void close() {
    _closed = true;
  }
}
