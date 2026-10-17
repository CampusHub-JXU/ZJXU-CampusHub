import 'dart:async';

import 'package:dio/dio.dart';

import '../logging/app_logger.dart';
import 'auth_recovery_state_store.dart';
import 'auth_session_persistence.dart';
import 'background_auth_context.dart';
import 'background_session_gate.dart';
import 'credential_store.dart';

/// 某个认证域在轮次开始时的持久会话快照：epoch 用于钉住，account 用于归属。
typedef BackgroundSessionPin = ({int epoch, String? account});

/// 读取某个域当前的 [BackgroundSessionPin]；测试注入桩，生产走
/// [readCurrentSessionPin]。
typedef BackgroundSessionPinReader = Future<BackgroundSessionPin> Function(
  AuthRecoveryDomain domain,
);

/// 生产读取：持久 envelope 的 epoch / account；account 缺失（已登出）时退回
/// 凭据库里的账号，与桌面组件历史口径一致。
Future<BackgroundSessionPin> readCurrentSessionPin(
  AuthRecoveryDomain domain,
) async {
  final isCas = domain == AuthRecoveryDomain.cas;
  final envelope = await AuthSessionPersistence.instance.read(
    isCas ? CredentialSessionDomain.unified : CredentialSessionDomain.academic,
  );
  final account =
      envelope.account ??
      (isCas
              ? await CredentialStore.instance.loadUnifiedAuthCredentials()
              : await CredentialStore.instance.loadCredentials())
          ?.$1;
  return (epoch: envelope.epoch, account: account);
}

/// 把 [domains] 当前的持久 epoch / 账号钉进 [context]。
///
/// 钉住之后：嵌套自动登录只认「本轮起始 epoch + 同一账号」，
/// `AuthSessionPersistence.revoke` 只撤销被钉住的那个会话——前台在申领之后
/// 重新登录（epoch 已前进）时，本轮的撤销 / 自动恢复都会让位，绝不踢掉新会话。
///
/// 必须在本轮首次触碰会话（restoreSession / validateSession / 自动登录）**之前**调用。
Future<void> pinBackgroundSessions(
  BackgroundAuthContext context,
  Iterable<AuthRecoveryDomain> domains, {
  BackgroundSessionPinReader? reader,
}) async {
  final read = reader ?? readCurrentSessionPin;
  for (final domain in domains) {
    final pin = await read(domain);
    context.expectedEpochs[domain.wireName] = pin.epoch;
    context.expectedAccounts[domain.wireName] = pin.account;
  }
}

/// [BackgroundAuthRun.execute] 的结果。
class BackgroundAuthRunResult<T> {
  const BackgroundAuthRunResult._({
    required this.claimed,
    this.value,
    this.timedOut = false,
    this.yielded = false,
    this.budgetExpired = false,
  });

  /// 申领未成功：本轮什么都没做（前台心跳新鲜 / 他人持有申领 / 门读写失败）。
  const BackgroundAuthRunResult._denied() : this._(claimed: false);

  /// 是否拿到申领。为 false 时 [value] 一定为 null、body 从未执行。
  final bool claimed;

  /// body 的返回值；超时放弃时为 null。
  final T? value;

  /// 总预算 + 宽限到期，body 仍未返回（挂在不响应取消的 await 上）而被放弃。
  /// 申领已照常释放；body 迟到的任何结果被丢弃。
  final bool timedOut;

  /// 轮次中途发现前台回来 / 申领丢失而让位（取消令牌已取消）。
  final bool yielded;

  /// 总预算先到期（取消令牌已取消）。
  final bool budgetExpired;
}

