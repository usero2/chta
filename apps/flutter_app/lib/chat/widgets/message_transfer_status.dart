import 'package:flutter/material.dart';

import '../file_transfer_progress.dart';
import '../peer_history.dart';
import 'file_transfer_status.dart';

/// Durable delivery wins over transient, possibly late transfer callbacks.
class MessageTransferStatus extends StatelessWidget {
  const MessageTransferStatus({
    super.key,
    required this.message,
    this.snapshot,
    this.legacyProgress,
  });
  final PeerMessage message;
  final TransferProgressSnapshot? snapshot;
  final double? legacyProgress;

  static bool visibleFor(
    PeerMessage message, {
    TransferProgressSnapshot? snapshot,
    double? legacyProgress,
  }) =>
      message.hasAttachment &&
      !message.deliveryPaused &&
      message.status != DeliveryStatus.delivered &&
      snapshot?.phase != FileTransferPhase.completed &&
      (snapshot != null || legacyProgress != null);

  @override
  Widget build(BuildContext context) {
    if (!visibleFor(
      message,
      snapshot: snapshot,
      legacyProgress: legacyProgress,
    )) {
      return const SizedBox.shrink();
    }
    final Widget content;
    if (snapshot case final value?) {
      content = FileTransferStatus(snapshot: value);
    } else if (legacyProgress! >= 1) {
      content = const TransferReceiptStatus();
    } else {
      final value = legacyProgress!.clamp(0.0, 1.0);
      content = Row(
        children: [
          Expanded(child: LinearProgressIndicator(value: value)),
          const SizedBox(width: 8),
          Text(
            '${(value * 100).round()}%',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      );
    }
    return SizedBox(
      width: 220,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10, right: 8),
        child: content,
      ),
    );
  }
}
