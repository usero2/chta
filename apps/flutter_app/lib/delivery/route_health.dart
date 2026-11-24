import 'dart:math';

class RouteHealth {
  int failures = 0, cooldownUntil = 0, lastReceipt = 0;
  void failed(int now, double jitter) {
    failures = min(8, failures + 1);
    cooldownUntil =
        now +
        (min(30000, 500 * (1 << failures)) * (0.75 + jitter.clamp(0, 1) * 0.5))
            .round();
  }

  void received(int now) {
    failures = 0;
    cooldownUntil = 0;
    lastReceipt = now;
  }
}
