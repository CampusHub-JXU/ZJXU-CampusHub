import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../logging/app_logger.dart';
import 'auth_file_lock.dart';

/// 后台登录申领凭证。
class BackgroundLoginClaim {
  const BackgroundLoginClaim({required this.token, required this.until});

  final String token;
  final DateTime until;
}

/// 后台会话变更类型（前台回到前台时据此对账内存）。
enum BackgroundSessionChangeKind {
  /// 后台自动登录已真实提交：磁盘 CookieJar 已更新，前台需重载。
  committed,

  /// 后台探测到服务端会话过期并持久登出，且未能重新登录：前台内存身份需对账。
  revoked,
}

class BackgroundSessionChange {
  const BackgroundSessionChange(this.kind, this.at);

  final BackgroundSessionChangeKind kind;
  final DateTime at;
}

/// 前台 / 后台 isolate 之间的会话交接门。
///
/// 后台 WorkManager isolate 与前台主 isolate 各有一份 `PersistCookieJar` 内存
/// 镜像、共用同一批磁盘文件；两者同时登录 / 写 Cookie 会互相覆盖。这里**不**
/// 用「过期即接管」的租约假装互斥，而是靠一条更弱但可证的规则：
///
/// * 前台在前台期间持续写心跳（[foregroundHeartbeatInterval]）；后台申领登录
///   前先看心跳，新鲜（[foregroundFreshFor] 内）则**不申领**——前台在用，会话
///   交给前台自己处理；
/// * 后台持有申领期间（[claimTtl]，超时视为后台已死）周期性复查前台心跳，前台
///   出现即 [shouldYield] 让位并取消登录；
/// * 前台进入时先发心跳再短暂等待后台申领释放（[enterForeground]），随后按后台
///   留下的变更记录重载 CookieJar / 对账身份。
///
/// **边界（不得夸大）**：这不是跨 isolate 原子事务。心跳与申领之间、以及后台
/// 提交 Cookie 的最后一小段（合并落盘）仍存在极小的竞争窗口；该窗口被大幅收窄，
/// 但没有被消除。状态读改写只在 [AuthFileLock] 内做毫秒级本地 IO，网络与 OCR
/// 永不持锁。
class BackgroundSessionGate {
  BackgroundSessionGate._({Future<Directory> Function()? directoryProvider})
    : debugDirectoryProvider = directoryProvider;

  static final BackgroundSessionGate instance = BackgroundSessionGate._();

  @visibleForTesting
  static BackgroundSessionGate debugNew({
    required Future<Directory> Function() directoryProvider,
    DateTime Function()? now,
  }) =>
      BackgroundSessionGate._(directoryProvider: directoryProvider)
        ..debugNow = now;

  static const int schemaVersion = 1;
  static const String stateFileName = 'background_session_gate.json';
  static const String lockFileName = 'background_session_gate.lock';

  static const Duration foregroundHeartbeatInterval = Duration(seconds: 30);

  /// 心跳超过该时长未更新，视为前台已退出（含进程被杀）。
  static const Duration foregroundFreshFor = Duration(seconds: 90);

  /// 后台申领的最长有效期；超过视为后台 isolate 已死。
  static const Duration claimTtl = Duration(minutes: 2);

  /// 「登录已过期」本地提醒的最小间隔，避免每 2 小时打扰一次。
  static const Duration promptMinInterval = Duration(hours: 12);

  @visibleForTesting
  Future<Directory> Function()? debugDirectoryProvider;

  @visibleForTesting
  DateTime Function()? debugNow;

  DateTime _now() => (debugNow ?? DateTime.now)();

  Timer? _heartbeat;
  DateTime? _lastSeenChangeAt;

  Future<Directory> _resolveDir() async {
    final override = debugDirectoryProvider;
    if (override != null) return override();
    return getApplicationSupportDirectory();
  }

