import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../logging/app_logger.dart';
import 'auth_failure.dart';
import 'auth_file_lock.dart';

/// 自动恢复状态所属认证域。CAS 与教务**独立** opt-in、独立撤销、独立 epoch。
enum AuthRecoveryDomain {
  cas('cas'),
  academic('academic');

  const AuthRecoveryDomain(this.wireName);

  final String wireName;
}

/// 退出类型：显式登出与业务过期必须区分。
enum AuthLogoutKind {
  /// 用户显式登出/切换账号：关闭该域自动恢复并持久撤销（[AuthRecoveryRecord.revoked]）。
  explicitUserLogout,

  /// 业务侧 `markLoggedOut`（会话过期、校验失败）：只记录失败与冷却，
  /// **不得**等价成用户手动撤销，不得关闭 opt-in。
  businessExpiry,
}

/// 一次失败的语义类别。**必须由调用方显式指定**，不要从 [AuthFailureKind] 推断。
///
/// 关键不变量：**OCR 认错 ≠ 身份错**。
/// - [transient]：验证码未识别 / 被拒、网络不可达、超时、协议变化、未知——
///   只推进冷却退避（`cooldownUntil`），**不**累计
///   [AuthRecoveryRecord.failureCount]；
/// - [identity]：服务端明确判定账号或密码错误（[AuthFailureKind.invalidCredentials]
///   或等价的服务端拒绝凭据文案）——才累计 [AuthRecoveryRecord.failureCount]，
///   达到 [AuthRecoveryStateStore.identityFailurePauseThreshold] 后暂停自动
///   登录并要求手动登录。
///
/// 之所以不按 [AuthFailureKind] 自动映射：分类器只描述「失败长什么样」，不描述
/// 「这次失败是否可疑到要暂停自动恢复」——同一个 kind（尤其
/// [AuthFailureKind.unknown]）既可能来自 OCR，也可能来自服务端。分类器保持纯粹。
enum AuthFailureScope {
  /// 识别 / 瞬时失败：只退避，不计入身份失败。
  transient,

  /// 身份失败：明确凭据错误，计入身份失败。
  identity,
}

/// 一次自动恢复交换的持久 ticket。
///
/// 在自动事务开始（取得交换锁、校验资格后）签发并落盘；每次网络交换前与
/// commit 前都用 [AuthRecoveryStateStore.verifyTicket] 重新读盘校验，
/// 保证撤销/epoch 变化/凭据变更不会被迟到的事务越过。
class AuthRecoveryTicket {
  const AuthRecoveryTicket({
    required this.id,
    required this.domain,
    required this.account,
    required this.epoch,
    required this.credentialRevision,
    required this.issuedAt,
    required this.expiresAt,
  });

  final String id;
  final AuthRecoveryDomain domain;
  final String account;
  final int epoch;
  final int credentialRevision;
  final DateTime issuedAt;
  final DateTime expiresAt;

  bool isExpiredAt(DateTime now) => !now.isBefore(expiresAt);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'account': account,
    'epoch': epoch,
    'credentialRevision': credentialRevision,
    'issuedAt': issuedAt.toIso8601String(),
    'expiresAt': expiresAt.toIso8601String(),
  };

  static AuthRecoveryTicket? fromJson(AuthRecoveryDomain domain, Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id']?.toString() ?? '';
    final account = raw['account']?.toString() ?? '';
    final epoch = raw['epoch'];
    final credentialRevision = raw['credentialRevision'];
    final issuedAt = DateTime.tryParse(raw['issuedAt']?.toString() ?? '');
    final expiresAt = DateTime.tryParse(raw['expiresAt']?.toString() ?? '');
    if (id.isEmpty ||
        account.isEmpty ||
        epoch is! int ||
        credentialRevision is! int ||
        issuedAt == null ||
        expiresAt == null) {
      return null;
    }
    return AuthRecoveryTicket(
      id: id,
      domain: domain,
      account: account,
      epoch: epoch,
      credentialRevision: credentialRevision,
      issuedAt: issuedAt,
      expiresAt: expiresAt,
    );
  }
}

