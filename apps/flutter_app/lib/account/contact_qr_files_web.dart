import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

const supportsContactQrImageImport = false;
const supportsContactQrImageExport = true;

Future<String?> readContactQrImage() async => throw UnsupportedError(
  'Paste the public contact card or scan it with your camera.',
);

Future<void> saveContactQrImage(Uint8List bytes) async {
  final blob = web.Blob(
    [bytes.toJS].toJS,
    web.BlobPropertyBag(type: 'image/png'),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = 'chta-public-contact.png';
  web.document.body!.append(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
}
