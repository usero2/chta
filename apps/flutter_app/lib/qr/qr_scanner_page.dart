import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

bool get supportsQrCamera =>
    kIsWeb ||
    const [
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.macOS,
    ].contains(defaultTargetPlatform);

Future<String?> scanQr(
  BuildContext context, {
  required String title,
  required String fallbackText,
}) async {
  final route = MaterialPageRoute<String>(
    builder: (_) => QrScannerPage(title: title, fallbackText: fallbackText),
  );
  final value = await Navigator.of(context).push(route);
  await route.completed;
  return value;
}

class QrScannerPage extends StatefulWidget {
  const QrScannerPage({
    required this.title,
    required this.fallbackText,
    super.key,
  });
  final String title;
  final String fallbackText;
  @override
  State<QrScannerPage> createState() => _QrScannerPageState();
}

class _QrScannerPageState extends State<QrScannerPage> {
  bool returned = false;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.title)),
    body: MobileScanner(
      errorBuilder: (context, error) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.no_photography_outlined, size: 40),
              const SizedBox(height: 16),
              Text(
                error.errorCode == MobileScannerErrorCode.permissionDenied
                    ? 'Allow camera access in Settings.'
                    : 'Could not open the camera.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(widget.fallbackText, textAlign: TextAlign.center),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Back'),
              ),
            ],
          ),
        ),
      ),
      onDetect: (capture) {
        if (returned) return;
        for (final barcode in capture.barcodes) {
          final value = barcode.rawValue;
          if (value == null || value.trim().isEmpty) continue;
          returned = true;
          Navigator.pop(context, value);
          return;
        }
      },
    ),
  );
}