/// 单域自动恢复的持久状态。**绝不包含密码或任何凭据明文**。
class AuthRecoveryRecord {
  const AuthRecoveryRecord({
    this.optIn = false,
    this.account,
    this.credentialRevision = 0,
    this.epoch = 0,
    this.revoked = false,
    this.cooldownUntil,
    this.lastFailure,
    this.lastFailureAt,
    this.failureCount = 0,
    this.manualHoldUntil,
    this.activeAttempt,
  });

  /// 用户是否显式启用该域自动恢复。默认 false。
  final bool optIn;

  /// opt-in 绑定的账号。
  final String? account;

  /// 凭据修订号；凭据 save/change/clear 时递增并撤销旧许可。
  final int credentialRevision;

  /// 身份 epoch；撤销/切换账号/凭据变更时递增，旧 ticket 立即失效。
  final int epoch;

  /// 是否被显式登出持久撤销（业务过期 markLoggedOut 不置位）。
  final bool revoked;

  final DateTime? cooldownUntil;
  final AuthFailureKind? lastFailure;
  final DateTime? lastFailureAt;

  /// 累计的**身份失败**次数（明确账号/密码错误，见 [AuthFailureScope.identity]）。
  ///
  /// 识别失败（OCR 未识别）、验证码被拒、网络与超时**不**计入此值——它们只推进
  /// [cooldownUntil]。达到 [AuthRecoveryStateStore.identityFailurePauseThreshold]
  /// 时自动登录暂停，须用户手动登录（见 `AuthRecoveryDecision.manualRequired`）。
  final int failureCount;

  /// 人工验证码持有截止时间；null 表示无人工持有。
  ///
  /// 单域只有一个截止时间（**不再有 token / TTL 释放协议**）：用户输入验证码
  /// 期间置位，自动恢复遇到未过期的持有窗口必须跳过，让位于人工。
  /// 不持有文件锁——状态锁只在读改写记录的毫秒级窗口内持有。
  ///
  /// 新不变量（跨 isolate）：人工持有与自动登录都只可能来自**前台单
  /// isolate**（workmanager 不发起 CAS/教务登录），因此无需 token 所有权校验；
  /// 释放是无条件的，后写者覆盖先写者。跨 isolate 的强互斥不再假装由持久
  /// 租约提供，见 `auth_operation_coordinator.dart` 类注释。
  final DateTime? manualHoldUntil;

  final AuthRecoveryTicket? activeAttempt;

  bool cooldownActiveAt(DateTime now) {
    final until = cooldownUntil;
    return until != null && now.isBefore(until);
  }

  bool manualHoldActiveAt(DateTime now) {
    final until = manualHoldUntil;
    return until != null && now.isBefore(until);
  }

