import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:cht/relay/windows_process_job.dart';

void main() {
  test('closing the relay job stops only its owned process', () async {
    final job = WindowsProcessJob();
    final child = await Process.start('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      'Start-Sleep -Seconds 30',
    ]);
    try {
      job.add(child.pid);
      job.close();
      await child.exitCode.timeout(const Duration(seconds: 5));
    } finally {
      job.close();
      child.kill();
    }
  }, skip: !Platform.isWindows);
}
