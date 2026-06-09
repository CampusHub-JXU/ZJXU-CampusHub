import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ServiceHubUsageEntry {
  const ServiceHubUsageEntry({
    required this.id,
    required this.visitCount,
    required this.lastVisitedAt,
  });

  final String id;
  final int visitCount;
  final DateTime lastVisitedAt;

  ServiceHubUsageEntry recordVisit(DateTime now) {
    return ServiceHubUsageEntry(
      id: id,
      visitCount: visitCount + 1,
      lastVisitedAt: now,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'visitCount': visitCount,
      'lastVisitedAt': lastVisitedAt.millisecondsSinceEpoch,
    };
  }

  static ServiceHubUsageEntry? fromJson(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    final id = (value['id'] as String? ?? '').trim();
    final visitCount = value['visitCount'] as int? ?? 0;
    final lastVisitedAtMillis = value['lastVisitedAt'] as int?;
    if (id.isEmpty || visitCount <= 0 || lastVisitedAtMillis == null) {
      return null;
    }
    return ServiceHubUsageEntry(
      id: id,
      visitCount: visitCount,
      lastVisitedAt: DateTime.fromMillisecondsSinceEpoch(lastVisitedAtMillis),
    );
  }
}

class ServiceHubUsageSnapshot {
  const ServiceHubUsageSnapshot({
    this.pinnedIds = const [],
    this.usageById = const {},
  });

  final List<String> pinnedIds;
  final Map<String, ServiceHubUsageEntry> usageById;

  bool get isEmpty => pinnedIds.isEmpty && usageById.isEmpty;

  bool isPinned(String id) => pinnedIds.contains(id);
}

class ServiceHubUsageStore extends ChangeNotifier {
  ServiceHubUsageStore._();

  static final ServiceHubUsageStore instance = ServiceHubUsageStore._();

  static const maxPinnedEntries = 6;
  static const _pinnedKey = 'service_hub_pinned_ids_v1';
  static const _usageKey = 'service_hub_usage_v1';

  SharedPreferences? _prefs;
  bool _restored = false;
  var _snapshot = const ServiceHubUsageSnapshot();

  ServiceHubUsageSnapshot get snapshot => _snapshot;

  Future<void> restore() async {
    if (_restored) return;
    _prefs = await SharedPreferences.getInstance();
    _snapshot = ServiceHubUsageSnapshot(
      pinnedIds: _restorePinnedIds(_prefs),
      usageById: _restoreUsage(_prefs),
    );
    _restored = true;
  }

  Future<void> recordVisit(String id, {DateTime? now}) async {
    await restore();
    final trimmedId = id.trim();
    if (trimmedId.isEmpty) return;

    final timestamp = now ?? DateTime.now();
    final usage = Map<String, ServiceHubUsageEntry>.from(_snapshot.usageById);
    usage[trimmedId] =
        usage[trimmedId]?.recordVisit(timestamp) ??
        ServiceHubUsageEntry(
          id: trimmedId,
          visitCount: 1,
          lastVisitedAt: timestamp,
        );
    _snapshot = ServiceHubUsageSnapshot(
      pinnedIds: _snapshot.pinnedIds,
      usageById: Map.unmodifiable(usage),
    );
    await _persistUsage();
    notifyListeners();
  }

  Future<void> togglePinned(String id) async {
    await restore();
    final trimmedId = id.trim();
    if (trimmedId.isEmpty) return;

    final pinnedIds = List<String>.from(_snapshot.pinnedIds);
    if (pinnedIds.contains(trimmedId)) {
      pinnedIds.remove(trimmedId);
    } else {
      pinnedIds.add(trimmedId);
      if (pinnedIds.length > maxPinnedEntries) {
        pinnedIds.removeAt(0);
      }
    }
    _snapshot = ServiceHubUsageSnapshot(
      pinnedIds: List.unmodifiable(pinnedIds),
      usageById: _snapshot.usageById,
    );
    await _persistPinnedIds();
    notifyListeners();
  }

  List<String> _restorePinnedIds(SharedPreferences? prefs) {
    return List.unmodifiable(prefs?.getStringList(_pinnedKey) ?? const []);
  }

  Map<String, ServiceHubUsageEntry> _restoreUsage(SharedPreferences? prefs) {
    final raw = prefs?.getString(_usageKey);
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List<dynamic>) return const {};
      final entries = <String, ServiceHubUsageEntry>{};
      for (final item in decoded) {
        final entry = ServiceHubUsageEntry.fromJson(item);
        if (entry != null) {
          entries[entry.id] = entry;
        }
      }
      return Map.unmodifiable(entries);
    } catch (_) {
      return const {};
    }
  }

  Future<void> _persistPinnedIds() async {
    await _prefs?.setStringList(_pinnedKey, _snapshot.pinnedIds);
  }

  Future<void> _persistUsage() async {
    final encoded = jsonEncode(
      _snapshot.usageById.values.map((entry) => entry.toJson()).toList(),
    );
    await _prefs?.setString(_usageKey, encoded);
  }

  @visibleForTesting
  void debugSetSnapshot(ServiceHubUsageSnapshot snapshot) {
    _snapshot = snapshot;
    _restored = true;
    notifyListeners();
  }

  @visibleForTesting
  void debugReset() {
    _prefs = null;
    _restored = false;
    _snapshot = const ServiceHubUsageSnapshot();
  }
}