  AuthRecoveryRecord copyWith({
    bool? optIn,
    String? account,
    bool clearAccount = false,
    int? credentialRevision,
    int? epoch,
    bool? revoked,
    DateTime? cooldownUntil,
    bool clearCooldown = false,
    AuthFailureKind? lastFailure,
    bool clearLastFailure = false,
    DateTime? lastFailureAt,
    int? failureCount,
    DateTime? manualHoldUntil,
    bool clearManualHold = false,
    AuthRecoveryTicket? activeAttempt,
    bool clearActiveAttempt = false,
  }) {
    return AuthRecoveryRecord(
      optIn: optIn ?? this.optIn,
      account: clearAccount ? null : (account ?? this.account),
      credentialRevision: credentialRevision ?? this.credentialRevision,
      epoch: epoch ?? this.epoch,
      revoked: revoked ?? this.revoked,
      cooldownUntil: clearCooldown
          ? null
          : (cooldownUntil ?? this.cooldownUntil),
      lastFailure: clearLastFailure ? null : (lastFailure ?? this.lastFailure),
      lastFailureAt: clearLastFailure
          ? null
          : (lastFailureAt ?? this.lastFailureAt),
      failureCount: failureCount ?? this.failureCount,
      manualHoldUntil: clearManualHold
          ? null
          : (manualHoldUntil ?? this.manualHoldUntil),
      activeAttempt: clearActiveAttempt
          ? null
          : (activeAttempt ?? this.activeAttempt),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'optIn': optIn,
    'account': account,
    'credentialRevision': credentialRevision,
    'epoch': epoch,
    'revoked': revoked,
    'cooldownUntil': cooldownUntil?.toIso8601String(),
    'lastFailure': lastFailure?.name,
    'lastFailureAt': lastFailureAt?.toIso8601String(),
    'failureCount': failureCount,
    'manualHoldUntil': manualHoldUntil?.toIso8601String(),
    'activeAttempt': activeAttempt?.toJson(),
  };

  /// 解析失败（损坏字段）时抛出，由 store 归为「不信任 → fail closed」。
  static AuthRecoveryRecord fromJson(AuthRecoveryDomain domain, Object? raw) {
    if (raw is! Map) {
      throw const FormatException('auth recovery record invalid');
    }
    final credentialRevision = raw['credentialRevision'];
    final epoch = raw['epoch'];
    final failureCount = raw['failureCount'];
    // 旧 schema 迁移（读一次、不写回）：
    // - 旧记录里 `failureCount` 把瞬时/识别失败也算进去，语义拆分后若沿用会
    //   直接把老用户误判成「身份失败已暂停」，因此旧记录一律从 0 重新累计；
    // - 旧 `manualLease.expiresAt` 派生为 `manualHoldUntil`，旧 `exchangeLease`
    //   直接忽略，不写回（[toJson] 不再输出这两键）。
    final legacySchema =
        raw.containsKey('exchangeLease') || raw.containsKey('manualLease');
    return AuthRecoveryRecord(
      optIn: raw['optIn'] == true,
      account: raw['account']?.toString(),
      credentialRevision: credentialRevision is int ? credentialRevision : 0,
      epoch: epoch is int ? epoch : 0,
      revoked: raw['revoked'] == true,
      cooldownUntil: DateTime.tryParse(raw['cooldownUntil']?.toString() ?? ''),
      lastFailure: _parseFailureKind(raw['lastFailure']),
      lastFailureAt: DateTime.tryParse(raw['lastFailureAt']?.toString() ?? ''),
      failureCount: !legacySchema && failureCount is int ? failureCount : 0,
      manualHoldUntil: _parseManualHoldUntil(raw),
      activeAttempt: AuthRecoveryTicket.fromJson(domain, raw['activeAttempt']),
    );
  }

  /// 人工持有窗口解析 + 旧 schema 迁移。
  ///
  /// 新字段是 `manualHoldUntil`；旧 JSON 里是 `manualLease: {expiresAt}`。
  /// 旧字段**只读一次**用于派生新值，之后 [toJson] 只写 `manualHoldUntil`，
  /// 旧键不再写回。
  static DateTime? _parseManualHoldUntil(Map<dynamic, dynamic> raw) {
    final direct = DateTime.tryParse(raw['manualHoldUntil']?.toString() ?? '');
    if (direct != null) return direct;
    final legacy = raw['manualLease'];
    if (legacy is Map) {
      return DateTime.tryParse(legacy['expiresAt']?.toString() ?? '');
    }
    return null;
  }

  static AuthFailureKind? _parseFailureKind(Object? raw) {
    final name = raw?.toString();
    if (name == null || name.isEmpty) return null;
    for (final kind in AuthFailureKind.values) {
      if (kind.name == name) return kind;
    }
    return null;
  }
}

/// 两域状态的完整快照。
class AuthRecoverySnapshot {
  const AuthRecoverySnapshot({required this.records});

  static const AuthRecoverySnapshot empty = AuthRecoverySnapshot(
    records: <AuthRecoveryDomain, AuthRecoveryRecord>{},
  );

  final Map<AuthRecoveryDomain, AuthRecoveryRecord> records;

  AuthRecoveryRecord recordFor(AuthRecoveryDomain domain) =>
      records[domain] ?? const AuthRecoveryRecord();

