import 'package:flutter/foundation.dart';

import 'account_bridge.dart';
import 'account_models.dart';
import 'desktop_identity_bridge.dart';
import 'android_session_bridge.dart';

enum AccountStatus {
  loading,
  needsIdentity,
  recoveryConfirmation,
  chooseIdentity,
  pinSetup,
  ready,
  failed,
}

class AccountController extends ChangeNotifier {
  AccountController(this.bridge);

  final AccountBridge bridge;
  AccountStatus status = AccountStatus.loading;
  IdentityView? identity;
  CreatedIdentityView? pendingIdentity;
  Object? error;
  bool working = false;
  List<SavedIdentityView> savedIdentities = const [];
  bool pinLockEnabled = true;
  String? rememberedRoute;
  Object? sessionError;
  int _sessionGeneration = 0;
  Future<void> _sessionWrites = Future.value();
  AndroidSessionBridge? get _session =>
      bridge is AndroidSessionBridge &&
          (bridge as AndroidSessionBridge).supportsRememberedSession
      ? bridge as AndroidSessionBridge
      : null;
  bool get supportsPinLockPreference => _session != null;
  DesktopIdentityBridge? get desktop =>
      bridge is DesktopIdentityBridge ? bridge as DesktopIdentityBridge : null;
  String? get errorMessage => error == null
      ? null
      : error is StateError
      ? (error as StateError).message.toString()
      : error.toString();

  Future<void> initialize() async {
    _sessionGeneration++;
    identity = null;
    pendingIdentity = null;
    pinLockEnabled = true;
    rememberedRoute = null;
    sessionError = null;
    try {
      savedIdentities = await desktop?.savedIdentities() ?? const [];
      Object? resumeError;
      if (_session != null) {
        try {
          identity = await _session!.resumeIdentity();
        } catch (_) {
          resumeError = StateError(
            'Remembered session unavailable. Enter PIN to continue.',
          );
        }
      }
      if (await bridge.hasIdentity()) {
        identity = await bridge.identity();
        await _readSessionPreferences();
        status =
            savedIdentities
                    .where((entry) => entry.identityId == identity!.id)
                    .firstOrNull
                    ?.requiresPin ==
                false
            ? AccountStatus.pinSetup
            : AccountStatus.ready;
      } else {
        status = desktop == null
            ? AccountStatus.needsIdentity
            : AccountStatus.chooseIdentity;
      }
      error = resumeError;
    } catch (caught) {
      error = caught;
      status = AccountStatus.failed;
    }
    notifyListeners();
  }

  Future<void> createIdentity() async {
    try {
      pendingIdentity = await bridge.createIdentity();
      status = AccountStatus.recoveryConfirmation;
      error = null;
    } catch (caught) {
      error = caught;
    }
    notifyListeners();
  }

  Future<void> cancelIdentityCreation() async {
    try {
      await bridge.discardPendingIdentity();
      pendingIdentity = null;
      identity = null;
      savedIdentities = await desktop?.savedIdentities() ?? const [];
      status = desktop == null
          ? AccountStatus.needsIdentity
          : AccountStatus.chooseIdentity;
      error = null;
    } catch (caught) {
      error = caught;
    }
    notifyListeners();
  }

  Future<bool> confirmRecovery(String phrase) async {
    try {
      identity = await bridge.confirmRecovery(phrase);
      pendingIdentity = null;
      status = desktop == null ? AccountStatus.ready : AccountStatus.pinSetup;
      error = null;
      notifyListeners();
      return true;
    } catch (caught) {
      error = caught;
      notifyListeners();
      return false;
    }
  }

  Future<bool> restoreIdentity(String phrase) async {
    try {
      identity = await bridge.restoreIdentity(phrase);
      pendingIdentity = null;
      status = desktop == null ? AccountStatus.ready : AccountStatus.pinSetup;
      error = null;
      notifyListeners();
      return true;
    } catch (caught) {
      error = caught;
      notifyListeners();
      return false;
    }
  }

  void beginRestore() {
    error = null;
    status = AccountStatus.needsIdentity;
    notifyListeners();
  }

  Future<void> showIdentityList() async {
    savedIdentities = await desktop!.savedIdentities();
    status = AccountStatus.chooseIdentity;
    error = null;
    notifyListeners();
  }

  Future<bool> savePin(String pin, String displayName, String avatar) async {
    if (working) return false;
    working = true;
    error = null;
    notifyListeners();
    try {
      identity = await desktop!.rememberIdentity(pin, displayName, avatar);
      await _readSessionPreferences();
      savedIdentities = await desktop!.savedIdentities();
      status = AccountStatus.ready;
      return true;
    } catch (caught) {
      error = caught;
      return false;
    } finally {
      working = false;
      notifyListeners();
    }
  }

  Future<bool> unlock(String id, String pin) async {
    if (working) return false;
    working = true;
    error = null;
    notifyListeners();
    try {
      identity = await desktop!.unlockIdentity(id, pin);
      _sessionGeneration++;
      await _readSessionPreferences();
      status =
          savedIdentities
                  .where((entry) => entry.identityId == id)
                  .firstOrNull
                  ?.requiresPin ==
              false
          ? AccountStatus.pinSetup
          : AccountStatus.ready;
      return true;
    } catch (caught) {
      identity = null;
      error = caught;
      savedIdentities = await desktop!.savedIdentities();
      return false;
    } finally {
      working = false;
      notifyListeners();
    }
  }

  Future<void> lock() async {
    _sessionGeneration++;
    await _sessionWrites;
    await desktop!.lockIdentity();
    identity = null;
    pendingIdentity = null;
    pinLockEnabled = true;
    rememberedRoute = null;
    await showIdentityList();
  }

  Future<void> _readSessionPreferences() async {
    pinLockEnabled = true;
    rememberedRoute = null;
    if (_session == null) return;
    try {
      final value = await _session!.sessionPreferences();
      pinLockEnabled = value.pinRequired;
      rememberedRoute = value.lastRoute;
      sessionError = null;
    } catch (caught) {
      sessionError = caught;
    }
  }

  Future<void> _enqueueSession(Future<void> Function() operation) {
    final pending = _sessionWrites.then((_) => operation());
    _sessionWrites = pending.then(
      (_) {},
      onError: (Object caught) {
        sessionError = caught;
      },
    );
    return pending;
  }

  bool _ownsSession(String owner, int generation) =>
      status == AccountStatus.ready &&
      identity?.id == owner &&
      generation == _sessionGeneration;

  Future<void> setPinLock(bool required) {
    final owner = identity?.id;
    final generation = _sessionGeneration;
    if (_session == null || owner == null) {
      throw StateError('Unlock an identity first');
    }
    return _enqueueSession(() async {
      if (!_ownsSession(owner, generation)) {
        throw StateError('Identity changed');
      }
      final value = await _session!.setPinLock(owner, required);
      if (!_ownsSession(owner, generation)) {
        throw StateError('Identity changed');
      }
      pinLockEnabled = value.pinRequired;
      rememberedRoute = value.lastRoute;
      sessionError = null;
      notifyListeners();
    });
  }

  Future<void> rememberRoute(String path) {
    final owner = identity?.id;
    final generation = _sessionGeneration;
    if (_session == null || owner == null || !isSessionRoute(path)) {
      return Future.value();
    }
    return _enqueueSession(() async {
      if (!_ownsSession(owner, generation)) return;
      await _session!.saveSessionRoute(owner, path);
      if (_ownsSession(owner, generation)) rememberedRoute = path;
    }).catchError((Object caught) {
      sessionError = caught;
    });
  }

  Future<void> flushSessionWrites() => _sessionWrites;
}
