import 'dart:convert';

/// Observed balance difference, not meter telemetry.
class DormUsagePoint {
  const DormUsagePoint({
    required this.startedAt,
    required this.endedAt,
    required this.consumedKwh,
  });
  final DateTime startedAt;
  final DateTime endedAt;
  final double consumedKwh;
  Duration get duration => endedAt.difference(startedAt);
  double get watts => consumedKwh * 3600000000000 / duration.inMicroseconds;
}

class DormUsageTotal {
  const DormUsageTotal(this.kwh, this.coverage);
  final double kwh;
  final Duration coverage;
}

class DormUsageHistory {
  static const minimumInterval = Duration(minutes: 10);
  static const maximumInterval = Duration(hours: 3);
  static const retention = Duration(days: 31);
  static const maxPoints = 4500;
  ({double kwh, DateTime at})? _baseline;
  ({double kwh, DateTime at})? _lastSeen;
  final _points = <DormUsagePoint>[];
  List<DormUsagePoint> get points => List.unmodifiable(_points);
  bool get hasCurrentInterval =>
      _points.isNotEmpty && _baseline?.at == _points.last.endedAt;
  void clear() {
    _baseline = null;
    _lastSeen = null;
    _points.clear();
  }

  /// True only for a new, usable observation. Gaps/top-ups end an interval,
  /// not the historical series. A clock rollback never produces overlap.
  bool record(double kwh, DateTime at) {
    if (!kwh.isFinite || kwh < 0) return false;
    final previous = _lastSeen;
    if (previous != null && !at.isAfter(previous.at)) return false;
    final sample = (kwh: kwh, at: at);
    _lastSeen = sample;
    _points.removeWhere((p) => p.endedAt.isBefore(at.subtract(retention)));
    final baseline = _baseline;
    if (baseline == null ||
        (previous != null && kwh > previous.kwh) ||
        at.difference(baseline.at) > maximumInterval) {
      _baseline = sample;
      return true;
    }
    if (at.difference(baseline.at) < minimumInterval) return true;
    final point = DormUsagePoint(
      startedAt: baseline.at,
      endedAt: at,
      consumedKwh: baseline.kwh - kwh,
    );
    if (point.watts.isFinite && point.watts >= 0) _points.add(point);
    _baseline = sample;
    if (_points.length > maxPoints) _points.removeAt(0);
    return true;
  }

  /// Prorates observed intervals at window boundaries; unobserved time is not zero.
  static DormUsageTotal total(
    List<DormUsagePoint> points,
    DateTime start,
    DateTime end,
  ) {
    var kwh = 0.0;
    var micros = 0;
    for (final p in points) {
      final from = p.startedAt.isAfter(start) ? p.startedAt : start;
      final to = p.endedAt.isBefore(end) ? p.endedAt : end;
      final overlap = to.difference(from).inMicroseconds;
      if (overlap <= 0 || p.duration.inMicroseconds <= 0) continue;
      micros += overlap;
      kwh += p.consumedKwh * overlap / p.duration.inMicroseconds;
    }
    return DormUsageTotal(kwh, Duration(microseconds: micros));
  }

  String encode(String scope) => jsonEncode({
    'scope': scope,
    'baseline': _baseline == null
        ? null
        : [_baseline!.kwh, _baseline!.at.millisecondsSinceEpoch],
    'last': _lastSeen == null
        ? null
        : [_lastSeen!.kwh, _lastSeen!.at.millisecondsSinceEpoch],
    'points': _points
        .map(
          (p) => [
            p.startedAt.millisecondsSinceEpoch,
            p.endedAt.millisecondsSinceEpoch,
            p.consumedKwh,
          ],
        )
        .toList(),
  });

  /// Reject malformed, overlapping, or wrong-scope persisted data as a whole.
  void restore(String? raw, String scope, DateTime now) {
    clear();
    if (raw == null || raw.length > 1000000) return;
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      if (data['scope'] != scope) return;
      DateTime time(Object? v) => DateTime.fromMillisecondsSinceEpoch(v as int);
      double amount(Object? v) {
        final n = (v as num).toDouble();
        if (!n.isFinite || n < 0) throw const FormatException('amount');
        return n;
      }

      ({double kwh, DateTime at})? sample(Object? v) {
        if (v == null) return null;
        final a = v as List<dynamic>;
        return (kwh: amount(a[0]), at: time(a[1]));
      }

      final base = sample(data['baseline']);
      final last = sample(data['last']);
      final records = data['points'] as List<dynamic>;
      if (records.length > maxPoints || (base == null) != (last == null)) {
        return;
      }
      if (base != null &&
          last != null &&
          (base.at.isAfter(last.at) ||
              last.at.isAfter(now) ||
              last.kwh > base.kwh)) {
        return;
      }
      DateTime? previousEnd;
      final loaded = <DormUsagePoint>[];
      for (final item in records) {
        final a = item as List<dynamic>;
        final p = DormUsagePoint(
          startedAt: time(a[0]),
          endedAt: time(a[1]),
          consumedKwh: amount(a[2]),
        );
        if (p.duration < minimumInterval ||
            p.duration > maximumInterval ||
            !p.watts.isFinite ||
            p.endedAt.isAfter(now) ||
            (previousEnd != null && p.startedAt.isBefore(previousEnd))) {
          return;
        }
        previousEnd = p.endedAt;
        if (!p.endedAt.isBefore(now.subtract(retention))) loaded.add(p);
      }
      if (previousEnd != null &&
          (base == null || base.at.isBefore(previousEnd))) {
        return;
      }
      _points.addAll(loaded);
      _baseline = base;
      _lastSeen = last;
    } catch (_) {
      clear();
    }
  }
}