  AuthRecoverySnapshot withRecord(
    AuthRecoveryDomain domain,
    AuthRecoveryRecord record,
  ) {
    return AuthRecoverySnapshot(
      records: <AuthRecoveryDomain, AuthRecoveryRecord>{
        ...records,
        domain: record,
      },
    );
  }
}

/// 自动恢复状态的持久存储（阶段 2 使用）。
///
/// 并发模型与 `NoticeSyncStore` 同源：独立 `.lock` 文件 + 锁内重读磁盘 +
/// 临时文件 rename 原子替换。区别：
/// - 读坏文件 **fail closed**：任何解析/版本异常都视为「全部未启用」，
///   既不猜 opt-in，也不复用半截状态；
/// - 明文密码永不进入 JSON，凭据只留在原 `CredentialStore`（加密格式不变）；
/// - 支持 `debugDirectoryProvider` 注入测试临时目录。
///
/// **重要边界（stage 2 约束）**：本锁只保护状态文件的读改写，**不能**自动
/// 解决跨 isolate 的 CookieJar 内存陈旧与文件竞争。自动登录只在**前台单
/// isolate**发起（workmanager 不发起 CAS/教务登录），因此不再用持久交换
/// 租约假装跨 isolate 互斥；同 isolate 非重入由
/// `AuthOperationCoordinator._runningExchanges` 保证，跨 isolate 的状态互斥
/// 由 `AuthFileLock` 的短 RMW 收敛。详见 `auth_operation_coordinator.dart`
/// 的类注释。
class AuthRecoveryStateStore {
  AuthRecoveryStateStore._({Future<Directory> Function()? directoryProvider})
    : debugDirectoryProvider = directoryProvider;

  static final AuthRecoveryStateStore instance = AuthRecoveryStateStore._();

  @visibleForTesting
  static AuthRecoveryStateStore debugNew({
    required Future<Directory> Function() directoryProvider,
  }) => AuthRecoveryStateStore._(directoryProvider: directoryProvider);

  static const int schemaVersion = 1;
  static const String stateFileName = 'auth_recovery_state.json';
  static const String lockFileName = 'auth_recovery_state.lock';

  /// 人工验证码持有窗口默认时长。
  static const Duration defaultManualHoldTtl = Duration(seconds: 90);
  static const Duration defaultTicketTtl = Duration(minutes: 2);

  /// 身份失败累计到该阈值后暂停自动登录，须用户手动登录。
  static const int identityFailurePauseThreshold = 3;

  /// 瞬时失败的推荐退避阶梯（1 / 2 / 5 分钟，之后维持 5 分钟）。
  ///
  /// [consecutiveTransientFailures] 从 1 开始计数。这是**纯策略**，不持久化，
  /// 由前台单 isolate 的调用方维护连续计数（见
  /// `AuthOperationCoordinator.recordTransientFailure`）。
  static Duration transientBackoffFor(int consecutiveTransientFailures) {
    if (consecutiveTransientFailures <= 1) return const Duration(minutes: 1);
    if (consecutiveTransientFailures == 2) return const Duration(minutes: 2);
    return const Duration(minutes: 5);
  }

  @visibleForTesting
  Future<Directory> Function()? debugDirectoryProvider;

  AuthRecoverySnapshot _snapshot = AuthRecoverySnapshot.empty;

  @visibleForTesting
  AuthRecoverySnapshot get debugSnapshot => _snapshot;

  @visibleForTesting
  void debugReset() {
    _snapshot = AuthRecoverySnapshot.empty;
    debugDirectoryProvider = null;
  }

  AuthRecoveryRecord recordFor(AuthRecoveryDomain domain) =>
      _snapshot.recordFor(domain);

  // ── 读路径（锁内读盘，fail closed） ────────────────────────────────

  Future<AuthRecoverySnapshot> reload() {
    return _withLock(() async {
      final loaded = await _readLocked();
      _snapshot = loaded;
      return loaded;
    });
  }

  Future<AuthRecoveryRecord> read(AuthRecoveryDomain domain) async {
    final snapshot = await reload();
    return snapshot.recordFor(domain);
  }

  /// 自动恢复是否可对该账号发起（只读判定，不签 ticket）。
  Future<bool> isAutomaticEligible(
    AuthRecoveryDomain domain, {
    required String account,
    DateTime? now,
  }) async {
    final record = await read(domain);
    return _isEligible(record, account: account, now: now ?? DateTime.now());
  }

