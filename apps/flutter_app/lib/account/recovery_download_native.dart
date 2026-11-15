import 'dart:io';

import 'package:flutter/services.dart';

Future<void> downloadRecoveryPhrase(String phrase) async {
  if (!Platform.isAndroid) {
    throw UnsupportedError(
      'Recovery phrase export is available on Web and Android',
    );
  }
  await const MethodChannel('app.cht/platform')
      .invokeMethod<void>('saveRecoveryPhrase', {'phrase': phrase});
}