/// 后台「申领 → 心跳让位 → 预算 → epoch 钉住 → 释放」的共享原语。
///
/// 此前桌面组件（`campus_widget_background.dart`）与通知恢复
/// （`background_cas_recovery.dart`）各自实现一套且已分叉（预算 105s vs 75s；
/// 通知路径没有安装 [BackgroundAuthContext]、因此没有 epoch 钉住）。所有会触碰
/// 认证状态的后台任务都应经本类：
///
/// 1. [BackgroundSessionGate.tryClaim]；失败返回 `claimed == false`，调用方
///    自行决定是「让位」还是「稍后重试」；
/// 2. 安装 [BackgroundAuthContext]：嵌套 [AutomaticLoginService] 共享同一取消令牌，
///    可选地钉住 [pinDomains] 的起始 epoch / 账号；
/// 3. 每 [yieldPollInterval] 复查 [BackgroundSessionGate.shouldYield]，前台一出现
///    立即取消令牌；
/// 4. 总预算 [budget] 到期取消令牌；再过 [hardStopGrace] body 仍未返回则**放弃等待**
///    （`timedOut`），保证整体 Future 与申领释放都落在申领 TTL
///    （[BackgroundSessionGate.claimTtl]）之内——否则 TTL 过期后他人申领成功，
///    本轮迟到的撤销 / 提交会踢掉对方刚提交的会话；
/// 5. `finally` 释放申领，并按 [recordChange] 留下的记录写变更种类 / 账号 / epoch。
///
/// 本类**不**清任何 Cookie、不新增提交路径、不改变「只认真实提交 receipt」
/// 与「明确身份错误累计 3 次暂停」等约束——那些仍由 `AutomaticLoginService` /
/// `AuthOperationCoordinator` 裁决。放弃等待的 body 在后台继续运行到自然结束，
/// 但取消令牌已取消、[BackgroundAuthContext.allowed] 恒为 false，嵌套登录与
/// 推送都会拒绝继续。
///
/// **边界（不得夸大）**：这不是跨 isolate 原子事务；跨 isolate `PersistCookieJar`
/// 竞争只被收窄、没有被消除（见 [BackgroundSessionGate]）。
class BackgroundAuthRun {
  BackgroundAuthRun._(this.gate, this.claim, this.context);

  /// 总预算默认值。须小于 [BackgroundSessionGate.claimTtl] 减去 [defaultHardStopGrace]
  /// 与释放耗时（2 分钟 − 8s − 锁等待）。
  static const Duration defaultBudget = Duration(seconds: 100);

  /// 预算到期后给 body 响应取消的最长额外时间。
  static const Duration defaultHardStopGrace = Duration(seconds: 8);

  static const Duration defaultYieldPollInterval = Duration(seconds: 2);

  /// 释放前读取变更 epoch 的上限，避免阻塞释放。
  static const Duration _changeEpochReadTimeout = Duration(seconds: 5);

  final BackgroundSessionGate gate;
  final BackgroundLoginClaim claim;
  final BackgroundAuthContext context;

  /// 本轮取消令牌：让位 / 预算到期 / 轮次结束都会取消它。
  CancelToken get cancelToken => context.cancelToken;

  bool _yielded = false;
  bool _budgetExpired = false;

  /// 轮次中途让位过（前台回来 / 申领丢失）。
  bool get yielded => _yielded;

  /// 总预算已到期。
  bool get budgetExpired => _budgetExpired;

  BackgroundSessionChangeKind? _changeKind;
  String? _changeAccount;
  Future<int?> Function()? _changeEpochReader;

  /// 记录释放时写入的会话变更（后一次覆盖前一次）。
  ///
  /// [account] 与 [readEpoch] 同时给出时，释放前读取 epoch 并一并写入
  /// （`revoked` 记录靠它判断是否已被前台新登录取代，见
  /// [BackgroundSessionChange.revokedStillApplies]）；读不到就不带，前台按
  /// 「不适用」处理。
  void recordChange(
    BackgroundSessionChangeKind kind, {
    String? account,
    Future<int?> Function()? readEpoch,
  }) {
    _changeKind = kind;
    _changeAccount = account;
    _changeEpochReader = readEpoch;
  }

  /// 钉住 [domains] 的起始 epoch / 账号（见 [pinBackgroundSessions]）。
  Future<void> pin(
    Iterable<AuthRecoveryDomain> domains, {
    BackgroundSessionPinReader? reader,
  }) => pinBackgroundSessions(context, domains, reader: reader);

