import 'dart:async';

import 'package:dio/dio.dart';

import '../auth/connect_mode_resolver.dart';
import '../auth/zhengfang_auth.dart';
import 'cancel_token_x.dart';
import 'route_failure.dart';

class RouteLease {
  const RouteLease._(
    this.mode,
    this.sessionRevision,
    this.didFallback,
    this.sessionEpoch,
  );

  final ZhengfangMode mode;
  final Object? sessionRevision;
  final bool didFallback;
  final int? sessionEpoch;
}

typedef RouteGatewayPreparation = Future<void> Function(
  CancelToken token,
  DateTime deadline,
);

/// Serializes route transitions per origin and shares ready leases for the same
/// preparation contract and session revision.
class RouteGate {
  RouteGate({
    ConnectModeResolver? resolver,
    this.leaseTtl = const Duration(seconds: 5),
  }) : _resolver = resolver ?? ConnectModeResolver.instance;

  static final instance = RouteGate();

  final ConnectModeResolver _resolver;
  final Duration leaseTtl;
  final _tails = <String, Future<void>>{};
  final _leases = <(String, Object?, ZhengfangMode?), _CachedRouteLease>{};
  final _flights = <Object, _RouteFlight>{};

  Future<RouteLease> acquire(
    Uri target, {
    Object? scope,
    Object? sessionRevision,
    Object? Function()? settledSessionRevision,
    int? Function()? settledSessionEpoch,
    ZhengfangMode? preferredMode,
    RouteGatewayPreparation? prepareWebVpn,
    Future<ZhengfangMode> Function()? resolveMode,
    bool allowReverseFallback = true,
    CancelToken? cancelToken,
    DateTime? deadline,
  }) async {
    final origin = target.origin;
    final leaseKey = (
      origin,
      (scope, prepareWebVpn != null, allowReverseFallback),
      preferredMode,
    );
    final version = _resolver.routeVersion(target);
    final cached = _leases[leaseKey];
    cancelToken?.throwIfCancelled();
    if (_tails[origin] == null &&
        cached != null &&
        cached.version == version &&
        cached.lease.sessionRevision == sessionRevision &&
        DateTime.now().isBefore(cached.expiresAt) &&
        (preferredMode != null || _resolver.hasCachedMode(target))) {
      return cached.lease;
    }

    final flightKey = (leaseKey, sessionRevision, version);
    var flight = _flights[flightKey];
    if (flight == null || flight.token.isCancelled) {
      final pending = _RouteFlight();
      final previous = _tails[origin] ?? Future<void>.value();
      pending.future = previous.then((_) async {
        pending.token.throwIfCancelled();
        final sharedDeadline = DateTime.now().add(const Duration(seconds: 20));
        final timer = Timer(const Duration(seconds: 20), () {
          pending.token.cancel('route preparation timed out');
        });
        final activeVersion = _resolver.routeVersion(target);
        try {
          ZhengfangMode mode;
          var didFallback = false;
          try {
            mode = preferredMode == ZhengfangMode.direct
                ? await _requireDirect(target)
                : preferredMode ??
                      await (resolveMode?.call() ??
                          _resolver.resolveOrThrow(target));
            pending.token.throwIfCancelled();
            if (mode == ZhengfangMode.webVpn && prepareWebVpn != null) {
              await prepareWebVpn(pending.token, sharedDeadline);
            }
          } on RouteFailure catch (error) {
            pending.token.throwIfCancelled();
            if (!allowReverseFallback ||
                error.reason != RouteFailureReason.webVpnGatewayFailed ||
                await _resolver.probeDirect(target) != RouteVerdict.direct) {
              rethrow;
            }
            mode = ZhengfangMode.direct;
            didFallback = true;
          }
          pending.token.throwIfCancelled();
          if (activeVersion != _resolver.routeVersion(target)) {
            throw const _RouteChanged();
          }
          if (mode == ZhengfangMode.direct &&
              (didFallback || preferredMode == mode)) {
            _resolver.markDirectReachable(target);
          }
          final lease = RouteLease._(
            mode,
            settledSessionRevision?.call() ?? sessionRevision,
            didFallback,
            settledSessionEpoch?.call(),
          );
          if (preferredMode != null || _resolver.hasCachedMode(target)) {
            _leases[leaseKey] = _CachedRouteLease(
              lease,
              _resolver.routeVersion(target),
              DateTime.now().add(leaseTtl),
            );
          }
          return lease;
        } catch (_) {
          if (!pending.token.isCancelled &&
              activeVersion != _resolver.routeVersion(target)) {
            throw const _RouteChanged();
          }
          rethrow;
        } finally {
          timer.cancel();
        }
      });
      late final Future<void> tail;
      void finish() {
        if (identical(_flights[flightKey], pending)) _flights.remove(flightKey);
        if (identical(_tails[origin], tail)) _tails.remove(origin);
      }

      tail = pending.future.then<void>(
        (_) => finish(),
        onError: (Object _) => finish(),
      );
      _tails[origin] = tail;
      flight = _flights[flightKey] = pending;
    }

    final active = flight;
    active.waiters++;
    Timer? deadlineTimer;
    try {
      final ifCancelled = cancelToken?.whenCancel.then<RouteLease>(
        (error) => throw error,
      );
      final ifExpired = deadline == null ? null : Completer<RouteLease>();
      if (deadline != null) {
        deadlineTimer = Timer(deadline.difference(DateTime.now()), () {
          ifExpired!.completeError(
            RouteFailure(RouteFailureReason.connectionFailed),
          );
        });
      }
      return await Future.any([
        active.future,
        ?ifCancelled,
        if (ifExpired != null) ifExpired.future,
      ]);
    } on _RouteChanged {
      return acquire(
        target,
        scope: scope,
        sessionRevision: sessionRevision,
        settledSessionRevision: settledSessionRevision,
        settledSessionEpoch: settledSessionEpoch,
        preferredMode: preferredMode,
        prepareWebVpn: prepareWebVpn,
        resolveMode: resolveMode,
        allowReverseFallback: allowReverseFallback,
        cancelToken: cancelToken,
        deadline: deadline,
      );
    } finally {
      deadlineTimer?.cancel();
      if (--active.waiters == 0 && identical(_flights[flightKey], active)) {
        active.token.cancel('route preparation has no waiters');
      }
    }
  }

  Future<ZhengfangMode> _requireDirect(Uri target) async {
    final verdict = await _resolver.probeDirect(target);
    if (verdict == RouteVerdict.direct) return ZhengfangMode.direct;
    throw RouteFailure(
      verdict == RouteVerdict.unknownRedirect
          ? RouteFailureReason.unknownRedirect
          : RouteFailureReason.connectionFailed,
    );
  }
}

class _RouteChanged implements Exception {
  const _RouteChanged();
}

class _RouteFlight {
  final token = CancelToken();
  late Future<RouteLease> future;
  int waiters = 0;
}

class _CachedRouteLease {
  const _CachedRouteLease(this.lease, this.version, this.expiresAt);

  final RouteLease lease;
  final (int, int) version;
  final DateTime expiresAt;
}
