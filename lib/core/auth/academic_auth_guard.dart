import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../logging/app_logger.dart';
import 'auth_recovery_state_store.dart';
import 'auth_session_persistence.dart';
import 'automatic_login.dart';
import 'connect_mode_resolver.dart';
import 'credential_store.dart';
import 'zhengfang_auth.dart';

/// 教务会话过期时由 [AcademicAuthGuard] 抛出的统一异常。
class AcademicAuthExpiredException implements Exception {
  const AcademicAuthExpiredException({this.automaticLoginPaused = false});

  /// 自动登录是否已暂停（身份失败累计达阈值）。为 true 时 UI 应提示用户手动
  /// 登录一次；默认 false 表示普通会话过期。
  final bool automaticLoginPaused;

  @override
  String toString() =>
      automaticLoginPaused ? '自动登录已暂停，请手动登录一次' : '登录状态已过期，请重新登录';
}

/// 调用方传入自定义过期异常时，[AutomaticLoginOutcome.manualRequired] 走本
/// 类型：它仍是 [AcademicAuthExpiredException] 子类，下游
/// `on AcademicAuthExpiredException` 依旧命中，同时让 UI 能按类型区分
/// 「需手动登录」。
class AcademicAuthManualLoginRequiredException
    extends AcademicAuthExpiredException {
  const AcademicAuthManualLoginRequiredException()
    : super(automaticLoginPaused: true);
}

/// 恢复正在退避或等待人工验证码；保留同账号最后一次成功数据。
class AcademicAuthRecoveryPendingException
    extends AcademicAuthExpiredException {
  const AcademicAuthRecoveryPendingException();

  @override
  String toString() => '正在恢复教务登录，稍后自动重试';
}

/// 与响应一起返回的身份凭据，只允许原会话或本次恢复的真实 receipt。
class AcademicGuardedResponse<T> {
  const AcademicGuardedResponse({
    required this.response,
    required this.account,
    required this.revision,
    required this.epoch,
  });

  final Response<T> response;
  final String? account;
  final int revision;
  final int? epoch;
}

class _RecoveryLease {
  const _RecoveryLease(this.account, this.revision, this.epoch);
  final String? account;
  final int revision;
  final int? epoch;
}

/// 封装教务业务请求的"认证过期识别 + 会话恢复 + 自动重试一次"链路（PRD FR-2）。
///
/// 供 exam/grades/schedule 等教务依赖模块复用，避免每个 service 各自重复
/// 302/403/登录页重定向识别与 `markLoggedOut` 逻辑。
class AcademicAuthGuard {
  const AcademicAuthGuard._();

  static final _recoveries =
      <(String?, int, int?, bool), Future<_RecoveryLease>>{};

  /// 测试注入：替换静默自动登录动作（默认走 [AutomaticLoginService.instance]）。
  ///
  /// 这是**旧 enum-only 桩**：它没有来源证据。返回
  /// [AutomaticLoginOutcome.committed] 时 guard 一律 fail closed（不发重试、
  /// 不撤销），因为无法证明该 committed 对应本次提交。需要验证成功路径的测试
  /// 必须改用 [debugAutomaticLoginReceiptOverride] 提供真实 receipt。
  @visibleForTesting
  static Future<AutomaticLoginOutcome> Function(
    AuthRecoveryDomain domain, {
    String? expectedAccount,
  })?
  debugAutomaticLoginOverride;

  /// 测试注入（带 receipt）：优先于 [debugAutomaticLoginOverride]。
  ///
  /// 测试桩必须像真实提交一样推进 [ZhengfangAuth.sessionRevision] 并写入
  /// durable envelope，使 receipt 的 account+epoch 可被 guard 复核。
  @visibleForTesting
  static Future<AutomaticLoginAttemptResult> Function(
    AuthRecoveryDomain domain, {
    String? expectedAccount,
  })?
  debugAutomaticLoginReceiptOverride;

