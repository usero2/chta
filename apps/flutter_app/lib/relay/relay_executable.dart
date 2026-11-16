import 'dart:io';

/// Prefer the immutable runtime extracted from the single-file application.
Future<String> findRelayTunnelExecutable({
  required String runtimeDirectory,
  String? overridePath,
  String? programFilesX86,
  Future<ProcessResult> Function(String, List<String>)? runVersion,
}) async {
  final run = runVersion ?? (command, args) => Process.run(command, args);
  for (final path in <String>[
    ?overridePath,
    '$runtimeDirectory${Platform.pathSeparator}cloudflared.exe',
    'cloudflared',
    '${programFilesX86 ?? Platform.environment['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)'}${Platform.pathSeparator}cloudflared${Platform.pathSeparator}cloudflared.exe',
  ]) {
    try {
      if ((await run(path, ['--version'])).exitCode == 0) return path;
    } catch (_) {
      // Older installations may still provide the tool via PATH.
    }
  }
  throw StateError(
    'Public relay component missing. Reinstall the latest Desktop app.',
  );
}