  Future<AuthFileLock> _lock() async {
    final dir = await _resolveDir();
    return AuthFileLock(
      lockFile: File('${dir.path}${Platform.pathSeparator}$lockFileName'),
      acquireTimeout: const Duration(seconds: 5),
    );
  }

  Future<File> _stateFile() async {
    final dir = await _resolveDir();
    return File('${dir.path}${Platform.pathSeparator}$stateFileName');
  }

  /// 锁内读改写。读坏文件按空状态处理（fail closed：没有前台心跳、没有申领）。
  Future<T> _update<T>(
    T Function(Map<String, dynamic> state) mutate, {
    bool write = true,
  }) async {
    final lock = await _lock();
    return lock.withLock(() async {
      final file = await _stateFile();
      var state = <String, dynamic>{};
      try {
        if (await file.exists()) {
          final raw = jsonDecode(await file.readAsString());
          if (raw is Map<String, dynamic> && raw['v'] == schemaVersion) {
            state = raw;
          }
        }
      } catch (_) {
        state = <String, dynamic>{};
      }
      final result = mutate(state);
      if (write) {
        state['v'] = schemaVersion;
        final tmp = File('${file.path}.tmp');
        await tmp.writeAsString(jsonEncode(state), flush: true);
        await tmp.rename(file.path);
      }
      return result;
    });
  }

  DateTime? _time(Object? raw) => raw is String ? DateTime.tryParse(raw) : null;

  bool _foregroundFresh(Map<String, dynamic> state, DateTime now) {
    final at = _time(state['fgAt']);
    return at != null && now.difference(at) < foregroundFreshFor;
  }

  BackgroundLoginClaim? _claimOf(Map<String, dynamic> state, DateTime now) {
    final raw = state['claim'];
    if (raw is! Map) return null;
    final token = raw['token'];
    final until = _time(raw['until']);
    if (token is! String || until == null || !now.isBefore(until)) return null;
    return BackgroundLoginClaim(token: token, until: until);
  }

  // ── 前台侧 ────────────────────────────────────────────────────────