  /// 判断响应是否命中教务认证过期。
  ///
  /// 语义与 [guardRequest] 内部判定完全一致，供教务依赖模块在自行处理
  /// 响应（如 `validateStatus < 1000` 把 901 作为正常响应返回）时复用：
  /// - 901 / 401，或 302 / 303 明确跳到已知登录入口：登录态失效。
  ///   单独 403 属于权限/业务拒绝，未知重定向不触发登录或撤销。
  /// - 状态码 200 且响应体是严格命中的正方登录 HTML
  ///   （[looksLikeZhengfangLoginHtml]）：视为登录态失效。
  /// - 其他状态码 / 空响应 / 非字符串响应体：不是认证过期，绝不误判。
  ///
  /// 本方法只读取状态码与响应体，不记录响应内容，也不产生网络请求。
  static bool isAuthExpiredResponse<T>(Response<T>? response) {
    if (response == null) return false;
    final code = response.statusCode ?? 0;
    if (code == 901 || code == 401) return true;
    if (code == 302 || code == 303) {
      final location = response.headers.value('location') ?? '';
      final lower = location.toLowerCase();
      return lower.contains('/xtgl/login_slogin.html') ||
          lower.contains('kaptcha') ||
          lower.contains('/cas/login') ||
          isZhengfangGatewayLoginUrl(location);
    }
    if (code == 200) {
      final data = response.data;
      if (data is String && looksLikeZhengfangLoginHtml(data)) return true;
    }
    return false;
  }

  static const _webVpnHost = 'webvpn.zjxu.edu.cn';
  static final _webVpnProxiedPath = RegExp(r'^/https?(-\d+)?/');

  /// 判断非 WebVPN 请求是否被 3xx 改道到 WebVPN 代理资源
  /// （`webvpn.zjxu.edu.cn/https/<hex>/…`）。
  ///
  /// 这表示当前出口不在校内、选路已过期，而不是教务登录态失效：只应重新选路
  /// 并恢复会话，**不得**据此撤销会话。WebVPN 自身的 `/login` 仍由
  /// [isAuthExpiredResponse] 识别。
  static bool isRouteMovedResponse<T>(Response<T>? response) {
    if (response == null) return false;
    // 已知登录入口（含 WebVPN 代理的 `/https/<hex>/cas/login`）优先按过期处理。
    if (isAuthExpiredResponse(response)) return false;
    final code = response.statusCode ?? 0;
    if (code < 300 || code >= 400) return false;
    final location = response.headers.value('location')?.trim() ?? '';
    if (location.isEmpty) return false;
    final requestUri = response.requestOptions.uri;
    if (requestUri.host.toLowerCase() == _webVpnHost) return false;
    final target = Uri.tryParse(location);
    if (target == null || target.host.toLowerCase() != _webVpnHost) {
      return false;
    }
    final targetPath = target.path.toLowerCase();
    if (!_webVpnProxiedPath.hasMatch(targetPath)) return false;
    // 只认同一来源的 WebVPN 包装（如 jwzx 的固定前缀），被跳到其它校内站点
    // 的包装不是本次请求的改道。
    final expected = Uri.tryParse(
      ZhengfangAuth.instance.buildWebVpnProxyUrl(
        '${requestUri.scheme}://${requestUri.authority}/',
      ),
    );
    if (expected == null || expected.host.toLowerCase() != _webVpnHost) {
      return false;
    }
    var prefix = expected.path.toLowerCase();
    if (prefix.endsWith('/')) prefix = prefix.substring(0, prefix.length - 1);
    return targetPath == prefix || targetPath.startsWith('$prefix/');
  }

  /// 执行 [request]，若响应命中认证过期则尝试恢复会话后重试一次。
  ///
  /// - 首次命中过期 → 调用 [ConnectModeResolver] 判定模式并做**无登出副作用**
  ///   的会话探测（直连走 `validateSession(revokeOnInvalid: false)`，WebVPN 走
  ///   `ensureWebVpnGatewaySession`）。
  /// - 恢复成功 → 重试原请求；重试仍命中过期 → 抛 [authExpiredException]。
  /// - 恢复失败 → 前台静默尝试一次自动登录（凭据 + OCR + typed ticket
  ///   commit）：提交产出**真实 receipt** 才重试原请求一次；仍失败则抛异常。
  ///   判定为 [AutomaticLoginOutcome.manualRequired] 时，抛出携带「自动登录已
  ///   暂停」语义的过期异常，供 UI 提示手动登录一次。
  ///
  /// 全程绑定**发起时的 owner + [ZhengfangAuth.sessionRevision] + 持久 epoch**：
  /// 任何 await 边界后若会话已变化（切号、同账号重登、登出），本次失效响应即
  /// 属于旧 owner，一律 fail closed——不触发恢复探测、不 OCR 自动登录、不重试、
  /// 更不撤销，绝不动新会话。
  ///
  /// 终态撤销只走条件 CAS：[ZhengfangAuth.revokeExpiredSessionIfCurrent]（有可信
  /// 账号+epoch）或 [ZhengfangAuth.revokeSessionIfCurrent]（本次 receipt）。读
  /// 失败 / 无可信 epoch 时至多条件清旧内存，绝不无条件持久 revoke。
  static Future<Response<T>> guardRequest<T>({
    required Future<Response<T>> Function() request,
    Object authExpiredException = const AcademicAuthExpiredException(),
  }) async => (await guardWithSession<T>(
    request: request,
    authExpiredException: authExpiredException,
  )).response;

