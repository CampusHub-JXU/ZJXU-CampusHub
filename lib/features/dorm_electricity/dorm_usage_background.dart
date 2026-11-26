import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../../core/auth/auth_file_lock.dart';
import '../../core/auth/auth_session_persistence.dart';
import '../../core/auth/background_session_gate.dart';
import '../../core/auth/credential_store.dart';
import '../../core/auth/unified_auth.dart';
import '../../core/epay100/epay100_gateway.dart';
import '../../core/logging/app_logger.dart';
import '../../core/notification/background_task_service.dart';
import '../../core/storage/atomic_json_file.dart';
import 'dorm_electricity_service.dart';

const dormUsageCollect = 'dormUsageCollectV3_15m';

/// Experimental: requires a deliberate test build and user opt-in. Never
/// automatically recover credentials or bypass the school's authentication.
class DormUsageBackground {
  DormUsageBackground._();
  static final instance = DormUsageBackground._();
  static const experimental = bool.fromEnvironment('DORM_USAGE_BACKGROUND');
  @visibleForTesting
  bool? debugAvailableOverride;
  @visibleForTesting
  DateTime Function()? debugNow;
  @visibleForTesting
  Future<Directory> Function()? debugDirectoryProvider;
  @visibleForTesting
  Future<BackgroundLoginClaim?> Function()? debugTryClaim;
  @visibleForTesting
  Future<bool> Function(BackgroundLoginClaim claim)? debugShouldYield;
  @visibleForTesting
  Future<void> Function(BackgroundLoginClaim claim)? debugRelease;
  @visibleForTesting
  Future<String> Function(Map<String, String> arguments)? debugFetchBalance;
  @visibleForTesting
  Future<void> Function()? debugCancelTask;
  @visibleForTesting
  Future<void> Function()? debugRegisterTask;

  bool get available =>
      debugAvailableOverride ?? (experimental && !kIsWeb && Platform.isAndroid);
  static const interval = Duration(minutes: 15);
  static const minAttemptInterval = Duration(minutes: 10);
  late final _io = AtomicJsonFile(
    'dorm_usage_background_v3.json',
    directory: () => debugDirectoryProvider?.call(),
  );
  bool _authListenerRegistered = false;
  String? _observedAuthOwner;
  DateTime _now() => (debugNow ?? DateTime.now)();

  void _watchAuthIdentity() {
    if (_authListenerRegistered) return;
    final auth = UnifiedAuthService.instance;
    _observedAuthOwner = auth.verifiedAccount;
    auth.addListener(_onAuthIdentityChanged);
    _authListenerRegistered = true;
  }

  void _onAuthIdentityChanged() {
    final owner = UnifiedAuthService.instance.verifiedAccount;
    if (owner == _observedAuthOwner) return;
    _observedAuthOwner = owner;
    unawaited(_reconcileAuthChange());
  }

