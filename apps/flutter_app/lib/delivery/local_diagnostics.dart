import 'dart:async';
import 'dart:convert';

import '../courier/courier_models.dart';
import '../groups/group_blob_bridge.dart';

enum DeliveryMetric {
  seedQuotaUnavailable,
  routeFailure,
  routeChange,
  receiptTimeout,
  courierWaiting,
  courierDeposited,
  courierPickedUp,
  courierExpired,
  repaired,
  failure,
}

enum DiagnosticSeed { unavailable, connecting, connected, quotaUnavailable }

String? courierStatusLabel(CourierJobStatus status, int availableNodes) =>
    switch (status) {
      CourierJobStatus.preparing => 'Preparing offline delivery',
      CourierJobStatus.waitingForNodes =>
        availableNodes < 2
            ? 'Waiting for 2 Couriers'
            : 'Waiting for Courier space',
      CourierJobStatus.depositing => 'Depositing with Couriers',
      CourierJobStatus.stored => 'Deposited · waiting for recipient',
      CourierJobStatus.paused => 'Paused',
      CourierJobStatus.cancelled => 'Cancelled',
      CourierJobStatus.expired => 'Courier deposit expired',
      CourierJobStatus.failed => 'Courier delivery unavailable',
      CourierJobStatus.delivered => null,
    };

/// Only enum-keyed counters and aggregate current state can enter the report.
class LocalDeliveryDiagnostics {
  LocalDeliveryDiagnostics({
    required this.owner,
    required this.storage,
    bool Function()? isCurrent,
  }) : _isCurrent = isCurrent ?? (() => true);
  final String owner;
  final GroupBlobBridge storage;
  final bool Function() _isCurrent;
  static const _key = 'delivery_metrics_v1', _max = 1000000000;
  final _counts = <DeliveryMetric, int>{};
  Timer? _saveTimer;
  Future<void>? _load;
  Future<void> _writes = Future.value();
  bool _closed = false;
  int _revision = 0, _saved = 0;
  bool get active => !_closed && _isCurrent();
  int total(DeliveryMetric key) => _counts[key] ?? 0;
  Future<void> load() => _load ??= _read();
  Future<void> _read() async {
    if (!active) return;
    final source = await storage.loadGroupBlob(owner, _key);
    if (!active || source == null) return;
    final decoded = jsonDecode(source);
    if (decoded is! Map || decoded.length > DeliveryMetric.values.length) {
      return;
    }
    for (final metric in DeliveryMetric.values) {
      final count = decoded[metric.name];
      if (count is int && count >= 0 && count <= _max) {
        _counts[metric] = (total(metric) + count).clamp(0, _max);
      }
    }
  }

  void count(DeliveryMetric key, [int amount = 1]) {
    if (!active || amount <= 0) return;
    _counts[key] = (total(key) + amount.clamp(0, _max)).clamp(0, _max);
    _revision++;
    _saveTimer ??= Timer(const Duration(seconds: 5), () {
      _saveTimer = null;
      unawaited(flush().catchError((Object _) {}));
    });
  }

  Future<void> flush() {
    final pending = _writes.then((_) async {
      if (!active || _saved == _revision) return;
      await load();
      if (!active) return;
      final revision = _revision;
      await storage.saveGroupBlob(owner, _key, jsonEncode(_totals));
      if (active) _saved = revision;
    });
    _writes = pending.catchError((Object _) {});
    return pending;
  }

  Map<String, int> get _totals => {
    for (final metric in DeliveryMetric.values) metric.name: total(metric),
  };
  String export({
    required DiagnosticSeed seed,
    required int activeRoutes,
    required int warmRoutes,
    required int knownCouriers,
    required bool hosting,
  }) => const JsonEncoder.withIndent('  ').convert({
    'version': 1,
    'seed': seed.name,
    'activeRoutes': activeRoutes.clamp(0, 1000),
    'warmRoutes': warmRoutes.clamp(0, 1000),
    'knownCouriers': knownCouriers.clamp(0, 256),
    'hosting': hosting,
    'totals': _totals,
  });
  void close() {
    _closed = true;
    _saveTimer?.cancel();
  }
}
