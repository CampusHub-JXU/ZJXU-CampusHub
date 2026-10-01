import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../logging/app_logger.dart';
import '../storage/atomic_json_file.dart';
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
  const BackgroundSessionChange(this.kind, this.at, {this.account, this.epoch});

  final BackgroundSessionChangeKind kind;
  final DateTime at;

  /// [BackgroundSessionChangeKind.revoked] 发生时被撤销的账号与持久会话 epoch。
  /// 前台据此判断记录是否已被之后的登录取代（见 [revokedStillApplies]）。
  final String? account;
  final int? epoch;

  /// `revoked` 记录是否仍适用于前台**当前**身份：账号与持久 epoch 都必须与记录
  /// 一致。缺字段（旧记录）按不适用处理——少登出一次，前台下次探测会发现过期；
  /// 多登出一次则会把用户刚重新登录的新会话踢掉。
  bool revokedStillApplies({
    required String? currentAccount,
    required int? currentEpoch,
  }) {
    if (kind != BackgroundSessionChangeKind.revoked) return false;
    final recordedAccount = account;
    final recordedEpoch = epoch;
    if (recordedAccount == null || recordedEpoch == null) return false;
    return currentAccount == recordedAccount && currentEpoch == recordedEpoch;
  }
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

  late final AtomicJsonFile _io = AtomicJsonFile(
    stateFileName,
    directory: () => debugDirectoryProvider?.call(),
  );

  Future<AuthFileLock> _lock() async {
    return AuthFileLock(
      lockFile: await _io.siblingFile(lockFileName),
      acquireTimeout: const Duration(seconds: 5),
    );
  }

  /// 状态文件存在但读不出有效内容（损坏 / schema 不符）时注入的保留键。
  ///
  /// 「文件不存在」是合法的空状态，「文件存在却读不出来」不是：此时无法证明前台
  /// 没有在用，后台一律 fail closed（不申领、不提醒、不写盘覆盖现场）。只有前台
  /// 写心跳的路径会 `remove` 该键自愈。
  static const String _invalidKey = '_invalid';

  bool _isInvalid(Map<String, dynamic> state) => state[_invalidKey] == true;

  /// 锁内读改写。读坏文件注入 [_invalidKey]，由各调用方决定如何 fail closed。
  Future<T> _update<T>(
    T Function(Map<String, dynamic> state) mutate, {
    bool write = true,
  }) async {
    final lock = await _lock();
    return lock.withLock(() async {
      final file = await _io.file();
      // 文件不存在 → 空状态；存在却读不出（损坏 / schema 不符）→ 注入无效标记。
      final state = await _io.read<Map<String, dynamic>>(
        file,
        absent: <String, dynamic>{},
        decode: (raw) =>
            raw is Map<String, dynamic> && raw['v'] == schemaVersion
            ? raw
            : <String, dynamic>{_invalidKey: true},
        onCorrupt: (_, _) => <String, dynamic>{_invalidKey: true},
      );
      final result = mutate(state);
      // 仍无效（mutator 没有自愈）就不落盘：保持文件原样，不把半截状态写成有效。
      if (write && !_isInvalid(state)) {
        state['v'] = schemaVersion;
        await AtomicJsonFile.write(file, state);
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
        // 前台心跳自愈：无效状态文件由这条重新写成有效文件。
        state.remove(_invalidKey);
        state['fgAt'] = _now().toIso8601String();
        // 注意：不在这里清 promptedAt。回到前台不代表身份已恢复，若每次进入前台
        // 都清掉，12 小时限频形同虚设；只有后台恢复成功（release committed）
        // 才清，其余靠时间过期。
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
        if (parsed == null) return null;
        final account = state['changeAccount'];
        final epoch = state['changeEpoch'];
        return BackgroundSessionChange(
          parsed,
          at,
          account: account is String ? account : null,
          epoch: epoch is int ? epoch : null,
        );
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
      await _update((state) {
        state.remove(_invalidKey);
        state.remove('fgAt');
      });
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
        _update((state) {
          state.remove(_invalidKey);
          return state['fgAt'] = _now().toIso8601String();
        }).catchError((_) => ''),
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
        (state) => _isInvalid(state) || _foregroundFresh(state, _now()),
        write: false,
      );
    } catch (_) {
      return true;
    }
  }

  /// 申领后台登录。前台心跳新鲜、已有未过期申领、状态文件无效时返回 null。
  /// 读写失败同样返回 null（fail closed）。
  Future<BackgroundLoginClaim?> tryClaim() async {
    try {
      return await _update((state) {
        final now = _now();
        if (_isInvalid(state)) return null;
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
        if (_isInvalid(state)) return true;
        if (_foregroundFresh(state, now)) return true;
        final current = _claimOf(state, now);
        return current == null || current.token != claim.token;
      }, write: false);
    } catch (_) {
      return true;
    }
  }

  /// 释放申领；[change] 非空时同时留下会话变更记录，供前台回来时对账。
  ///
  /// [changeAccount] / [changeEpoch] 是 `revoked` 记录的适用范围：前台只在自己
  /// 当前账号与持久 epoch 仍与之相同时才据此登出，见
  /// [BackgroundSessionChange.revokedStillApplies]。
  Future<void> release(
    BackgroundLoginClaim claim, {
    BackgroundSessionChangeKind? change,
    String? changeAccount,
    int? changeEpoch,
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
          if (changeAccount != null && changeEpoch != null) {
            state['changeAccount'] = changeAccount;
            state['changeEpoch'] = changeEpoch;
          } else {
            state.remove('changeAccount');
            state.remove('changeEpoch');
          }
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
        if (_isInvalid(state)) return false;
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
