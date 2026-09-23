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

/// 封装教务业务请求的"认证过期识别 + 会话恢复 + 自动重试一次"链路（PRD FR-2）。
///
/// 供 exam/grades/schedule 等教务依赖模块复用，避免每个 service 各自重复
/// 302/403/登录页重定向识别与 `markLoggedOut` 逻辑。
class AcademicAuthGuard {
  const AcademicAuthGuard._();

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
  /// - 状态码 901 / 302 / 303 / 401 / 403：业务接口不应出现这些状态，
  ///   一律视为登录态失效（901 是教务未登录/会话失效的专用状态码）。
  /// - 状态码 200 且响应体是严格命中的正方登录 HTML
  ///   （[looksLikeZhengfangLoginHtml]）：视为登录态失效。
  /// - 其他状态码 / 空响应 / 非字符串响应体：不是认证过期，绝不误判。
  ///
  /// 本方法只读取状态码与响应体，不记录响应内容，也不产生网络请求。
  static bool isAuthExpiredResponse<T>(Response<T>? response) {
    if (response == null) return false;
    final code = response.statusCode ?? 0;
    // 业务接口不应重定向；901/302/303/401/403 都视为登录态失效。
    if (code == 901 ||
        code == 302 ||
        code == 303 ||
        code == 401 ||
        code == 403) {
      return true;
    }
    if (code == 200) {
      final data = response.data;
      if (data is String && looksLikeZhengfangLoginHtml(data)) return true;
    }
    return false;
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
  }) async {
    final auth = ZhengfangAuth.instance;
    final revisionAtStart = auth.sessionRevision;
    final accountAtStart = auth.currentStudentId;
    final epochAtStart = await auth.durableAcademicEpochOrUnknown();
    // 持久 epoch 读取本身是异步边界：若期间已换号/重登，连首次业务请求
    // 都不应再用新会话为旧 owner 发出。
    if (!_isSessionCurrent(auth, revisionAtStart)) {
      throw authExpiredException;
    }

    final resp = await _safeRequest(request);
    if (!isAuthExpiredResponse<T>(resp)) return resp;

    // 首个请求期间身份已变化：本失效响应属于旧 owner，fail closed。
    if (!_isSessionCurrent(auth, revisionAtStart)) {
      AppLogger.instance.auth(LogLevel.warn, '教务请求命中认证过期，但会话已变化，放弃恢复与撤销');
      throw authExpiredException;
    }

    AppLogger.instance.auth(LogLevel.warn, '教务请求命中认证过期，尝试恢复会话后重试一次');
    final recovered = await _attemptRecovery();

    // 恢复探测期间身份已变化：本次失效响应/恢复结果属于旧 owner，不重试、
    // 不 OCR、不撤销新会话，fail closed。
    if (!_isSessionCurrent(auth, revisionAtStart)) {
      AppLogger.instance.auth(LogLevel.warn, '会话恢复期间身份已变化，放弃重试、自动登录与撤销');
      throw authExpiredException;
    }

    if (recovered) {
      final retry = await _safeRequest(request);
      if (!isAuthExpiredResponse<T>(retry)) return retry;
      AppLogger.instance.auth(LogLevel.warn, '教务请求重试后仍命中认证过期，条件撤销');
      await auth.revokeExpiredSessionIfCurrent(
        revision: revisionAtStart,
        account: accountAtStart,
        expectedEpoch: epochAtStart,
      );
      throw authExpiredException;
    }

    // 会话恢复失败：前台静默尝试一次自动登录；只有真实 receipt 才重试原请求。
    final revisionBeforeAutoLogin = auth.sessionRevision;
    final attempt = await _attemptSilentAutomaticLogin(accountAtStart);
    final outcome = attempt.outcome;

    if (outcome == AutomaticLoginOutcome.committed) {
      final receipt = attempt.receipt;
      if (receipt == null ||
          !await _receiptProvesCurrentSession(
            receipt,
            ownerAccount: accountAtStart,
            revisionBeforeCommit: revisionBeforeAutoLogin,
          )) {
        // 无来源归属 / 旁路登录 / 身份已变：fail closed，不发无归属 retry，
        // 也绝不撤销旁路登录。
        AppLogger.instance.auth(
          LogLevel.warn,
          '自动登录 committed 无可信 receipt 归属，fail closed',
        );
        throw _expiredExceptionFor(authExpiredException, outcome);
      }
      final revisionAfterCommit = auth.sessionRevision;
      final retry = await _safeRequest(request);
      // 重试期间或之后外部并发换号：fail closed，不撤销旁路登录。
      if (!await _receiptProvesCurrentSession(
        receipt,
        ownerAccount: accountAtStart,
        revisionBeforeCommit: revisionBeforeAutoLogin,
      )) {
        AppLogger.instance.auth(LogLevel.warn, '自动登录重试期间身份已变化，fail closed');
        throw _expiredExceptionFor(authExpiredException, outcome);
      }
      if (!isAuthExpiredResponse<T>(retry)) return retry;
      AppLogger.instance.auth(LogLevel.warn, '自动登录成功后重试仍命中认证过期，条件撤销本次 receipt');
      await auth.revokeSessionIfCurrent(
        revision: revisionAfterCommit,
        account: receipt.account,
        expectedEpoch: receipt.epoch,
      );
      throw _expiredExceptionFor(authExpiredException, outcome);
    }

    // 非提交终态：仅在仍是请求发起时的 owner/epoch 时条件撤销，否则至多清旧内存。
    await auth.revokeExpiredSessionIfCurrent(
      revision: revisionAtStart,
      account: accountAtStart,
      expectedEpoch: epochAtStart,
    );
    throw _expiredExceptionFor(authExpiredException, outcome);
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
    try {
      final current = await AuthSessionPersistence.instance
          .withCurrentSession<bool>(
            CredentialSessionDomain.academic,
            account: receiptAccount,
            expectedEpoch: receipt.epoch,
            action: () async => true,
          );
      return current == true;
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
      // 业务接口配置 validateStatus < 1000，302/901 不会抛；但 403/网络异常
      // 可能抛。仅当 DioException 携带明确认证过期状态（901/302/303/401/403
      // 或 200 登录 HTML）时才封装为可识别的响应，其他非认证错误一律重抛，
      // 不得吞掉。
      final response = e.response;
      if (response == null || !isAuthExpiredResponse(response)) rethrow;
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
      if (mode == ZhengfangMode.webVpn) {
        final ok = await ZhengfangAuth.instance.ensureWebVpnGatewaySession(
          syncWebViewCookies: false,
        );
        return ok == true;
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
