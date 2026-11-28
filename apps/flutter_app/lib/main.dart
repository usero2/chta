import 'dart:async';

import 'package:flutter/widgets.dart';

import 'app.dart';
import 'account/account_controller.dart';
import 'account/desktop_identity_bridge.dart';
import 'account/share_link_inbox.dart';
import 'chat/chat_controller.dart';
import 'core/core_bridge_factory.dart';
import 'core/core_bridge.dart';
import 'profile/profile_controller.dart';
import 'profile/profile_store.dart';
import 'routing/app_router.dart';
import 'startup/app_bootstrap.dart';
import 'runtime/app_runtime.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppRuntime.install();
  unawaited(startShareLinkInbox());
  runApp(AppBootstrap(load: _loadApp));
}

Future<Widget> _loadApp() async {
  final coreBridge = createCoreBridge();
  if (coreBridge is InitializableCoreBridge) {
    await (coreBridge as InitializableCoreBridge).initializePlatform();
  }
  final profileController = ProfileController(
    createProfileStore(
      identityBridge: coreBridge is DesktopIdentityBridge
          ? coreBridge as DesktopIdentityBridge
          : null,
    ),
  );
  await profileController.load();
  return ChtApp(
    controller: ChatController(coreBridge: coreBridge),
    coreBridge: coreBridge,
    accountController: AccountController(coreBridge),
    profileController: profileController,
    router: AppRouter(),
  );
}
