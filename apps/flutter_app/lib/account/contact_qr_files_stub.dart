import 'dart:typed_data';

const supportsContactQrImageImport = false;
const supportsContactQrImageExport = false;

Future<String?> readContactQrImage() async =>
    throw UnsupportedError('QR image import is unavailable');
Future<void> saveContactQrImage(Uint8List bytes) async =>
    throw UnsupportedError('QR image export is unavailable');
