import 'package:cht/runtime/network_monitor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('platform monitor closes after its last subscriber cancels', () async {
    final monitor = createNetworkMonitor();
    final subscription = monitor.changes.listen((_) {});
    await subscription.cancel();
    await monitor.close();
  }, timeout: const Timeout(Duration(seconds: 10)));
}
