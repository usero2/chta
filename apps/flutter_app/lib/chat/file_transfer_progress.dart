enum FileTransferPhase {
  preparing,
  sending,
  receiving,
  verifying,
  waiting,
  completed,
  failed,
}

class TransferProgressSnapshot {
  const TransferProgressSnapshot({
    required this.confirmedBytes,
    required this.totalBytes,
    required this.bytesPerSecond,
    required this.transport,
    required this.phase,
  });
  final int confirmedBytes, totalBytes;
  final double bytesPerSecond;
  final String transport;
  final FileTransferPhase phase;
  double get fraction => totalBytes == 0
      ? (phase == FileTransferPhase.completed ? 1 : 0)
      : (confirmedBytes / totalBytes).clamp(0, 1);
}