  bool _isEligible(
    AuthRecoveryRecord record, {
    required String account,
    required DateTime now,
  }) {
    if (!record.optIn) return false;
    if (record.revoked) return false;
    if (record.account != account) return false;
    if (record.failureCount >= identityFailurePauseThreshold) return false;
    if (record.cooldownActiveAt(now)) return false;
    if (record.manualHoldActiveAt(now)) return false;
    return true;
  }

  // ── opt-in / 撤销 / 失败记录 ───────────────────────────────────────

  /// 显式 opt-in。调用方必须已确认该域存在已保存凭据（见 coordinator）。
  Future<AuthRecoveryRecord> enable(
    AuthRecoveryDomain domain, {
    required String account,
    required int credentialRevision,
  }) {
    return _mutate(domain, (record, now) {
      return record.copyWith(
        optIn: true,
        account: account,
        credentialRevision: credentialRevision,
        revoked: false,
        clearActiveAttempt: true,
      );
    });
  }

  /// 用户关闭 opt-in（非登出）。
  Future<AuthRecoveryRecord> disable(AuthRecoveryDomain domain) {
    return _mutate(domain, (record, now) {
      return record.copyWith(optIn: false, clearActiveAttempt: true);
    });
  }

  /// 记录退出。显式登出与业务过期的语义严格区分。
  Future<AuthRecoveryRecord> recordLogout(
    AuthRecoveryDomain domain, {
    required AuthLogoutKind kind,
  }) {
    return _mutate(domain, (record, now) {
      if (kind == AuthLogoutKind.explicitUserLogout) {
        // 持久撤销：关闭 opt-in、置 revoked、epoch++、清账号与租约/ticket。
        return record.copyWith(
          optIn: false,
          revoked: true,
          epoch: record.epoch + 1,
          clearAccount: true,
          clearManualHold: true,
          clearActiveAttempt: true,
          clearCooldown: true,
          clearLastFailure: true,
          failureCount: 0,
        );
      }
      // 业务过期：只记录失败，不动 opt-in / revoked / epoch。
      // 会话过期/被服务端登出**不是**身份失败（它恰恰是自动恢复要处理的情形），
      // 因此**不**累计 failureCount，避免 3 次过期就误判成「需手动登录」。
      return record.copyWith(
        lastFailure: AuthFailureKind.unknown,
        lastFailureAt: now,
        clearActiveAttempt: true,
      );
    });
  }

  /// 记录一次**瞬时 / 识别失败**（OCR 未识别、验证码被拒、网络不可达、
  /// 超时、协议变化、未知）：只推进 [AuthRecoveryRecord.cooldownUntil] 退避，
  /// **绝不**累计 [AuthRecoveryRecord.failureCount]。
  ///
  /// **OCR 认错 ≠ 身份错**：验证码识别失败无论连续多少次都只退避，不会把用户
  /// 拖进「需手动登录」。`cooldown` 为 null 时沿用现有冷却，不重设。
  Future<AuthRecoveryRecord> recordTransientFailure(
    AuthRecoveryDomain domain, {
    required AuthFailureKind kind,
    required DateTime now,
    Duration? cooldown,
  }) {
    return _mutate(domain, (record, _) {
      return record.copyWith(
        lastFailure: kind,
        lastFailureAt: now,
        cooldownUntil: cooldown == null
            ? record.cooldownUntil
            : now.add(cooldown),
        clearActiveAttempt: true,
      );
    });
  }

  /// 记录一次**身份失败**（服务端明确判定账号/密码错误，即
  /// [AuthFailureKind.invalidCredentials] 或等价的服务端明确拒绝凭据文案）：
  /// 累计 [AuthRecoveryRecord.failureCount]，达到
  /// [identityFailurePauseThreshold] 后自动登录暂停，须用户手动登录。
  ///
  /// **只有调用方明确判定为身份错误时才可调用**；不得从 [AuthFailureKind]
  /// 自动推断（见 [AuthFailureScope]）。验证码/OCR/网络失败请改用
  /// [recordTransientFailure]。
  Future<AuthRecoveryRecord> recordIdentityFailure(
    AuthRecoveryDomain domain, {
    required AuthFailureKind kind,
    required DateTime now,
    Duration? cooldown,
  }) {
    return _mutate(domain, (record, _) {
      return record.copyWith(
        lastFailure: kind,
        lastFailureAt: now,
        failureCount: record.failureCount + 1,
        cooldownUntil: cooldown == null
            ? record.cooldownUntil
            : now.add(cooldown),
        clearActiveAttempt: true,
      );
    });
  }

