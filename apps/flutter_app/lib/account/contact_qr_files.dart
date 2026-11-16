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
    return Semantics(
      label: 'qr code',
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(painter: _ContactQrPainter(card, qr)),
      ),
    );
  }
}

class _ContactQrPainter extends CustomPainter {
  _ContactQrPainter(this.card, QrCode qr) : image = QrImage(qr);
  final String card;
  final QrImage image;

  @override
  void paint(Canvas canvas, Size size) {
    final edge = size.shortestSide;
    final margin = contactQrMargin(edge, image.moduleCount);
    final module = (edge - 2 * margin) / image.moduleCount;
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    final ink = Paint()
      ..color = Colors.black
      ..isAntiAlias = false;
    // Do not round each module's width: cumulative rounding can erase the
    // quiet zone of dense codes at small display sizes.
    for (var row = 0; row < image.moduleCount; row++) {
      for (var col = 0; col < image.moduleCount; col++) {
        if (!image.isDark(row, col)) continue;
        canvas.drawRect(
          Rect.fromLTRB(
            margin + col * module,
            margin + row * module,
            margin + (col + 1) * module,
            margin + (row + 1) * module,
          ),
          ink,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_ContactQrPainter oldDelegate) => oldDelegate.card != card;
}

Future<Uint8List> encodeContactQrImage(String card) async {
  const pixels = 1200;
  final qr = QrCode.fromData(
    data: card,
    errorCorrectLevel: QrErrorCorrectLevel.L,
  );
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  _ContactQrPainter(
    card,
    qr,
  ).paint(canvas, ui.Size.square(pixels.toDouble()));
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
