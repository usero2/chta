import '../chat/chat_models.dart';
import '../account/account_bridge.dart';

abstract interface class CoreBridge {
  Future<String> version();

  Future<ChatSnapshot> loadSnapshot();

  Future<ChatSnapshot> sendText(
    String conversationId,
    String text,
    int sentAtMilliseconds,
  );
}

abstract interface class AppBridge implements CoreBridge, AccountBridge {}

abstract interface class ConversationManagementBridge {
  Future<ChatSnapshot> deleteConversation(String conversationId);
}

abstract interface class InitializableCoreBridge {
  Future<void> initializePlatform();
}
