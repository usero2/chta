import 'package:flutter/material.dart';

import '../peer_history.dart';

class FileTransferActions extends StatefulWidget {
  const FileTransferActions({
    required this.message,
    required this.onPause,
    required this.onResume,
    required this.onCancel,
    super.key,
  });
  final PeerMessage message;
  final Future<void> Function() onPause, onResume, onCancel;
  @override
  State<FileTransferActions> createState() => _FileTransferActionsState();
}

class _FileTransferActionsState extends State<FileTransferActions> {
  bool _busy = false;
  String? _error;
  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not save transfer state. Try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.message;
    if (!m.hasAttachment || m.status == DeliveryStatus.delivered) {
      return const SizedBox.shrink();
    }
    final cancelled = m.failureReason == 'Cancelled';
    final resumable = m.deliveryPaused || m.status == DeliveryStatus.failed;
    final label =
        _error ?? m.failureReason ?? (m.deliveryPaused ? 'Paused' : null);
    return SizedBox(
      width: 260,
      child: Row(
        children: [
          if (label != null)
            Expanded(
              child: Text(
                label,
                style: Theme.of(context).textTheme.bodySmall,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            )
          else
            const Spacer(),
          if (!(m.incoming && cancelled))
            IconButton(
              tooltip: resumable
                  ? (m.deliveryPaused ? 'Resume transfer' : 'Retry transfer')
                  : 'Pause transfer',
              icon: Icon(resumable ? Icons.play_arrow : Icons.pause, size: 20),
              onPressed: _busy
                  ? null
                  : () => _run(resumable ? widget.onResume : widget.onPause),
            ),
          if (!cancelled)
            IconButton(
              tooltip: 'Cancel transfer',
              icon: const Icon(Icons.close, size: 20),
              onPressed: _busy ? null : () => _run(widget.onCancel),
            ),
        ],
      ),
    );
  }
}