  /// 自动或**手动**成功：清除失败计数、冷却与 ticket，即重新武装自动恢复。
  ///
  /// 手动登录成功后同样应调用本方法，使 [identityFailurePauseThreshold] 的
  /// 暂停状态解除；人工持有窗口需调用方另行 [endManualHold]。
  Future<AuthRecoveryRecord> recordSuccess(AuthRecoveryDomain domain) {
    return _mutate(domain, (record, now) {
      return record.copyWith(
        clearLastFailure: true,
        failureCount: 0,
        clearCooldown: true,
        clearActiveAttempt: true,
      );
    });
  }

  /// ticket 条件完成：仅当 [ticketId] 仍是当前活跃 attempt 时写入成功/失败
  /// 结果并清除该 ticket。
  ///
  /// 与 [recordSuccess] / [recordTransientFailure] / [recordIdentityFailure]
  /// 的区别：后三者会**无条件**清掉 `activeAttempt`——若本试图已被更新的
  /// ticket 取代，那会误清新 ticket。这里对 ticketId 做条件判断，不匹配即
  /// no-op，也绝不改动 opt-in / epoch / 账号。供
  /// [AuthOperationCoordinator.runAutomatic] 的终态收尾使用。
  ///
  /// 失败时按 [scope] 决定是否累计身份失败：瞬时/未知失败只退避，只有身份
  /// 失败才 `failureCount++`（见 [AuthFailureScope]）。
  Future<AuthRecoveryRecord> completeAttempt(
    AuthRecoveryDomain domain, {
    required String ticketId,
    required bool success,
    required AuthFailureScope scope,
    AuthFailureKind? failureKind,
    DateTime? now,
    Duration? cooldown,
  }) {
    return _mutate(domain, (record, mutationNow) {
      final active = record.activeAttempt;
      if (active == null || active.id != ticketId) return record;
      if (success) {
        return record.copyWith(
          clearLastFailure: true,
          failureCount: 0,
          clearCooldown: true,
          clearActiveAttempt: true,
        );
      }
      final effectiveNow = now ?? mutationNow;
      return record.copyWith(
        lastFailure: failureKind ?? AuthFailureKind.unknown,
        lastFailureAt: effectiveNow,
        failureCount: scope == AuthFailureScope.identity
            ? record.failureCount + 1
            : record.failureCount,
        cooldownUntil: cooldown == null
            ? record.cooldownUntil
            : effectiveNow.add(cooldown),
        clearActiveAttempt: true,
      );
    });
  }

  /// 凭据 save/change/clear：推进 credentialRevision、撤销旧许可、epoch++。
  Future<AuthRecoveryRecord> onCredentialsChanged(AuthRecoveryDomain domain) {
    return _mutate(domain, (record, now) {
      return record.copyWith(
        optIn: false,
        revoked: false,
        credentialRevision: record.credentialRevision + 1,
        epoch: record.epoch + 1,
        clearAccount: true,
        clearManualHold: true,
        clearActiveAttempt: true,
        clearCooldown: true,
        clearLastFailure: true,
        failureCount: 0,
      );
    });
  }

  // ── 人工验证码持有窗口 ────────────────────────────────────────────

  /// 开始/延长人工验证码持有窗口。
  ///
  /// 单域只有一个 [AuthRecoveryRecord.manualHoldUntil] 截止时间，**没有**
  /// token，也没有 TTL 释放协议：已有更晚的截止时间则保留（不缩短），否则
  /// 置为 `now + ttl`。`now` 可注入以便测试。
  Future<AuthRecoveryRecord> beginManualHold(
    AuthRecoveryDomain domain, {
    Duration ttl = defaultManualHoldTtl,
    DateTime? now,
  }) {
    final effectiveNow = now ?? DateTime.now();
    final until = effectiveNow.add(ttl);
    return _mutate(domain, (record, _) {
      final existing = record.manualHoldUntil;
      final merged = (existing != null && existing.isAfter(until))
          ? existing
          : until;
      return record.copyWith(manualHoldUntil: merged, clearActiveAttempt: true);
    });
  }

