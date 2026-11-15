import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'notification_backend_stub.dart'
    if (dart.library.io) 'notification_backend_native.dart'
    if (dart.library.js_interop) 'notification_backend_web.dart';

enum IncomingNotificationKind { message, file, control }

class IncomingNotification {
  const IncomingNotification({
    required this.identityId,
    required this.peerId,
    required this.messageId,
    required this.title,
    required this.body,
  });
  final String identityId;
  final String peerId;
  final String messageId;
  final String title;
  final String body;
  String get tag => sha256
      .convert(utf8.encode(jsonEncode([identityId, peerId, messageId])))
      .toString();
}

abstract interface class NotificationBackend {
  Future<bool> initialize();
  Future<bool> requestPermissions();
  Future<void> show(IncomingNotification notification);
}

class IncomingNotifications extends ChangeNotifier {
  IncomingNotifications({
    required this.identityId,
    NotificationBackend? backend,
  }) : backend = backend ?? createNotificationBackend();
  final String identityId;
  final NotificationBackend backend;
  final _seen = <(String, String)>{};
  bool _enabled = false;
  bool _disposed = false;
  Future<void>? _initialization;
  bool get enabled => _enabled;

  // This only checks existing permission. Never prompt at startup or on receipt.
  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    try {
      final allowed = await backend.initialize();
      if (!_disposed) {
        _enabled = allowed;
        notifyListeners();
      }
    } catch (_) {
      // Notifications are optional; missing OS support must not break chat.
    }
  }

  // Call directly from a user gesture, especially on Web.
  Future<bool> requestPermissions() async {
    if (_disposed) return false;
    try {
      final allowed = await backend.requestPermissions();
      if (_disposed) return false;
      _enabled = allowed;
      notifyListeners();
      return allowed;
    } catch (_) {
      return false;
    }
  }

  /// Deliver only newly received, persisted text or completed file events.
  /// Loaded history must be marked [isHistory], or excluded by the caller.
  Future<void> notifyIncoming({
    required String peerId,
    required String displayName,
    required String messageId,
    String? fileName,
    bool incoming = true,
    bool isHistory = false,
    IncomingNotificationKind kind = IncomingNotificationKind.message,
  }) async {
    if (_disposed || !incoming || kind == IncomingNotificationKind.control) {
      return;
    }
    final key = (peerId, messageId);
    if (!_seen.add(key)) return;
    if (_seen.length > 4096) _seen.remove(_seen.first);
    if (isHistory) return;
    await initialize();
    if (_disposed || !_enabled) return;
    final title = _clean(displayName, 64);
    final name = _clean(fileName ?? '', 160);
    try {
      await backend.show(
        IncomingNotification(
          identityId: identityId,
          peerId: peerId,
          messageId: messageId,
          title: title.isEmpty ? 'chta' : title,
          body: kind == IncomingNotificationKind.file
              ? (name.isEmpty ? 'Received file' : 'Received file: $name')
              : 'New message',
        ),
      );
    } catch (_) {
      // Delivery failures never fail receipt processing or replay later.
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _seen.clear();
    super.dispose();
  }
}

String _clean(String value, int maxLength) {
  final clean = value
      .replaceAll(
        RegExp(r'[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]'),
        ' ',
      )
      .trim();
  return String.fromCharCodes(clean.runes.take(maxLength));
}