  Future<void> _release() async {
    int? epoch;
    final reader = _changeEpochReader;
    if (_changeKind != null && _changeAccount != null && reader != null) {
      try {
        epoch = await reader().timeout(_changeEpochReadTimeout);
      } catch (_) {
        epoch = null;
      }
    }
    await gate.release(
      claim,
      change: _changeKind,
      changeAccount: _changeAccount,
      changeEpoch: epoch,
    );
  }

  /// 执行一轮后台认证工作。
  ///
  /// [pinDomains] 非空时在 body 之前钉住这些域（[pinReader] 供测试注入）；
  /// body 内部也可以自行 [pin]（桌面组件在其缓存恢复阶段钉住，保持既有的
  /// 注入缝）。body 抛出的异常在释放申领之后原样重新抛出。
  static Future<BackgroundAuthRunResult<T>> execute<T>({
    required Future<T> Function(BackgroundAuthRun run) body,
    BackgroundSessionGate? gate,
    Duration budget = defaultBudget,
    Duration hardStopGrace = defaultHardStopGrace,
    Duration yieldPollInterval = defaultYieldPollInterval,
    Set<AuthRecoveryDomain> pinDomains = const {},
    BackgroundSessionPinReader? pinReader,
    String label = '后台认证轮次',
  }) async {
    final theGate = gate ?? BackgroundSessionGate.instance;
    final claim = await theGate.tryClaim();
    if (claim == null) return BackgroundAuthRunResult<T>._denied();

    late final BackgroundAuthRun run;
    final context = BackgroundAuthContext(
      mayContinue: () async {
        final shouldLeave = await theGate.shouldYield(claim);
        if (shouldLeave) run._yielded = true;
        return !shouldLeave;
      },
    );
    run = BackgroundAuthRun._(theGate, claim, context);

    final done = Completer<T?>();
    var timedOut = false;
    var polling = false;
    Timer? poll;
    Timer? budgetTimer;
    Timer? hardStop;
    try {
      poll = Timer.periodic(yieldPollInterval, (_) {
        // 门读写在锁内做本地 IO；上一次复查未返回就不叠加。
        if (polling || context.cancelToken.isCancelled) return;
        polling = true;
        unawaited(
          context
              .allowed()
              .whenComplete(() => polling = false)
              .catchError((_) => false),
        );
      });
      budgetTimer = Timer(budget, () {
        run._budgetExpired = true;
        if (!context.cancelToken.isCancelled) {
          context.cancelToken.cancel('$label budget');
        }
      });
      hardStop = Timer(budget + hardStopGrace, () {
        if (done.isCompleted) return;
        timedOut = true;
        AppLogger.instance.auth(LogLevel.warn, '$label：预算与宽限到期，放弃等待并释放申领');
        done.complete(null);
      });
      unawaited(
        context
            .run(() async {
              if (pinDomains.isNotEmpty) {
                await pinBackgroundSessions(
                  context,
                  pinDomains,
                  reader: pinReader,
                );
              }
              return body(run);
            })
            .then(
              (value) {
                if (!done.isCompleted) done.complete(value);
              },
              onError: (Object error, StackTrace stackTrace) {
                if (!done.isCompleted) {
                  done.completeError(error, stackTrace);
                } else {
                  AppLogger.instance.auth(
                    LogLevel.debug,
                    '$label：已放弃等待的 body 迟到失败',
                    error: error,
                    stackTrace: stackTrace,
                  );
                }
              },
            ),
      );
      final value = await done.future;
      return BackgroundAuthRunResult<T>._(
        claimed: true,
        value: timedOut ? null : value,
        timedOut: timedOut,
        yielded: run._yielded,
        budgetExpired: run._budgetExpired,
      );
    } finally {
      poll?.cancel();
      budgetTimer?.cancel();
      hardStop?.cancel();
      if (!context.cancelToken.isCancelled) {
        context.cancelToken.cancel('$label finished');
      }
      await run._release();
    }
  }
}