  Future<void> _reconcileAuthChange() async {
    try {
      await _cancelIfInactive(requireVerifiedAccount: true);
    } catch (error, stackTrace) {
      AppLogger.instance.storage(
        LogLevel.warn,
        '后台采集身份变更清理失败',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _registerPeriodicTask() async {
    final override = debugRegisterTask;
    if (override != null) return override();
    await BackgroundTaskService.instance.registerPeriodicTask(
      uniqueName: dormUsageCollect,
      frequency: interval,
      initialDelay: interval,
      constraints: Constraints(networkType: NetworkType.connected),
    );
  }

  Future<void> _cancelScheduledTask() async {
    final override = debugCancelTask;
    if (override != null) return override();
    await BackgroundTaskService.instance.cancelTask(dormUsageCollect);
  }

  /// Remove stale periodic work after logout, room/epoch changes, or an upgrade
  /// to a build where the experimental worker is disabled. Recheck the stored
  /// intent before cancelling so a concurrent re-enable is restored.
  Future<void> _cancelIfInactive({bool requireVerifiedAccount = false}) async {
    if (!available) {
      await _locked((file, _) async {
        await AtomicJsonFile.write(file, <String, dynamic>{});
      });
      await _cancelScheduledTask();
      return;
    }
    final current = await _scope();
    final currentKey =
        current == null ||
            (requireVerifiedAccount &&
                UnifiedAuthService.instance.verifiedAccount != current.owner)
        ? null
        : _key(current);
    final snapshot = await _locked(
      (_, data) async => <Object?>[
        data['scope'],
        data['enabled'],
        data['token'],
      ],
    );
    bool activeForCurrent(List<Object?> values) =>
        currentKey != null &&
        values[0] == currentKey &&
        values[1] == true &&
        values[2] is int;
    if (activeForCurrent(snapshot)) return;
    final preserveCurrentDisabledState =
        currentKey != null && snapshot[0] == currentKey && snapshot[1] != true;

    final removed = await _locked((file, data) async {
      if (data['scope'] != snapshot[0] ||
          data['enabled'] != snapshot[1] ||
          data['token'] != snapshot[2]) {
        return false;
      }
      if (!preserveCurrentDisabledState) {
        await AtomicJsonFile.write(file, <String, dynamic>{});
      }
      return true;
    });
    if (!removed) return;
    await _cancelScheduledTask();

    // If enable raced with cancelByUniqueName, restore its periodic request.
    final afterCancel = await _scope();
    if (afterCancel == null) return;
    final stillEnabled = await _locked(
      (_, data) async =>
          data['scope'] == _key(afterCancel) &&
          data['enabled'] == true &&
          data['token'] is int,
    );
    if (stillEnabled) await _registerPeriodicTask();
  }

  @visibleForTesting
  void debugReset() {
    if (_authListenerRegistered) {
      UnifiedAuthService.instance.removeListener(_onAuthIdentityChanged);
    }
    _authListenerRegistered = false;
    _observedAuthOwner = null;
    debugAvailableOverride = null;
    debugNow = null;
    debugDirectoryProvider = null;
    debugTryClaim = null;
    debugShouldYield = null;
    debugRelease = null;
    debugFetchBalance = null;
    debugCancelTask = null;
    debugRegisterTask = null;
  }

  Future<T> _locked<T>(
    Future<T> Function(File, Map<String, dynamic>) action,
  ) async {
    final file = await _io.file();
    final lock = AuthFileLock(
      lockFile: await _io.siblingFile('dorm_usage_background_v3.lock'),
      acquireTimeout: const Duration(seconds: 3),
    );
    return lock.withLock(() async {
      final data = await _io.read<Map<String, dynamic>>(
        file,
        absent: <String, dynamic>{},
        decode: (raw) =>
            raw is Map<String, dynamic> ? raw : <String, dynamic>{},
        onCorrupt: (_, _) => <String, dynamic>{},
      );
      return action(file, data);
    });
  }

  // Include durable auth epoch and all four room identifiers. Never persist
  // passwords, cookies, tokens or raw responses in this file.
  Future<
    ({
      String owner,
      int epoch,
      String area,
      String building,
      String floor,
      String room,
    })?
  >
  _scope() async {
    final auth = await AuthSessionPersistence.instance.read(
      CredentialSessionDomain.unified,
    );
    final owner = auth.account;
    if (!auth.active || owner == null || owner.trim().isEmpty) return null;
    final p = await SharedPreferences.getInstance();
    await p.reload();
    if (p.getString(DormElectricityService.roomOwnerKey) != owner) return null;
    final area = p.getString(DormElectricityService.keyAreaId);
    final building = p.getString(DormElectricityService.keyBuildingId);
    final floor = p.getString(DormElectricityService.keyFloorId);
    final room = p.getString(DormElectricityService.keyRoomId);
    if ([area, building, floor, room].any((s) => s == null || s.isEmpty)) {
      return null;
    }
    return (
      owner: owner,
      epoch: auth.epoch,
      area: area!,
      building: building!,
      floor: floor!,
      room: room!,
    );
  }

  String _key(
    ({
      String owner,
      int epoch,
      String area,
      String building,
      String floor,
      String room,
    })
    s,
  ) => jsonEncode([s.owner, s.epoch, s.area, s.building, s.floor, s.room]);

  // Called on explicit room replacement while foreground owns the config.
  // Disable old scope even if the user later switches back to the same room.
  Future<void> resetRoom() async {
    if (!available) return;
    try {
      await _locked((file, d) async {
        await AtomicJsonFile.write(file, <String, dynamic>{});
      });
      await _cancelScheduledTask();
    } catch (_) {
      AppLogger.instance.storage(LogLevel.warn, '后台采集配置清理失败');
    }
  }

  Future<bool> enabled() async {
    if (!available) return false;
    try {
      final s = await _scope();
      if (s == null || UnifiedAuthService.instance.verifiedAccount != s.owner) {
        return false;
      }
      return await _locked(
        (_, d) async => d['scope'] == _key(s) && d['enabled'] == true,
      );
    } catch (_) {
      return false;
    }
  }

  /// Shared ten-minute request spacing for foreground auto sampling and the
  /// periodic worker. Manual refreshes keep their existing behavior.
  Future<bool> tryAcquireAutoSamplingSlot() async {
    final s = await _scope();
    if (s == null || UnifiedAuthService.instance.verifiedAccount != s.owner) {
      return false;
    }
    final key = _key(s);
    final now = _now().millisecondsSinceEpoch;
    final result = await _locked((file, data) async {
      if (data['scope'] != key) {
        final cancelStaleTask = data['scope'] is String;
        await AtomicJsonFile.write(file, <String, dynamic>{
          'scope': key,
          'enabled': false,
          'token': now,
          'samples': <Object?>[],
          'attemptAt': now,
        });
        return (true, cancelStaleTask);
      }
      if (!available && data['enabled'] == true) {
        await AtomicJsonFile.write(file, <String, dynamic>{
          'scope': key,
          'enabled': false,
          'token': now,
          'samples': <Object?>[],
          'attemptAt': now,
        });
        return (true, true);
      }
      final last = data['attemptAt'];
      if (last is int && now - last < minAttemptInterval.inMilliseconds) {
        return (false, false);
      }
      data['attemptAt'] = now;
      await AtomicJsonFile.write(file, data);
      return (true, false);
    });
    if (result.$2) {
      await _cancelScheduledTask();
      if (available && await enabled()) await _registerPeriodicTask();
    }
    return result.$1;
  }

  Future<bool> setEnabled(bool enable) async {
    if (!available) return false;
    _watchAuthIdentity();
    final s = await _scope();
    if (s == null || UnifiedAuthService.instance.verifiedAccount != s.owner) {
      return false;
    }
    final key = _key(s);
    final token = _now().microsecondsSinceEpoch;
    await _locked((file, d) async {
      final same = d['scope'] == key;
      final next = <String, dynamic>{
        'scope': key,
        'enabled': enable,
        'token': token,
        'samples': same ? d['samples'] ?? [] : [],
        'attemptAt': same ? d['attemptAt'] : null,
      };
      await AtomicJsonFile.write(file, next);
    });
    try {
      if (enable) {
        await _registerPeriodicTask();
      } else {
        await _cancelScheduledTask();
      }
      return await enabled();
    } catch (_) {
      await _locked((file, d) async {
        if (d['scope'] == key && d['token'] == token) {
          d['enabled'] = false;
          await AtomicJsonFile.write(file, d);
        }
      });
      rethrow;
    }
  }

  /// Read-only mailbox for foreground history; repeated imports are deduped
  /// by the existing chronological history algorithm. No shared prefs writes.
  Future<List<({double kwh, DateTime at})>> samplesFor({
    required String owner,
    required String area,
    required String building,
    required String floor,
    required String room,
  }) async {
    if (!available) return const [];
    final s = await _scope();
    if (s == null ||
        s.owner != owner ||
        s.area != area ||
        s.building != building ||
        s.floor != floor ||
        s.room != room) {
      return const [];
    }
    return _locked((_, d) async {
      if (d['scope'] != _key(s)) return const <({double kwh, DateTime at})>[];
      final rows = d['samples'];
      if (rows is! List || rows.length > 3200) {
        return const <({double kwh, DateTime at})>[];
      }
      final result = <({double kwh, DateTime at})>[];
      for (final row in rows) {
        if (row is! List ||
            row.length != 2 ||
            row[0] is! int ||
            row[1] is! num) {
          continue;
        }
        final value = (row[1] as num).toDouble();
        final ms = row[0] as int;
        if (!value.isFinite ||
            value < 0 ||
            ms < 0 ||
            ms > _now().millisecondsSinceEpoch) {
          continue;
        }
        result.add((kwh: value, at: DateTime.fromMillisecondsSinceEpoch(ms)));
      }
      result.sort((a, b) => a.at.compareTo(b.at));
      return result;
    });
  }

  @visibleForTesting
  static double? parseBalance(String body, String room) {
    try {
      final root = jsonDecode(body);
      if (root is! Map || root['code'].toString() != '200') return null;
      final data = root['data'];
      if (data is! Map || data['balance_list'] is! List) return null;
      for (final item in data['balance_list'] as List) {
        if (item is! Map || item['id'].toString() != room) continue;
        final v = double.tryParse(item['balance'].toString());
        return v != null && v.isFinite && v >= 0 ? v : null;
      }
    } catch (_) {}
    return null;
  }

  Future<bool> run() async {
    BackgroundLoginClaim? claim;
    HeadlessEpay100Gateway? gateway;
    try {
      if (!available) {
        await _cancelIfInactive();
        return true;
      }
      final s = await _scope();
      if (s == null) {
        await _cancelIfInactive();
        return true;
      }
      final key = _key(s);
      final token = await _locked(
        (_, d) async =>
            d['scope'] == key && d['enabled'] == true ? d['token'] : null,
      );
      if (token is! int) {
        await _cancelIfInactive();
        return true;
      }
      final tryClaim = debugTryClaim ?? BackgroundSessionGate.instance.tryClaim;
      claim = await tryClaim();
      if (claim == null) return true;
      final activeClaim = claim;
      final stopAt = _now().add(const Duration(seconds: 75));
      final shouldYield =
          debugShouldYield ?? BackgroundSessionGate.instance.shouldYield;
      Future<bool> allowed() async {
        if (!_now().isBefore(stopAt) || await shouldYield(activeClaim)) {
          return false;
        }
        if (await _scope() != s) return false;
        return _locked(
          (_, d) async =>
              d['scope'] == key && d['enabled'] == true && d['token'] == token,
        );
      }

      if (!await allowed()) return true;
      final attempt = await _locked((file, d) async {
        if (d['scope'] != key || d['enabled'] != true || d['token'] != token) {
          return false;
        }
        final now = _now().millisecondsSinceEpoch;
        final last = d['attemptAt'];
        if (last is int && now - last < minAttemptInterval.inMilliseconds) {
          return false;
        }
        d['attemptAt'] = now;
        await AtomicJsonFile.write(file, d);
        return true;
      });
      if (!attempt || !await allowed()) return true;
      final auth = UnifiedAuthService.instance;
      await auth.restoreSession(
        syncWebViewCookies: false,
        clearIfInactive: true,
      );
      if (auth.verifiedAccount != s.owner || !await allowed()) return true;
      // Only this secondary isolate's gateway. Guard checkpoints are
      // cooperative, not a guarantee that an already issued network request cancels.
      final arguments = <String, String>{
        'adapter_id': DormElectricityService.defaultAdapterId,
        'L1_area_id': s.area,
        'L2_building_id': s.building,
        'L3_floor_id': s.floor,
        'L4_room_id': s.room,
      };
      final testFetch = debugFetchBalance;
      late final String body;
      if (testFetch != null) {
        body = await testFetch(arguments);
      } else {
        gateway = Epay100Gateway.instance as HeadlessEpay100Gateway;
        gateway.backgroundUsageGuard = allowed;
        body = await gateway.call('app.electric.getRoomBalance', arguments);
      }
      final value = parseBalance(body, s.room);
      if (value == null || !await allowed()) return true;
      final at = _now().millisecondsSinceEpoch;
      await AuthSessionPersistence.instance.withCurrentSession<bool>(
        CredentialSessionDomain.unified,
        account: s.owner,
        expectedEpoch: s.epoch,
        action: () async {
          // Local commit only; no auth or network calls under auth lock.
          return _locked((file, d) async {
            if (d['scope'] != key ||
                d['enabled'] != true ||
                d['token'] != token) {
              return false;
            }
            final p = await SharedPreferences.getInstance();
            await p.reload();
            if (p.getString(DormElectricityService.roomOwnerKey) != s.owner ||
                p.getString(DormElectricityService.keyAreaId) != s.area ||
                p.getString(DormElectricityService.keyBuildingId) !=
                    s.building ||
                p.getString(DormElectricityService.keyFloorId) != s.floor ||
                p.getString(DormElectricityService.keyRoomId) != s.room) {
              return false;
            }
            final rows =
                (d['samples'] is List ? d['samples'] as List : const [])
                    .where(
                      (r) =>
                          r is List &&
                          r.length == 2 &&
                          r[0] is int &&
                          (r[0] as int) >=
                              at - const Duration(days: 31).inMilliseconds &&
                          (r[0] as int) < at,
                    )
                    .toList();
            rows.add([at, value]);
            if (rows.length > 3100) rows.removeRange(0, rows.length - 3100);
            d['samples'] = rows;
            await AtomicJsonFile.write(file, d);
            return true;
          });
        },
      );
      return true;
    } catch (_) {
      // No raw server response or account detail in logs; no immediate retry.
      AppLogger.instance.network(LogLevel.warn, '寝室后台采样本轮跳过');
      return true;
    } finally {
      try {
        if (gateway != null) {
          try {
            await gateway.invalidate();
          } catch (error, stackTrace) {
            AppLogger.instance.network(
              LogLevel.warn,
              '后台用电采集 WebView 清理失败',
              error: error,
              stackTrace: stackTrace,
            );
          } finally {
            gateway.backgroundUsageGuard = null;
          }
        }
      } finally {
        if (claim != null) {
          final release =
              debugRelease ?? BackgroundSessionGate.instance.release;
          await release(claim);
        }
      }
    }
  }
}
