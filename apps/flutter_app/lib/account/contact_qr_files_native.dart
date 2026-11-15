import 'dart:io';

import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

bool get supportsContactQrImageImport => Platform.isAndroid;
bool get supportsContactQrImageExport =>
    Platform.isAndroid || Platform.isWindows;
const _channel = MethodChannel('app.cht/platform');

Future<String?> readContactQrImage() async {
  final path = await _channel.invokeMethod<String>('pickContactQrImage');
  if (path == null) return null;
  final controller = MobileScannerController(
    autoStart: false,
    formats: [BarcodeFormat.qrCode],
  );
  try {
    final capture = await controller.analyzeImage(
      path,
      formats: [BarcodeFormat.qrCode],
    );
    for (final barcode in capture?.barcodes ?? <Barcode>[]) {
      final value = barcode.rawValue;
      if (value != null && value.trim().isNotEmpty) return value;
    }
    throw const FormatException('No QR found. Try the original image.');
  } finally {
    await controller.dispose();
    final file = File(path);
    if (await file.exists()) await file.delete();
  }
}

Future<void> saveContactQrImage(Uint8List bytes) async {
  if (Platform.isAndroid) {
    await _channel.invokeMethod<void>('saveContactQr', {'bytes': bytes});
    return;
  }
  if (!Platform.isWindows) {
    throw UnsupportedError('QR image export is unavailable');
  }
  const script = r'''
Add-Type -AssemblyName System.Windows.Forms
$dialog = New-Object System.Windows.Forms.SaveFileDialog
$dialog.Filter = 'PNG image|*.png'
$dialog.FileName = 'cht-public-contact.png'
$dialog.DefaultExt = 'png'
$dialog.AddExtension = $true
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
  if (result.exitCode != 0) throw StateError('Unable to open the save dialog');
  final path = '${result.stdout}'.trim();
  if (path.isNotEmpty) await File(path).writeAsBytes(bytes, flush: true);
}
