import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'qa_result_stub.dart'
    if (dart.library.js_interop) 'qa_result_web.dart'
    if (dart.library.io) 'qa_result_native.dart';

void reportQa(Map<String, Object?> result) {
  debugPrint('CHT_LARGE_QA:${jsonEncode(result)}');
  writeQaResult(result);
}
