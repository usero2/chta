import 'dart:js_interop';

import 'package:web/web.dart' as web;

Future<int?> availableCacheSpace() async {
  try {
    final estimate = await web.window.navigator.storage.estimate().toDart;
    return (estimate.quota - estimate.usage).clamp(0, estimate.quota);
  } catch (_) {
    return null;
  }
}