  /// 只读业务的有界再查询，同时返回可用于私有缓存条件提交的身份版本。
  static Future<AcademicGuardedResponse<T>> guardWithSession<T>({
    required Future<Response<T>> Function() request,
    Object authExpiredException = const AcademicAuthExpiredException(),
  }) async {
    final auth = ZhengfangAuth.instance;
    final revision = auth.sessionRevision;
    final account = auth.currentStudentId;
    final epoch = await _knownEpoch(account);
    if (!_isSessionCurrent(auth, revision)) throw authExpiredException;
    final first = await _safeRequest(request);
    if (!_isSessionCurrent(auth, revision)) throw authExpiredException;
    var lease = _RecoveryLease(account, revision, epoch);
    final routeMoved = isRouteMovedResponse(first);
    if (routeMoved || isAuthExpiredResponse(first)) {
      // 改道恢复与过期恢复分开去重：前者绝不走撤销终态。
      final key = (account, revision, epoch, routeMoved);
      if (routeMoved && !_recoveries.containsKey(key)) {
        AppLogger.instance.auth(LogLevel.info, '教务请求被改道到 WebVPN，重新选路后重试');
        // 缓存里的 direct 已过期：让恢复链路里的 resolve() 重新探测。
        ConnectModeResolver.instance.invalidate();
      }
      final pending = _recoveries.putIfAbsent(
        key,
        () => _recover(
          lease,
          const AcademicAuthExpiredException(),
          routeOnly: routeMoved,
        ),
      );
      try {
        lease = await pending;
      } on AcademicAuthRecoveryPendingException {
        rethrow;
      } on AcademicAuthExpiredException catch (error) {
        if (error.automaticLoginPaused) {
          throw _expiredExceptionFor(
            authExpiredException,
            AutomaticLoginOutcome.manualRequired,
          );
        }
        throw authExpiredException;
      } finally {
        if (identical(_recoveries[key], pending)) _recoveries.remove(key);
      }
      if (!await _leaseIsCurrent(lease)) throw authExpiredException;
      final retry = await _safeRequest(request);
      if (!await _leaseIsCurrent(lease)) throw authExpiredException;
      if (isRouteMovedResponse(retry)) {
        // 重新选路后仍被改道：属于暂时性选路失败，保留会话与旧数据。
        throw const AcademicAuthRecoveryPendingException();
      }
      if (isAuthExpiredResponse(retry)) {
        await auth.revokeExpiredSessionIfCurrent(
          revision: lease.revision,
          account: lease.account,
          expectedEpoch: lease.epoch ?? -1,
        );
        throw authExpiredException;
      }
      return AcademicGuardedResponse(
        response: retry,
        account: lease.account,
        revision: lease.revision,
        epoch: lease.epoch,
      );
    }
    if (!await _leaseIsCurrent(lease)) throw authExpiredException;
    return AcademicGuardedResponse(
      response: first,
      account: account,
      revision: revision,
      epoch: epoch,
    );
  }

  static Future<bool> _leaseIsCurrent(_RecoveryLease lease) async {
    final auth = ZhengfangAuth.instance;
    if (auth.sessionRevision != lease.revision ||
        auth.currentStudentId != lease.account) {
      return false;
    }
    final epoch = lease.epoch;
    final account = lease.account;
    if (epoch == null || epoch < 0 || account == null) return true;
    final current = await AuthSessionPersistence.instance
        .withCurrentSession<bool>(
          CredentialSessionDomain.academic,
          account: account,
          expectedEpoch: epoch,
          action: () async =>
              auth.sessionRevision == lease.revision &&
              auth.currentStudentId == account,
        );
    return current == true;
  }

  static Future<int> _knownEpoch(String? account) async {
    try {
      final session = await AuthSessionPersistence.instance.read(
        CredentialSessionDomain.academic,
      );
      return session.active && session.account == account ? session.epoch : -1;
    } catch (_) {
      return -1;
    }
  }