  /// 前台进入 / 回到前台：先发心跳（让后台让位），再有限等待后台申领释放，
  /// 最后返回后台在前台缺席期间留下的会话变更（若有）。
  ///
  /// [coldStart] 为 true 时只建立基线（冷启动 CookieJar 本来就从磁盘读取），
  /// 不返回历史变更。任何 IO 失败都吞掉并返回 null：门是尽力而为的协调，
  /// 不得阻断前台启动。
  Future<BackgroundSessionChange?> enterForeground({
    bool coldStart = false,
    Duration waitForClaim = const Duration(seconds: 5),
  }) async {
    startHeartbeat();
    try {
      await _update((state) {
        state['fgAt'] = _now().toIso8601String();
        // 用户已回到应用：上一次「登录已过期」提醒已完成使命。
        state.remove('promptedAt');
      });
      final deadline = _now().add(waitForClaim);
      while (true) {
        final claimed = await _update(
          (state) => _claimOf(state, _now()) != null,
          write: false,
        );
        if (!claimed || !_now().isBefore(deadline)) break;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      return await _update((state) {
        final at = _time(state['changeAt']);
        final kind = state['changeKind'];
        final seen = _lastSeenChangeAt;
        if (at != null) _lastSeenChangeAt = at;
        if (coldStart || at == null) return null;
        if (seen != null && !at.isAfter(seen)) return null;
        final parsed = BackgroundSessionChangeKind.values
            .where((value) => value.name == kind)
            .firstOrNull;
        return parsed == null ? null : BackgroundSessionChange(parsed, at);
      }, write: false);
    } catch (error, stackTrace) {
      AppLogger.instance.auth(
        LogLevel.warn,
        '后台会话交接门（进入前台）失败，已忽略',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  /// 前台离开（paused / hidden）：停心跳并清除前台标记，后台可申领登录。
  Future<void> leaveForeground() async {
    stopHeartbeat();
    try {
      await _update((state) => state.remove('fgAt'));
    } catch (error, stackTrace) {
      AppLogger.instance.auth(
        LogLevel.warn,
        '后台会话交接门（离开前台）失败，已忽略',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  void startHeartbeat() {
    if (_heartbeat != null) return;
    _heartbeat = Timer.periodic(foregroundHeartbeatInterval, (_) {
      unawaited(
        _update((state) => state['fgAt'] = _now().toIso8601String())
            .catchError((_) => ''),
      );
    });
  }

  void stopHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = null;
  }

  // ── 后台侧 ────────────────────────────────────────────────────────

  /// 前台心跳是否新鲜（读盘失败按「新鲜」处理：fail closed，不去抢）。
  Future<bool> isForegroundActive() async {
    try {
      return await _update(
        (state) => _foregroundFresh(state, _now()),
        write: false,
      );
    } catch (_) {
      return true;
    }
  }

  /// 申领后台登录。前台心跳新鲜、或已有未过期申领时返回 null。读写失败同样
  /// 返回 null（fail closed）。
  Future<BackgroundLoginClaim?> tryClaim() async {
    try {
      return await _update((state) {
        final now = _now();
        if (_foregroundFresh(state, now)) return null;
        if (_claimOf(state, now) != null) return null;
        final claim = BackgroundLoginClaim(
          token: 'bg-$pid-${now.microsecondsSinceEpoch}',
          until: now.add(claimTtl),
        );
        state['claim'] = {
          'token': claim.token,
          'until': claim.until.toIso8601String(),
        };
        return claim;
      });
    } catch (error, stackTrace) {
      AppLogger.instance.auth(
        LogLevel.warn,
        '后台登录申领失败，按未申领处理',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  /// 后台是否应让位：前台已回来，或申领已丢失 / 过期。读失败按让位处理。
  Future<bool> shouldYield(BackgroundLoginClaim claim) async {
    try {
      return await _update((state) {
        final now = _now();
        if (_foregroundFresh(state, now)) return true;
        final current = _claimOf(state, now);
        return current == null || current.token != claim.token;
      }, write: false);
    } catch (_) {
      return true;
    }
  }

  /// 释放申领；[change] 非空时同时留下会话变更记录，供前台回来时对账。
  Future<void> release(
    BackgroundLoginClaim claim, {
    BackgroundSessionChangeKind? change,
  }) async {
    try {
      await _update((state) {
        final current = state['claim'];
        if (current is Map && current['token'] == claim.token) {
          state.remove('claim');
        }
        if (change != null) {
          state['changeKind'] = change.name;
          state['changeAt'] = _now().toIso8601String();
          if (change == BackgroundSessionChangeKind.committed) {
            state.remove('promptedAt');
          }
        }
      });
    } catch (error, stackTrace) {
      AppLogger.instance.auth(
        LogLevel.warn,
        '后台登录申领释放失败（将随 TTL 过期）',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// 是否应发「登录已过期」本地提醒：距上次提醒不足 [promptMinInterval] 则不发。
  /// 返回 true 时已同时记录本次提醒时间。
  Future<bool> claimExpiredPrompt() async {
    try {
      return await _update((state) {
        final now = _now();
        final last = _time(state['promptedAt']);
        if (last != null && now.difference(last) < promptMinInterval) {
          return false;
        }
        state['promptedAt'] = now.toIso8601String();
        return true;
      });
    } catch (_) {
      return false;
    }
  }

  /// 提醒发送失败时回滚，让下次检查仍可重试。
  Future<void> rollbackExpiredPrompt() async {
    try {
      await _update((state) => state.remove('promptedAt'));
    } catch (_) {}
  }

  @visibleForTesting
  void debugReset() {
    stopHeartbeat();
    _lastSeenChangeAt = null;
    debugDirectoryProvider = null;
    debugNow = null;
  }
}