  /// 结束人工持有窗口：**无条件**清除，无 token 校验（前台单 isolate 下不再
  /// 需要所有权协议）。后写者覆盖先写者。
  Future<AuthRecoveryRecord> endManualHold(AuthRecoveryDomain domain) {
    return _mutate(domain, (record, _) {
      if (record.manualHoldUntil == null) return record;
      return record.copyWith(clearManualHold: true);
    });
  }

  Future<bool> isManualHoldActive(
    AuthRecoveryDomain domain, {
    DateTime? now,
  }) async {
    final record = await read(domain);
    return record.manualHoldActiveAt(now ?? DateTime.now());
  }

  // ── 持久 ticket ──────────────────────────────────────────────────

  /// 资格校验通过才签发 ticket；否则返回 null（不落盘）。
  Future<AuthRecoveryTicket?> beginAttempt(
    AuthRecoveryDomain domain, {
    required String account,
    DateTime? now,
    Duration ttl = defaultTicketTtl,
  }) async {
    final effectiveNow = now ?? DateTime.now();
    return _withLock(() async {
      final snapshot = await _readLocked();
      final record = snapshot.recordFor(domain);
      if (!_isEligible(record, account: account, now: effectiveNow)) {
        _snapshot = snapshot;
        return null;
      }
      final ticket = AuthRecoveryTicket(
        id: _newToken('attempt'),
        domain: domain,
        account: account,
        epoch: record.epoch,
        credentialRevision: record.credentialRevision,
        issuedAt: effectiveNow,
        expiresAt: effectiveNow.add(ttl),
      );
      final next = snapshot.withRecord(
        domain,
        record.copyWith(activeAttempt: ticket),
      );
      await _writeLocked(next);
      _snapshot = next;
      return ticket;
    });
  }

  /// 校验持久 ticket：交换前与 commit 前都应调用。
  ///
  /// 重新读盘，只有 opt-in 仍开、未撤销、账号/epoch/凭据修订一致、ticket
  /// 仍是当前活跃 attempt、未过期，且没有新的人工持有窗口时才返回 true。
  Future<bool> verifyTicket(
    AuthRecoveryTicket ticket, {
    DateTime? now,
    bool requireNoManualHold = true,
  }) {
    final effectiveNow = now ?? DateTime.now();
    return _withLock(() async {
      final snapshot = await _readLocked();
      _snapshot = snapshot;
      return _ticketMatches(
        snapshot.recordFor(ticket.domain),
        ticket,
        effectiveNow,
        requireNoManualHold,
      );
    });
  }

  /// 在**同一次状态锁内**校验 ticket 并执行 [action]。
  ///
  /// 供协调器做「verify 与 commit 之间无窗口」的受约束提交：ticket 不匹配
  /// 返回 null 且不执行 [action]。锁内只应做本地、短时操作（如条件写会话语义
  /// 的 envelope）；**不得**发网络。
  ///
  /// 加锁顺序：本方法持恢复状态锁期间，[action] 可能取会话锁
  /// （`AuthSessionPersistence`）。固定顺序为**恢复状态锁 → 会话锁**，反向
  /// 顺序不得出现。
  Future<T?> withVerifiedTicket<T>(
    AuthRecoveryTicket ticket, {
    required Future<T> Function() action,
    DateTime? now,
    bool requireNoManualHold = true,
  }) {
    final effectiveNow = now ?? DateTime.now();
    return _withLock(() async {
      final snapshot = await _readLocked();
      _snapshot = snapshot;
      if (!_ticketMatches(
        snapshot.recordFor(ticket.domain),
        ticket,
        effectiveNow,
        requireNoManualHold,
      )) {
        return null;
      }
      return await action();
    });
  }

