import 'dart:js_interop';

import 'package:web/web.dart' as web;

Future<void> downloadRecoveryPhrase(String phrase) async {
  final content =
      '''chta recovery phrase

WARNING: Anyone with these 24 words can control this identity.
Store this file offline and delete unsafe copies.

$phrase
''';
  final blob = web.Blob(
    <JSAny>[content.toJS].toJS,
    web.BlobPropertyBag(type: 'text/plain;charset=utf-8'),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = 'chta-recovery-phrase.txt'
    ..style.display = 'none';
  web.document.body!.append(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
}
