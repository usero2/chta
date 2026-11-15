import 'account_models.dart';

class SessionPreferences {
  const SessionPreferences({required this.pinRequired, this.lastRoute});
  final bool pinRequired;
  final String? lastRoute;
  factory SessionPreferences.fromJson(Map<String, Object?> value) {
    final required = value['pinRequired'], route = value['lastRoute'];
    if (required is! bool ||
        (route != null && (route is! String || !isSessionRoute(route)))) {
      throw const FormatException('Invalid saved session preferences');
    }
    return SessionPreferences(
      pinRequired: required,
      lastRoute: route as String?,
    );
  }
}

bool isSessionRoute(String path) {
  if (path.length > 512 ||
      path.contains('..') ||
      path.contains('?') ||
      path.contains('#')) {
    return false;
  }
  if (['/chats', '/contacts', '/connect', '/profile'].contains(path)) {
    return true;
  }
  final prefix = path.startsWith('/chats/')
      ? '/chats/'
      : path.startsWith('/connect/')
      ? '/connect/'
      : null;
  if (prefix == null) return false;
  try {
    final id = Uri.decodeComponent(path.substring(prefix.length));
    return RegExp(r'^did:cht:[0-9a-f]{64}$').hasMatch(id) ||
        RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id);
  } on FormatException {
    return false;
  }
}

abstract interface class AndroidSessionBridge {
  bool get supportsRememberedSession;
  Future<IdentityView?> resumeIdentity();
  Future<SessionPreferences> sessionPreferences();
  Future<SessionPreferences> setPinLock(String ownerId, bool required);
  Future<void> saveSessionRoute(String ownerId, String path);
}