  /// [routeOnly] 为 true 时（请求只是被改道到 WebVPN）恢复失败**绝不撤销**
  /// 会话：选路变化不是登录态失效。需手动登录时抛暂停语义的过期异常，其余
  /// 一律按暂时失败抛 [AcademicAuthRecoveryPendingException]，保留缓存；并把
  /// 恢复链路切换的全局模式回滚到发起前，免得下一次请求带着未建成的 WebVPN
  /// 模式落入普通过期（会撤销）路径。
  static Future<_RecoveryLease> _recover(
    _RecoveryLease start,
    Object expired, {
    bool routeOnly = false,
  }) async {
    if (!routeOnly) return _recoverInner(start, expired, routeOnly: false);
    final auth = ZhengfangAuth.instance;
    final modeBefore = auth.mode;
    try {
      return await _recoverInner(start, expired, routeOnly: true);
    } catch (_) {
      if (_isSessionCurrent(auth, start.revision) && auth.mode != modeBefore) {
        auth.restoreModeWithoutNotify(modeBefore);
      }
      rethrow;
    }
  }

  static Future<_RecoveryLease> _recoverInner(
    _RecoveryLease start,
    Object expired, {
    required bool routeOnly,
  }) async {
    final auth = ZhengfangAuth.instance;
    final recovered = await _attemptRecovery();
    if (!_isSessionCurrent(auth, start.revision)) throw expired;
    if (recovered) return start;
    final attempt = await _attemptSilentAutomaticLogin(start.account);
    if (attempt.outcome == AutomaticLoginOutcome.committed) {
      final receipt = attempt.receipt;
      final committedRevision = auth.sessionRevision;
      if (receipt == null ||
          !await _receiptProvesCurrentSession(
            receipt,
            ownerAccount: start.account,
            revisionBeforeCommit: start.revision,
          )) {
        throw expired;
      }
      // 固定 receipt 对应的内存版本，后续旁路重登不得被接受。
      if (auth.sessionRevision != committedRevision) throw expired;
      return _RecoveryLease(receipt.account, committedRevision, receipt.epoch);
    }
    if (!_isSessionCurrent(auth, start.revision)) throw expired;
    if (attempt.outcome == AutomaticLoginOutcome.busy ||
        attempt.outcome == AutomaticLoginOutcome.cooldown ||
        attempt.outcome == AutomaticLoginOutcome.failed) {
      // 暂时失败不能撤销另一条恢复事务，也不能清掉同账号最后成功快照。
      throw const AcademicAuthRecoveryPendingException();
    }
    if (routeOnly) {
      if (attempt.outcome == AutomaticLoginOutcome.manualRequired) {
        throw _expiredExceptionFor(expired, attempt.outcome);
      }
      throw const AcademicAuthRecoveryPendingException();
    }
    await auth.revokeExpiredSessionIfCurrent(
      revision: start.revision,
      account: start.account,
      expectedEpoch: start.epoch ?? -1,
    );
    throw _expiredExceptionFor(expired, attempt.outcome);
  }

  /// 会话 revision 是否仍等于发起时的值；任何身份变化都会推进 revision。
  static bool _isSessionCurrent(ZhengfangAuth auth, int revision) =>
      auth.sessionRevision == revision;

