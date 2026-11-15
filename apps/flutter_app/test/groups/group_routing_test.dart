import 'package:cht/routing/app_router.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('group deep links stay separate from friend and local chat routes', () {
    final id = 'group:${'a' * 64}';
    final path = conversationRoute(id);
    expect(groupIdFromChatRoute(path), id);
    expect(contactIdFromChatRoute(path), isNull);
    expect(groupIdFromChatRoute('/chats/group:bad'), isNull);
    expect(groupIdFromChatRoute('/contacts'), isNull);
  });
}
