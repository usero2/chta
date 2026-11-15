import 'package:flutter/material.dart';

import '../file_transfer_progress.dart';

/// Compact durable-byte progress for an attachment card.
class FileTransferStatus extends StatelessWidget {
  const FileTransferStatus({super.key, required this.snapshot});
  final TransferProgressSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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

String _size(int bytes) {
  if (bytes < 1000) return '$bytes B';
  if (bytes < 1000000) return '${(bytes / 1000).toStringAsFixed(1)} KB';
  if (bytes < 1000000000) return '${(bytes / 1000000).toStringAsFixed(1)} MB';
  return '${(bytes / 1000000000).toStringAsFixed(1)} GB';
}
