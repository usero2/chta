import 'package:flutter/foundation.dart';

import 'route_location_stub.dart'
    if (dart.library.js_interop) 'route_location_web.dart';

class AppRouter extends ChangeNotifier {
  AppRouter({String? initialPath}) : _path = initialPath ?? readCurrentPath() {
    watchPath(_pathChanged);
  }

  String _path;

  String get path => _path;

  void go(String path, {bool replace = false}) {
    final normalized = _normalize(path);
    if (normalized == _path) return;
    writePath(normalized, replace: replace);
    _path = normalized;
    notifyListeners();
  }

  void _pathChanged(String path) {
    final normalized = _normalize(path);
    if (normalized == _path) return;
    _path = normalized;
    notifyListeners();
  }

  static String _normalize(String path) {
    if (path.isEmpty || !path.startsWith('/')) return '/';
    return path.length > 1 && path.endsWith('/')
        ? path.substring(0, path.length - 1)
        : path;
  }
}

String contactChatRoute(String identityId) =>
    '/chats/${Uri.encodeComponent(identityId)}';

String contactConnectRoute(String identityId) =>
    '/connect/${Uri.encodeComponent(identityId)}';

String? contactIdFromConnectRoute(String path) {
  const prefix = '/connect/';
  if (!path.startsWith(prefix) || path.length == prefix.length) return null;
  return Uri.decodeComponent(path.substring(prefix.length));
}

String? contactIdFromChatRoute(String path) {
  final value = conversationIdFromRoute(path);
  return value?.startsWith('did:cht:') == true ? value : null;
}

String conversationRoute(String conversationId) =>
    '/chats/${Uri.encodeComponent(conversationId)}';

String? groupIdFromChatRoute(String path) {
  final id = conversationIdFromRoute(path);
  return id != null && RegExp(r'^group:[0-9a-f]{64}$').hasMatch(id) ? id : null;
}

String? conversationIdFromRoute(String path) {
  const prefix = '/chats/';
  if (!path.startsWith(prefix) || path.length == prefix.length) return null;
  return Uri.decodeComponent(path.substring(prefix.length));
}
