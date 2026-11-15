import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:qr_flutter/qr_flutter.dart';

import 'contact_qr_files_stub.dart'
    if (dart.library.io) 'contact_qr_files_native.dart'
    if (dart.library.js_interop) 'contact_qr_files_web.dart'
    as platform;

bool get supportsContactQrImageImport => platform.supportsContactQrImageImport;
bool get supportsContactQrImageExport => platform.supportsContactQrImageExport;

Future<String?> readContactQrImage() => platform.readContactQrImage();

double contactQrMargin(double size, int modules, {int quietModules = 4}) =>
    size * quietModules / (modules + 2 * quietModules);

class ContactQrView extends StatelessWidget {
  const ContactQrView({required this.card, this.size = 260, super.key});
  final String card;
  final double size;
  @override
  Widget build(BuildContext context) {
    final qr = QrCode.fromData(
      data: card,
      errorCorrectLevel: QrErrorCorrectLevel.L,
    );
    return QrImageView.withQr(
      qr: qr,
      size: size,
      padding: EdgeInsets.all(
        contactQrMargin(size, qr.moduleCount, quietModules: 2),
      ),
      backgroundColor: Colors.white,
    );
  }
}

Future<Uint8List> encodeContactQrImage(String card) async {
  const pixels = 1200;
  final qr = QrCode.fromData(
    data: card,
    errorCorrectLevel: QrErrorCorrectLevel.L,
  );
  final margin = contactQrMargin(pixels.toDouble(), qr.moduleCount);
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawColor(const ui.Color(0xffffffff), ui.BlendMode.src);
  canvas.translate(margin, margin);
  QrPainter.withQr(
    qr: qr,
    gapless: true,
  ).paint(canvas, ui.Size(pixels - 2 * margin, pixels - 2 * margin));
  final picture = recorder.endRecording();
  final image = await picture.toImage(pixels, pixels);
  try {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) throw StateError('Unable to render the contact QR');
    return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
  } finally {
    image.dispose();
    picture.dispose();
  }
}

Future<void> saveContactQrImage(String card) async =>
    platform.saveContactQrImage(await encodeContactQrImage(card));