  /// 证明 [receipt] 对应**本次**提交：本地内存账号/revision 已体现该提交，且
  /// 持久 envelope 仍是 receipt 的 account+epoch（原子条件读）。任一不成立
  /// 都说明存在旁路提交或身份已变，不得据该 receipt 重试或撤销。
  static Future<bool> _receiptProvesCurrentSession(
    SessionCommitResult receipt, {
    required String? ownerAccount,
    required int revisionBeforeCommit,
  }) async {
    final auth = ZhengfangAuth.instance;
    final receiptAccount = receipt.account.trim();
    if (receiptAccount.isEmpty) return false;
    final expected = ownerAccount?.trim() ?? '';
    if (expected.isNotEmpty && receiptAccount != expected) return false;
    if ((auth.currentStudentId?.trim() ?? '') != receiptAccount) return false;
    if (auth.sessionRevision == revisionBeforeCommit) return false;
    final capturedRevision = auth.sessionRevision;
    try {
      final current = await AuthSessionPersistence.instance
          .withCurrentSession<bool>(
            CredentialSessionDomain.academic,
            account: receiptAccount,
            expectedEpoch: receipt.epoch,
            action: () async => true,
          );
      return current == true &&
          auth.sessionRevision == capturedRevision &&
          auth.currentStudentId?.trim() == receiptAccount;
    } catch (error, stackTrace) {
      AppLogger.instance.auth(
        LogLevel.warn,
        'receipt 归属校验失败',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  /// 前台单 isolate 的静默自动登录尝试；异常隔离，绝不中断 guard 链路。
  ///
  /// [expectedAccount] 使用**发起时**捕获的账号，避免恢复期间切号后把自动
  /// 登录错绑到新账号；调用方已确保会话未变化才进入本方法。
  ///
  /// 优先使用带 receipt 的测试桩；旧 enum-only 桩的 committed 无来源证据，
  /// receipt 留空，guard 会据此 fail closed。
  static Future<AutomaticLoginAttemptResult> _attemptSilentAutomaticLogin(
    String? expectedAccount,
  ) async {
    final domain = AuthRecoveryDomain.academic;
    try {
      final receiptOverride = debugAutomaticLoginReceiptOverride;
      if (receiptOverride != null) {
        return await receiptOverride(domain, expectedAccount: expectedAccount);
      }
      final enumOverride = debugAutomaticLoginOverride;
      if (enumOverride != null) {
        return AutomaticLoginAttemptResult(
          outcome: await enumOverride(domain, expectedAccount: expectedAccount),
        );
      }
      return await AutomaticLoginService.instance.attemptWithReceipt(
        domain,
        expectedAccount: expectedAccount,
      );
    } catch (error, stackTrace) {
      AppLogger.instance.auth(
        LogLevel.warn,
        '静默自动登录执行异常',
        error: error,
        stackTrace: stackTrace,
      );
      return const AutomaticLoginAttemptResult(
        outcome: AutomaticLoginOutcome.failed,
      );
    }
  }

  /// manualRequired 时让抛出的异常可被 UI 区分；其余结果保持调用方原对象。
  static Object _expiredExceptionFor(
    Object provided,
    AutomaticLoginOutcome outcome,
  ) {
    if (outcome != AutomaticLoginOutcome.manualRequired) return provided;
    if (provided is AcademicAuthExpiredException) {
      return provided.automaticLoginPaused
          ? provided
          : const AcademicAuthExpiredException(automaticLoginPaused: true);
    }
    return const AcademicAuthManualLoginRequiredException();
  }

  static Future<Response<T>> _safeRequest<T>(
    Future<Response<T>> Function() request,
  ) async {
    try {
      return await request();
    } on DioException catch (e) {
      // 仅将明确过期的 901/401、指向已知登录入口的 302/303、改道到 WebVPN
      // 的 3xx 或 200 登录 HTML 封装为可识别响应；403、未知重定向及传输
      // 异常按原错误抛出。
      final response = e.response;
      if (response == null ||
          !(isAuthExpiredResponse(response) ||
              isRouteMovedResponse(response))) {
        rethrow;
      }
      // Dio 抛出的 DioException.response 运行期类型是 Response<dynamic>，
      // 直接 `as Response<T>` 在 T 为具体类型时抛 TypeError；这里按 T 安全重建。
      return Response<T>(
        requestOptions: response.requestOptions,
        data: response.data is T ? response.data as T : null,
        headers: response.headers,
        statusCode: response.statusCode,
        statusMessage: response.statusMessage,
        isRedirect: response.isRedirect,
        redirects: response.redirects,
        extra: response.extra,
      );
    }
  }

  static Future<bool> _attemptRecovery() async {
    try {
      final mode = await ConnectModeResolver.instance.resolve();
      if (mode != null) ZhengfangAuth.instance.setMode(mode);
      if (mode == ZhengfangMode.webVpn) {
        final ok = await ZhengfangAuth.instance.ensureWebVpnGatewaySession(
          syncWebViewCookies: false,
        );
        if (ok != true) return false;
        // 网关与教务是不同认证域，网关 ready 不能证明正方 Cookie 有效。
        return await ZhengfangAuth.instance.validateSession(
              revokeOnInvalid: false,
            ) ==
            true;
      }
      if (mode == ZhengfangMode.direct) {
        // 无登出副作用探测：撤销留给 guard 的终态条件撤销，探测本身不得
        // 先登出，否则 guard 会因 revision 变化而 fail closed、无法走 OCR。
        final ok = await ZhengfangAuth.instance.validateSession(
          revokeOnInvalid: false,
        );
        return ok == true;
      }
      return false;
    } catch (e, s) {
      AppLogger.instance.auth(
        LogLevel.warn,
        '教务会话恢复失败',
        error: e,
        stackTrace: s,
      );
      return false;
    }
  }
}