  bool _ticketMatches(
    AuthRecoveryRecord record,
    AuthRecoveryTicket ticket,
    DateTime now,
    bool requireNoManualHold,
  ) {
    if (ticket.isExpiredAt(now)) return false;
    if (!record.optIn || record.revoked) return false;
    if (record.account != ticket.account) return false;
    if (record.epoch != ticket.epoch) return false;
    if (record.credentialRevision != ticket.credentialRevision) return false;
    final active = record.activeAttempt;
    if (active == null || active.id != ticket.id) return false;
    if (requireNoManualHold && record.manualHoldActiveAt(now)) {
      return false;
    }
    return true;
  }

  Future<AuthRecoveryRecord> clearTicket(
    AuthRecoveryDomain domain, {
    required String ticketId,
  }) {
    return _mutate(domain, (record, now) {
      final active = record.activeAttempt;
      if (active == null || active.id != ticketId) return record;
      return record.copyWith(clearActiveAttempt: true);
    });
  }

  // ── 内部：锁 / 文件 / 编解码 ──────────────────────────────────────

  Future<AuthRecoveryRecord> _mutate(
    AuthRecoveryDomain domain,
    AuthRecoveryRecord Function(AuthRecoveryRecord record, DateTime now) update,
  ) {
    return _withLock(() async {
      final snapshot = await _readLocked();
      final now = DateTime.now();
      final next = snapshot.withRecord(
        domain,
        update(snapshot.recordFor(domain), now),
      );
      await _writeLocked(next);
      _snapshot = next;
      return next.recordFor(domain);
    });
  }

  Future<T> _withLock<T>(Future<T> Function() action) async {
    final lock = await _lock();
    return lock.withLock(action);
  }

  Future<AuthFileLock> _lock() async {
    final dir = await _resolveDir();
    return AuthFileLock(
      lockFile: File('${dir.path}${Platform.pathSeparator}$lockFileName'),
    );
  }

  Future<Directory> _resolveDir() async {
    final override = debugDirectoryProvider;
    if (override != null) return override();
    return getApplicationSupportDirectory();
  }

  Future<File> _stateFile() async {
    final dir = await _resolveDir();
    return File('${dir.path}${Platform.pathSeparator}$stateFileName');
  }

  /// 读坏文件 fail closed：返回「全部未启用」的空快照，不删除、不猜测。
  Future<AuthRecoverySnapshot> _readLocked() async {
    final file = await _stateFile();
    if (!await file.exists()) return AuthRecoverySnapshot.empty;
    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map || raw['v'] != schemaVersion) {
        throw const FormatException('unsupported auth recovery schema');
      }
      final domains = raw['domains'];
      if (domains is! Map) {
        throw const FormatException('missing auth recovery domains');
      }
      final records = <AuthRecoveryDomain, AuthRecoveryRecord>{};
      for (final domain in AuthRecoveryDomain.values) {
        final entry = domains[domain.wireName];
        if (entry == null) continue;
        records[domain] = AuthRecoveryRecord.fromJson(domain, entry);
      }
      return AuthRecoverySnapshot(records: records);
    } catch (error, stackTrace) {
      AppLogger.instance.auth(
        LogLevel.warn,
        '自动恢复状态解析失败，按未启用处理（fail closed）',
        error: error,
        stackTrace: stackTrace,
      );
      return AuthRecoverySnapshot.empty;
    }
  }

  Future<void> _writeLocked(AuthRecoverySnapshot snapshot) async {
    final file = await _stateFile();
    final domains = <String, dynamic>{
      for (final domain in AuthRecoveryDomain.values)
        if (snapshot.records[domain] != null)
          domain.wireName: snapshot.records[domain]!.toJson(),
    };
    final encoded = jsonEncode(<String, dynamic>{
      'v': schemaVersion,
      'domains': domains,
    });
    final tmp = File(
      '${file.path}.${DateTime.now().microsecondsSinceEpoch}'
      '-${_random.nextInt(0x7fffffff)}.tmp',
    );
    await tmp.writeAsString(encoded, flush: true);
    try {
      await tmp.rename(file.path);
    } on FileSystemException {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      rethrow;
    }
  }

  final _random = Random.secure();

  String _newToken(String prefix) {
    final buffer = StringBuffer(prefix);
    buffer.write('-');
    for (var i = 0; i < 12; i++) {
      buffer.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}
