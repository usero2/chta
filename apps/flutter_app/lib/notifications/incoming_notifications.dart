import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../chat/chat_attachment.dart';
import '../groups/group_blob_bridge.dart';

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
    this.settings,
  }) : backend = backend ?? createNotificationBackend() {
    _preferenceLoaded = settings == null;
  }
  final String identityId;
  final NotificationBackend backend;
  final GroupBlobBridge? settings;
  static const _settingsKey = 'notification-settings-v1';
  static const _previewKey = 'notification-message-preview-v1';
  static const _previewLength = 160;
  final _seen = <(String, String)>{};
  bool _enabled = false;
  bool _showMessagePreview = false;
  int _previewVersion = 0;
  bool _alertsRequested = true, _preferenceLoaded = false;
  int _choiceVersion = 0, _permissionVersion = 0, _permissionRequests = 0;
  Future<void> _writes = Future.value();
  final _choices = <Future<bool>>{};
  int _changesPaused = 0;
  bool _unavailable = false;
  bool _disposed = false;
  Future<void>? _initialization;
  bool get enabled => _preferenceLoaded && _alertsRequested && _enabled;
  bool get showMessagePreview => _showMessagePreview;
  bool get unavailable => _unavailable;
  bool get canChange => !_disposed && _changesPaused == 0;

  Future<void> withChangesPaused(Future<void> Function() action) async {
    _changesPaused++;
    if (!_disposed) notifyListeners();
    try {
      await action();
    } finally {
      _changesPaused--;
      if (!_disposed) notifyListeners();
    }
  }

  // This only checks existing permission. Never prompt at startup or on receipt.
  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    final permissionVersion = _permissionVersion;
    final permissionPending = _permissionRequests > 0;
    try {
      final source = await settings?.loadGroupBlob(identityId, _settingsKey);
      var requested = true;
      if (source != null) {
        final value = jsonDecode(source);
        if (value is! Map ||
            value['version'] != 1 ||
            value['enabled'] is! bool) {
          throw const FormatException('Invalid notification preference');
        }
        requested = value['enabled'] as bool;
      }
      if (_disposed) return;
      if (_choiceVersion == 0) _alertsRequested = requested;
      try {
        final preview = await settings?.loadGroupBlob(identityId, _previewKey);
        if (!_disposed && _previewVersion == 0) {
          _showMessagePreview = preview == 'true';
        }
      } catch (_) {
        // A missing preview preference keeps message content hidden.
      }
      if (_disposed) return;
      _preferenceLoaded = true;
      final allowed = await backend.initialize();
      if (!_disposed) {
        if (!permissionPending && permissionVersion == _permissionVersion) {
          _enabled = allowed;
        }
        notifyListeners();
      }
    } catch (_) {
      // Notifications are optional; missing OS support must not break chat.
      if (!_disposed) {
        _unavailable = true;
        if (_choiceVersion == 0) _alertsRequested = false;
        _preferenceLoaded = true;
        notifyListeners();
      }
    }
  }

  // Call directly from a user gesture, especially on Web.
  Future<bool> requestPermissions() async {
    if (_disposed) return false;
    final version = ++_permissionVersion;
    _permissionRequests++;
    try {
      final allowed = await backend.requestPermissions();
      if (_disposed || version != _permissionVersion) return false;
      _permissionVersion++;
      _enabled = allowed;
      notifyListeners();
      return allowed;
    } catch (_) {
      if (!_disposed && version == _permissionVersion) {
        _permissionVersion++;
        _enabled = false;
        notifyListeners();
      }
      return false;
    } finally {
      _permissionRequests--;
    }
  }

  Future<bool> setEnabled(bool value) {
    if (!canChange) return Future.value(enabled);
    final version = ++_choiceVersion;
    _alertsRequested = value;
    // Start permission synchronously in the gesture, before storage awaits.
    final permission = value ? requestPermissions() : Future.value(false);
    notifyListeners();
    final change = _saveChoice(value, version, permission);
    _choices.add(change);
    change.then<void>(
      (_) => _choices.remove(change),
      onError: (Object _, StackTrace _) => _choices.remove(change),
    );
    return change;
  }

  Future<bool> _saveChoice(
    bool value,
    int version,
    Future<bool> permission,
  ) async {
    await initialize();
    await permission;
    if (_disposed || version != _choiceVersion) return enabled;
    final choice = value && _enabled;
    _alertsRequested = choice;
    final write = _writes.then((_) async {
      if (_disposed || version != _choiceVersion) return;
      await settings?.saveGroupBlob(
        identityId,
        _settingsKey,
        jsonEncode({'version': 1, 'enabled': choice}),
      );
    });
    _writes = write.catchError((Object _) {});
    try {
      await write;
      if (!_disposed && version == _choiceVersion) _unavailable = false;
    } catch (_) {
      if (!_disposed && version == _choiceVersion) {
        _alertsRequested = false;
        notifyListeners();
      }
      rethrow;
    }
    if (!_disposed) notifyListeners();
    return enabled;
  }

  Future<void> flush() async {
    while (true) {
      for (final change in _choices.toList()) {
        try {
          await change;
        } catch (_) {
          // The setter reports save failures; optional alerts cannot block lock.
        }
      }
      final pending = _writes;
      await pending;
      if (_choices.isEmpty && identical(pending, _writes)) return;
    }
  }

  /// Deliver only newly received, persisted text or completed file events.
  /// Loaded history must be marked [isHistory], or excluded by the caller.
  Future<void> notifyIncoming({
    required String peerId,
    required String displayName,
    required String messageId,
    String? fileName,
    String? messageText,
    Future<ChatAttachment> Function()? loadMarkdown,
    int? markdownSize,
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
    final choiceVersion = _choiceVersion;
    if (!_alertsRequested) return;
    await initialize();
    if (_disposed || !enabled || choiceVersion != _choiceVersion) return;
    final title = _clean(displayName, 64);
    final name = _clean(fileName ?? '', 160);
    final isFile =
        kind == IncomingNotificationKind.file && loadMarkdown == null;
    var body = isFile
        ? (name.isEmpty ? 'Received file' : 'Received file: $name')
        : 'New message';
    if (!isFile && _showMessagePreview) {
      final previewVersion = _previewVersion;
      String? text = messageText;
      try {
        if (loadMarkdown != null &&
            markdownSize != null &&
            markdownSize <= ChatAttachment.maxLongMessageBytes) {
          text = await (await loadMarkdown()).readTextExcerpt(_previewLength);
        }
      } catch (_) {
        // A file that cannot be opened still produces a generic alert.
      }
      if (_disposed || !enabled || choiceVersion != _choiceVersion) return;
      if (_showMessagePreview && previewVersion == _previewVersion) {
        final preview = _clean(text ?? '', _previewLength);
        if (preview.isNotEmpty) body = preview;
      }
    }
    try {
      await backend.show(
        IncomingNotification(
          identityId: identityId,
          peerId: peerId,
          messageId: messageId,
          title: title.isEmpty ? 'chta' : title,
          body: body,
        ),
      );
    } catch (_) {
      // Delivery failures never fail receipt processing or replay later.
    }
  }

  Future<void> setShowMessagePreview(bool value) {
    if (!canChange) return Future.value();
    final version = ++_previewVersion;
    if (!value && _showMessagePreview) {
      _showMessagePreview = false;
      notifyListeners();
    }
    final write = _writes.then((_) async {
      await initialize();
      if (_disposed || version != _previewVersion) return;
      await settings?.saveGroupBlob(identityId, _previewKey, value.toString());
      if (_disposed || version != _previewVersion) return;
      _showMessagePreview = value;
      notifyListeners();
    });
    _writes = write.catchError((Object _) {});
    return write;
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
  return clean.characters.take(maxLength).toString();
}
