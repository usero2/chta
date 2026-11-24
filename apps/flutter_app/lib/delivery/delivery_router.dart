import 'dart:async';
import 'dart:math';

import 'route_health.dart';
import 'local_diagnostics.dart';

enum DeliveryRouteKind { direct, relay, courier }

class DeliveryRoute {
  const DeliveryRoute({
    required this.id,
    required this.kind,
    required this.authenticated,
    required this.send,
  });
  final String id;
  final DeliveryRouteKind kind;
  final bool authenticated;
  final Future<void> Function() send;
}

class _Attempt {
  _Attempt(this.route, this.at, {this.offline = false});
  final bool offline;
  final String route;
  final int at;
  bool received = false;
}

/// Route usability and recipient receipts are distinct. A socket write is not delivery.
class DeliveryRouter {
  DeliveryRouter({
    int Function()? clock,
    double Function()? jitter,
    this.attemptTimeout = const Duration(seconds: 2),
    this.onMetric,
  }) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
       _jitter = jitter ?? Random().nextDouble;
  final int Function() _clock;
  final double Function() _jitter;
  final Duration attemptTimeout;
  final void Function(DeliveryMetric)? onMetric;
  final _health = <String, RouteHealth>{}, _pending = <String, _Attempt>{};
  String? _preferred;
  String? _lastRoute;
  int _holdUntil = 0;
  int get pendingCount => _pending.length;
  RouteHealth healthFor(String id) => _health.putIfAbsent(id, RouteHealth.new);
  void failed(String routeId) => healthFor(routeId).failed(_clock(), _jitter());
  void receivedOn(String routeId) {
    healthFor(routeId).received(_clock());
    _preferred = routeId;
    _holdUntil = _clock() + 30000;
  }

  List<DeliveryRoute> rank(List<DeliveryRoute> routes, {String? avoid}) {
    final now = _clock();
    final usable = routes
        .where((r) => r.authenticated && healthFor(r.id).cooldownUntil <= now)
        .toList();
    int score(DeliveryRoute r) =>
        r.kind.index * 100 +
        (r.id == avoid ? 1000 : 0) -
        (r.kind != DeliveryRouteKind.courier &&
                r.id == _preferred &&
                now < _holdUntil
            ? 200
            : 0);
    usable.sort((a, b) => score(a).compareTo(score(b)));
    return usable;
  }

  void acknowledge(String messageId, {String? routeId}) {
    final attempt = _pending.remove(messageId);
    if (attempt == null) return;
    attempt.received = true;
    healthFor(routeId ?? attempt.route).received(_clock());
    _preferred = routeId ?? attempt.route;
    _holdUntil = _clock() + 30000;
  }

  void clear() {
    _pending.clear();
    _health.clear();
    _preferred = null;
    _lastRoute = null;
    _holdUntil = 0;
  }

  Future<String> send(
    String messageId,
    List<DeliveryRoute> routes, {
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) throw StateError('Identity changed');
    final now = _clock(), previous = _pending[messageId];
    if (previous != null && !previous.offline && now - previous.at >= 4000) {
      healthFor(previous.route).failed(now, _jitter());
      onMetric?.call(DeliveryMetric.receiptTimeout);
    }
    final usable = rank(routes, avoid: previous?.route);
    Object? error;
    StackTrace? stack;
    for (final route in usable) {
      if (!isCurrent()) throw StateError('Identity changed');
      final attempt = _Attempt(
        route.id,
        _clock(),
        offline: route.kind == DeliveryRouteKind.courier,
      );
      if (!_pending.containsKey(messageId) && _pending.length >= 2048) {
        _pending.remove(
          _pending.keys.first,
        ); // Only an ephemeral route hint; sender intent lives in the outbox.
      }
      _pending[messageId] = attempt;
      try {
        await route.send().timeout(attemptTimeout);
        if (!isCurrent()) throw StateError('Identity changed');
        if (_lastRoute != null && _lastRoute != route.id) {
          onMetric?.call(DeliveryMetric.routeChange);
        }
        _lastRoute = route.id;
        return route.id;
      } catch (caught, trace) {
        if (!isCurrent()) throw StateError('Identity changed');
        if (attempt.received) return route.id;
        if (identical(_pending[messageId], attempt)) _pending.remove(messageId);
        healthFor(route.id).failed(_clock(), _jitter());
        onMetric?.call(DeliveryMetric.routeFailure);
        error = caught;
        stack = trace;
      }
    }
    if (error != null) Error.throwWithStackTrace(error, stack!);
    throw StateError('No authenticated delivery route');
  }
}
