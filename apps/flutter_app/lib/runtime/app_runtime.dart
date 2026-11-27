import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

const minBackgroundRefreshSeconds = 10;
const maxBackgroundRefreshSeconds = 300;

class RuntimeState {
  const RuntimeState({
    required this.enabled,
    required this.running,
    this.notificationVisible = true,
    this.canOpenBackgroundNotificationSettings = false,
    this.showLockAction = true,
    this.backgroundRefreshSeconds = minBackgroundRefreshSeconds,
  });
  final bool enabled;
  final bool running;
  final bool notificationVisible;
  final bool canOpenBackgroundNotificationSettings;
  final bool showLockAction;
  final int backgroundRefreshSeconds;
}

abstract interface class RuntimeBridge {
  Future<RuntimeState> configure({
    required bool active,
    bool? enabled,
    bool? showLockAction,
    int? backgroundRefreshSeconds,
  });

  Future<void> openBackgroundNotificationSettings();
}

class NativeRuntimeBridge implements RuntimeBridge {
  static const channel = MethodChannel('app.cht/runtime');

  @override
  Future<RuntimeState> configure({
    required bool active,
    bool? enabled,
    bool? showLockAction,
    int? backgroundRefreshSeconds,
  }) async {
    final state = await channel.invokeMapMethod<String, dynamic>('configure', {
      'active': active,
      'enabled': ?enabled,
      'showLockAction': ?showLockAction,
      'backgroundRefreshSeconds': ?backgroundRefreshSeconds,
    });
    final savedInterval = state?['backgroundRefreshSeconds'];
    return RuntimeState(
      enabled: state?['enabled'] == true,
      running: state?['running'] == true,
      notificationVisible: state?['notificationVisible'] != false,
      canOpenBackgroundNotificationSettings:
          state?['canOpenBackgroundNotificationSettings'] == true,
      showLockAction: state?['showLockAction'] != false,
      backgroundRefreshSeconds:
          savedInterval is int &&
              savedInterval >= minBackgroundRefreshSeconds &&
              savedInterval <= maxBackgroundRefreshSeconds
          ? savedInterval
          : minBackgroundRefreshSeconds,
    );
  }

  @override
  Future<void> openBackgroundNotificationSettings() =>
      channel.invokeMethod<void>('openBackgroundNotificationSettings');
}

/// Lives above navigation and never owns a second messaging isolate.
class AppRuntime extends ChangeNotifier with WidgetsBindingObserver {
  AppRuntime({required this.bridge});
  final RuntimeBridge bridge;
  static AppRuntime? instance;
  String? _owner;
  Future<void> Function()? _flush;
  Future<void> Function()? _lock;
  Future<void> _tail = Future.value();
  Future<bool>? _handling;
  bool enabled = true;
  bool running = false;
  bool notificationVisible = true;
  bool canOpenBackgroundNotificationSettings = false;
  bool showLockAction = true;
  int backgroundRefreshSeconds = minBackgroundRefreshSeconds;
  String? error;

  static Future<void> install() async {
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.windows)) {
      return;
    }
    final runtime = instance = AppRuntime(bridge: NativeRuntimeBridge());
    WidgetsBinding.instance.addObserver(runtime);
    NativeRuntimeBridge.channel.setMethodCallHandler(
      (call) => runtime.handle(call.method),
    );
    await runtime._configure();
  }

  Future<void> attach(
    String owner, {
    required Future<void> Function() flush,
    required Future<void> Function() lock,
  }) {
    _owner = owner;
    _flush = flush;
    _lock = lock;
    return _configure();
  }

  Future<void> detach(String owner) {
    if (_owner != owner) return Future.value();
    _owner = null;
    _flush = null;
    _lock = null;
    return _configure();
  }

  Future<void> setEnabled(bool value) => _configure(enabled: value);

  Future<void> openBackgroundNotificationSettings() =>
      bridge.openBackgroundNotificationSettings();

  Future<void> setShowLockAction(bool value) =>
      _configure(showLockAction: value);

  Future<void> setBackgroundRefreshSeconds(int value) {
    RangeError.checkValueInInterval(
      value,
      minBackgroundRefreshSeconds,
      maxBackgroundRefreshSeconds,
      'backgroundRefreshSeconds',
    );
    return _configure(backgroundRefreshSeconds: value);
  }

  Future<void> _configure({
    bool? enabled,
    bool? showLockAction,
    int? backgroundRefreshSeconds,
  }) {
    // Preserve ordering when lock/dispose and a new account overlap.
    final active = _owner != null;
    return _tail = _tail.then((_) async {
      try {
        final state = await bridge.configure(
          active: active,
          enabled: enabled,
          showLockAction: showLockAction,
          backgroundRefreshSeconds: backgroundRefreshSeconds,
        );
        this.enabled = state.enabled;
        running = state.running;
        notificationVisible = state.notificationVisible;
        canOpenBackgroundNotificationSettings =
            state.canOpenBackgroundNotificationSettings;
        this.showLockAction = state.showLockAction;
        this.backgroundRefreshSeconds = state.backgroundRefreshSeconds;
        error = null;
      } catch (_) {
        running = false;
        error = 'Background reception unavailable. Tap to retry.';
      }
      notifyListeners();
    });
  }

  Future<bool> handle(String method) {
    if (method != 'exitRequested' && method != 'lockRequested') {
      return Future.value(false);
    }
    // A retry after the native timeout must flush again, even while the prior
    // flush is still running: the reopened window can have new writes.
    return _handling = (_handling ?? Future.value(false)).then(
      (_) => _handle(method),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _owner != null) {
      unawaited(_configure());
    }
  }

  Future<bool> _handle(String method) async {
    final owner = _owner, flush = _flush, lock = _lock;
    try {
      await _tail;
      if (_owner != owner) return false;
      await flush?.call();
      if (_owner != owner) return false;
      if (method == 'lockRequested') {
        await lock?.call();
        if (owner != null) await detach(owner);
      }
      // A native exit may time out. Retain callbacks until the process actually
      // closes, so a cancelled/late exit cannot leave an unowned live session.
      return true;
    } catch (_) {
      error = 'Could not save changes. Keep the app open and try again.';
      notifyListeners();
      return false;
    }
  }
}
