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
    this.compact = false,
    this.color,
  });
  final PeerMessage message;
  final TransferProgressSnapshot? snapshot;
  final double? legacyProgress;
  final bool compact;
  final Color? color;

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
    if (compact) return _compactProgress(context);
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

  Widget _compactProgress(BuildContext context) {
    final value = (snapshot?.fraction ?? legacyProgress!).clamp(0.0, 1.0);
    final phase = snapshot?.phase;
    final label = switch (phase) {
      FileTransferPhase.preparing => 'Preparing',
      FileTransferPhase.waiting => 'Waiting',
      FileTransferPhase.verifying => 'Verifying',
      FileTransferPhase.failed => 'Failed',
      _ => value >= 1 ? 'Sent' : '${(value * 100).round()}%',
    };
    return Tooltip(
      message: label == 'Sent'
          ? 'Waiting for receipt'
          : snapshot == null
          ? label
          : '$label · ${snapshot!.transport}',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall
                ?.copyWith(color: color),
          ),
          if ((phase == null ||
                  phase == FileTransferPhase.sending ||
                  phase == FileTransferPhase.receiving) &&
              value < 1) ...[
            const SizedBox(height: 2),
            LinearProgressIndicator(value: value, minHeight: 2, color: color),
          ],
        ],
      ),
    );
  }
}
