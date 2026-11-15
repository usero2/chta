import 'dart:io';

import 'package:flutter/services.dart';

Future<Uint8List?> pickPlatformProfileImage() async {
  if (Platform.isAndroid) {
    return const MethodChannel('app.cht/platform')
        .invokeMethod<Uint8List>('pickProfileImage');
  }
  if (!Platform.isWindows) return null;
  const script = r'''
Add-Type -AssemblyName System.Windows.Forms
$dialog = New-Object System.Windows.Forms.OpenFileDialog
$dialog.Filter = 'Images|*.png;*.jpg;*.jpeg;*.webp'
$dialog.Multiselect = $false
if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
  [Console]::Out.Write($dialog.FileName)
}
''';
  final result = await Process.run('powershell.exe', [
    '-NoProfile',
    '-NonInteractive',
    '-STA',
    '-Command',
    script,
  ]);
  if (result.exitCode != 0) {
    throw StateError('Unable to open the image picker: ${result.stderr}');
  }
  final path = '${result.stdout}'.trim();
  if (path.isEmpty) return null;
  return File(path).readAsBytes();
}
