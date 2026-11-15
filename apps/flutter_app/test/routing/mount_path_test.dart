import 'package:cht/routing/mount_path.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('chat mount preserves deep links and browser navigation', () {
    const mount = AppMount('/chat/');
    expect(
      mount.internal('/chat/chats/did%3Acht%3Aabc'),
      '/chats/did%3Acht%3Aabc',
    );
    expect(mount.external('/contacts'), '/chat/contacts');
    expect(mount.external('/'), '/chat/');
    expect(mount.internal('/chat'), '/');
    expect(mount.internal('/chatty/chats'), '/');
  });
  test('root desktop and localhost routes remain unchanged', () {
    const mount = AppMount('/');
    expect(mount.internal('/chats/a'), '/chats/a');
    expect(mount.external('/connect/a'), '/connect/a');
    expect(
      AppMount.fromBaseUri(Uri.parse('http://localhost:8080/')).prefix,
      '',
    );
    expect(
      AppMount.fromBaseUri(Uri.parse('https://chta.app/chat/')).prefix,
      '/chat',
    );
  });
  test('browser navigation never accepts network paths outside the mount', () {
    expect(const AppMount('/').external('//outside.example/chat'), '/');
    expect(const AppMount('/chat/').external('/\\outside.example'), '/chat/');
  });
}
