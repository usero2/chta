import 'package:flutter/material.dart';

import '../peer_history.dart';

class FileTransferActions extends StatefulWidget {
  const FileTransferActions({
    required this.message,
    this.onPause,
    this.onResume,
    this.onCancel,
    this.progress,
    this.awaitingAcceptance,
    this.color,
    super.key,
  });
  final PeerMessage message;
  final Future<void> Function()? onPause, onResume, onCancel;
  final Widget? progress;
  final String? awaitingAcceptance;
  final Color? color;
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
    if (!m.hasAttachment) return const SizedBox.shrink();
    final delivered = m.status == DeliveryStatus.delivered;
    final cancelled =
        m.failureReason == 'Cancelled' ||
        m.failureReason == 'Declined by recipient';
    final resumable = m.deliveryPaused || m.status == DeliveryStatus.failed;
    final override =
        _error ?? m.failureReason ?? (m.deliveryPaused ? 'Paused' : null);
    final label = delivered
        ? (m.incoming ? 'Received' : 'Delivered')
        : override ??
              widget.awaitingAcceptance ??
              switch (m.status) {
                DeliveryStatus.sent => 'Sent',
                DeliveryStatus.failed => 'Failed',
                _ => m.incoming ? 'Receiving' : 'Queued',
              };
    final primaryAction = resumable ? widget.onResume : widget.onPause;
    final cancel = widget.onCancel;
    final hasProgress =
        !delivered && override == null && widget.progress != null;
    return Row(
      children: [
        Expanded(
          child: hasProgress
              ? widget.progress!
              : Tooltip(
                  message: label,
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.labelSmall
                        ?.copyWith(color: widget.color),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
        ),
        if (!delivered &&
            m.failureReason != 'Declined by recipient' &&
            !(m.incoming && cancelled) &&
            widget.awaitingAcceptance == null &&
            primaryAction != null)
          _action(
            tooltip: resumable
                ? (m.deliveryPaused ? 'Resume transfer' : 'Retry transfer')
                : 'Pause transfer',
            icon: resumable ? Icons.play_arrow : Icons.pause,
            callback: primaryAction,
          ),
        if (!delivered && !cancelled && cancel != null)
          _action(
            tooltip: 'Cancel transfer',
            icon: Icons.close,
            callback: cancel,
          ),
      ],
    );
  }

  Widget _action({
    required String tooltip,
    required IconData icon,
    required Future<void> Function() callback,
  }) => IconButton(
    tooltip: tooltip,
    icon: Icon(icon, size: 17),
    style: IconButton.styleFrom(
      foregroundColor: widget.color,
      minimumSize: const Size(32, 32),
      padding: EdgeInsets.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    onPressed: _busy ? null : () => _run(callback),
  );
}
