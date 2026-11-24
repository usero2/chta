import 'package:flutter/material.dart';

import '../file_transfer_progress.dart';

/// Compact durable-byte progress for an attachment card.
class FileTransferStatus extends StatelessWidget {
  const FileTransferStatus({super.key, required this.snapshot});
  final TransferProgressSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    if (snapshot.phase == FileTransferPhase.completed) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    if (snapshot.phase == FileTransferPhase.failed) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 16, color: theme.colorScheme.error),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              'Transfer failed',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        ],
      );
    }
    if (snapshot.phase == FileTransferPhase.sending &&
        snapshot.confirmedBytes >= snapshot.totalBytes) {
      return const TransferReceiptStatus();
    }
    final phase = switch (snapshot.phase) {
      FileTransferPhase.preparing => 'Preparing',
      FileTransferPhase.sending => 'Sending',
      FileTransferPhase.receiving => 'Receiving',
      FileTransferPhase.verifying => 'Verifying',
      FileTransferPhase.waiting => 'Waiting to reconnect',
      FileTransferPhase.completed => 'Completed',
      FileTransferPhase.failed => 'Failed',
    };
    final speed =
        snapshot.bytesPerSecond > 0 &&
            (snapshot.phase == FileTransferPhase.sending ||
                snapshot.phase == FileTransferPhase.receiving)
        ? '${(snapshot.bytesPerSecond / 1000000).toStringAsFixed(1)} MB/s'
        : null;
    return Semantics(
      label:
          '$phase via ${snapshot.transport}, ${_size(snapshot.confirmedBytes)} of ${_size(snapshot.totalBytes)} confirmed',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$phase · ${snapshot.transport} · ${(snapshot.fraction * 100).floor()}%',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          LinearProgressIndicator(value: snapshot.fraction),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${_size(snapshot.confirmedBytes)} / ${_size(snapshot.totalBytes)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ),
              if (speed != null) Text(speed, style: theme.textTheme.bodySmall),
            ],
          ),
        ],
      ),
    );
  }
}

class TransferReceiptStatus extends StatelessWidget {
  const TransferReceiptStatus({super.key});

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Waiting for receipt',
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(strokeWidth: 1.5),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            'Waiting for receipt',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    ),
  );
}

String _size(int bytes) {
  if (bytes < 1000) return '$bytes B';
  if (bytes < 1000000) return '${(bytes / 1000).toStringAsFixed(1)} KB';
  if (bytes < 1000000000) return '${(bytes / 1000000).toStringAsFixed(1)} MB';
  return '${(bytes / 1000000000).toStringAsFixed(1)} GB';
}
