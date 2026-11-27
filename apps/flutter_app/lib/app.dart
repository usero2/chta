import 'package:flutter/material.dart';

import 'account/account_controller.dart';
import 'account/account_gate.dart';
import 'chat/chat_controller.dart';
import 'chat/chat_shell.dart';
import 'chat/peer_history_store.dart';
import 'core/core_bridge.dart';
import 'profile/profile_controller.dart';
import 'routing/app_router.dart';

class ChtApp extends StatelessWidget {
  const ChtApp({
    required this.controller,
    required this.coreBridge,
    required this.router,
    this.accountController,
    this.profileController,
    this.peerHistoryStore,
    super.key,
  });

  final ChatController controller;
  final CoreBridge coreBridge;
  final AppRouter router;
  final AccountController? accountController;
  final ProfileController? profileController;
  final PeerHistoryStore? peerHistoryStore;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'chta',
    locale: const Locale('en', 'US'),
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF9AE585),
        brightness: Brightness.dark,
        surface: const Color(0xFF1C1C1E),
      ),
      scaffoldBackgroundColor: const Color(0xFF1A1A1A),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: Color(0xFF2A2A2C),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(24)),
          borderSide: BorderSide.none,
        ),
      ),
    ),
    home: accountController == null
        ? ChatShell(controller: controller, coreBridge: coreBridge)
        : AccountGate(
            controller: accountController!,
            chatController: controller,
            bridge: coreBridge as AppBridge,
            profileController: profileController,
            router: router,
            peerHistoryStore: peerHistoryStore,
          ),
  );
}
