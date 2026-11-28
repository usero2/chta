import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'share_links.dart';

final pendingShareLink = ValueNotifier<String?>(null);
const _channel = MethodChannel('app.cht/share');

Future<void> startShareLinkInbox() async {
  void receive(String token) {
    final magnet = magnetFromShareToken(token);
    if (magnet != null) pendingShareLink.value = magnet;
  }

  if (kIsWeb) {
    final fragment = Uri.base.fragment;
    if (fragment.startsWith('chta=')) receive(fragment.substring(5));
  } else if (defaultTargetPlatform == TargetPlatform.android) {
    Future<void> take() async {
      try {
        final token = await _channel.invokeMethod<String>('take');
        if (token != null) receive(token);
      } on MissingPluginException {
        // This engine does not have a native activity yet.
      }
    }

    _channel.setMethodCallHandler((call) async {
      if (call.method == 'available') await take();
    });
    await take();
  }
}
