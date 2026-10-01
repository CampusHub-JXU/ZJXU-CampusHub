import 'dart:async';

import 'package:dio/dio.dart';

import '../logging/app_logger.dart';
import '../network/dio_client.dart';
import 'cas_auth_broker.dart';
import 'cas_routed_access.dart';
import 'connect_mode_resolver.dart';
import 'unified_auth.dart';
import 'zhengfang_auth.dart';

/// 教务 H5 入口的准备结果（headless，不展示任何 UI）。
sealed class AcademicWebEntryResult {
  const AcademicWebEntryResult();
}

/// 已准备就绪：可直接交给 WebView 载入 [url]，并携带 [headers]。
class AcademicWebEntryReady extends AcademicWebEntryResult {
  AcademicWebEntryReady({
    required this.url,
    required Map<String, String> headers,
    required this.selectedMode,
  }) : headers = Map<String, String>.unmodifiable(headers);

  final String url;
  final Map<String, String> headers;
  final ZhengfangMode selectedMode;

  bool get isWebVpn => selectedMode == ZhengfangMode.webVpn;

  @override
  String toString() =>
      'AcademicWebEntryReady(mode=$selectedMode, url=$url, '
      '${headers.length} header(s))';
}

/// 教务（正方）账号会话不可用，需要用户完成教务登录。
class AcademicWebEntryNeedsAcademicLogin extends AcademicWebEntryResult {
  const AcademicWebEntryNeedsAcademicLogin();

  @override
  String toString() => 'AcademicWebEntryNeedsAcademicLogin()';
}

/// 校外 WebVPN 网关需要统一认证（CAS）会话，需要用户先完成统一认证登录。
class AcademicWebEntryNeedsUnifiedLogin extends AcademicWebEntryResult {
  const AcademicWebEntryNeedsUnifiedLogin();

  @override
  String toString() => 'AcademicWebEntryNeedsUnifiedLogin()';
}

/// 暂时不可用（网络未知 / 初始化失败 / 无法代理），不代表会话失效。
class AcademicWebEntryUnavailable extends AcademicWebEntryResult {
  const AcademicWebEntryUnavailable(this.message);

  final String message;

  @override
  String toString() => 'AcademicWebEntryUnavailable($message)';
}

/// 目标被拒绝：非受信入口 / 携带 ticket / 越权 query，一律 fail closed。
class AcademicWebEntryDenied extends AcademicWebEntryResult {
  const AcademicWebEntryDenied(this.message);

  final String message;

  @override
  String toString() => 'AcademicWebEntryDenied($message)';
}

/// 本次准备已作废：被调用方取消、超出预算或准备期间身份已变化。
enum AcademicWebEntryStaleReason {
  /// 调用方取消或整体预算耗尽，传输已被真实取消。
  cancelled,

  /// 准备期间账号 / auth revision 变化，旧 owner 的结果必须丢弃。
  identityChanged,
}

class AcademicWebEntryStale extends AcademicWebEntryResult {
  const AcademicWebEntryStale(this.reason);

  final AcademicWebEntryStaleReason reason;

  @override
  String toString() => 'AcademicWebEntryStale($reason)';
}

/// 目标直连解析器：按目标 origin 判定直连 / WebVPN。
typedef AcademicModeResolver = Future<ZhengfangMode?> Function(
  String targetUrl,
);

/// WebVPN 网关会话确保器（复用 CAS broker 真实回调，不伪造 ticket）。
/// 需要统一认证时抛 [CasAuthExpiredException]。
typedef AcademicGatewaySessionEnsurer = Future<void> Function(
  CancelToken token,
  DateTime deadline,
);

/// 教务业务会话探测器：返回 fail-closed 的分类结果
/// （[AcademicEntrySessionStatus]）；无法证明时必须返回 `unknown`，绝不判就绪。
typedef AcademicSessionProber = Future<AcademicEntrySessionStatus> Function(
  ZhengfangMode mode,
  String requestUrl,
  CancelToken token,
);

/// 按显式 mode 同步教务 Cookie 到 WebView；[isIdentityCurrent] 会在每个写
/// 副作用前复核，返回 false 立即中止。
typedef AcademicCookieSyncer = Future<void> Function(
  ZhengfangMode mode,
  bool Function() isIdentityCurrent,
);

/// 按显式 mode 构造 WebView 初始请求头。
typedef AcademicHeaderBuilder = Future<Map<String, String>> Function(
  ZhengfangMode mode,
  String resolvedUrl,
);

/// 受信教务 H5 入口的有界 headless 准备控制器。
///
/// 只处理固定入口
/// `https://jwzx.zjxu.edu.cn/jwglxt/xtgl/index_initMenu.html`（`jsdm` 仅
/// `xs` / `query`），不接受任意 URL / ticket；自动完成「目标 origin 选路 →
/// （WebVPN 时）真实 CAS 网关回调 → 教务业务会话探测 → 按本次 mode 同步
/// Cookie / 生成请求头」，并返回类型化结果。
///
/// 安全不变量：
/// - 绝不修改全局 [ZhengfangAuth.mode] 或任何认证标记；失败的尝试不留副作用。
/// - 绝不 `restoreSession` / `markLoggedOut` / `validateSession`；只用当前
///   内存中的已验证 owner；网络失败一律归为 unknown，不判失效。
/// - 直连与 WebVPN 各自使用独立 CookieJar，绝不把直连 JSESSIONID 复制到
///   WebVPN 会话。
/// - 全程绑定入口时的账号 + [ZhengfangAuth.sessionRevision] +
///   [UnifiedAuthService.sessionRevision]，每个 await 后复核；身份变化即作废。
/// - 取消 / 总预算通过 [CancelToken] 真实取消底层传输，而不是只丢弃 Future。
/// - 不自动提交凭据、不 OCR、不登录。
class AcademicWebEntryPreparer {
  AcademicWebEntryPreparer({
    AcademicModeResolver? modeResolver,
    AcademicGatewaySessionEnsurer? gatewaySessionEnsurer,
    AcademicSessionProber? academicSessionProber,
    AcademicCookieSyncer? cookieSyncer,
    AcademicHeaderBuilder? headerBuilder,
  }) : _modeResolver = modeResolver ?? _defaultModeResolver,
       _gatewaySessionEnsurer =
           gatewaySessionEnsurer ?? _defaultGatewaySessionEnsurer,
       _academicSessionProber =
           academicSessionProber ?? _defaultAcademicSessionProber,
       _cookieSyncer = cookieSyncer ?? _defaultCookieSyncer,
       _headerBuilder = headerBuilder ?? _defaultHeaderBuilder;

  static final AcademicWebEntryPreparer instance = AcademicWebEntryPreparer();

  static const String trustedOrigin = 'https://jwzx.zjxu.edu.cn';
  static const String trustedEntryPath = '/jwglxt/xtgl/index_initMenu.html';
  static const Set<String> trustedJsdmValues = {'xs', 'query'};
  static const Duration defaultTotalBudget = Duration(seconds: 20);

  final AcademicModeResolver _modeResolver;
  final AcademicGatewaySessionEnsurer _gatewaySessionEnsurer;
  final AcademicSessionProber _academicSessionProber;
  final AcademicCookieSyncer _cookieSyncer;
  final AcademicHeaderBuilder _headerBuilder;

  /// 构造受信入口 URL；`jsdm` 不在白名单时返回 null。
  static String? trustedEntryUrl({String jsdm = 'xs'}) {
    final normalized = jsdm.trim().toLowerCase();
    if (!trustedJsdmValues.contains(normalized)) return null;
    return Uri.https('jwzx.zjxu.edu.cn', trustedEntryPath, {
      'jsdm': normalized,
    }).toString();
  }

  /// 严格校验是否为受信入口：https + 精确 origin + 精确 path + 仅 `jsdm`
  /// 且值在白名单、无 userInfo / fragment / ticket / 其它 query。
  static bool isTrustedEntryUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return false;
    if (uri.scheme.toLowerCase() != 'https') return false;
    if (uri.host.toLowerCase() != 'jwzx.zjxu.edu.cn') return false;
    if (uri.userInfo.isNotEmpty) return false;
    if (uri.hasPort && uri.port != 443) return false;
    if (uri.path != trustedEntryPath) return false;
    if (uri.hasFragment) return false;

    final params = uri.queryParametersAll;
    if (params.length != 1) return false;
    final jsdm = params['jsdm'];
    if (jsdm == null || jsdm.length != 1) return false;
    return trustedJsdmValues.contains(jsdm.first.trim().toLowerCase());
  }

  /// 准备受信教务入口。
  ///
  /// [forceWebVpn] 为 true 时跳过直连偏好（用于 WebView 已证实直连
  /// `ERR_CONNECTION_CLOSED` 等场景），一律走 WebVPN。
  Future<AcademicWebEntryResult> prepare({
    String jsdm = 'xs',
    bool forceWebVpn = false,
    CancelToken? cancelToken,
    Duration totalBudget = defaultTotalBudget,
  }) async {
    final targetUrl = trustedEntryUrl(jsdm: jsdm);
    if (targetUrl == null) {
      return const AcademicWebEntryDenied('非受信教务入口');
    }

    final budget = _EntryBudget(cancelToken ?? CancelToken(), totalBudget);
    try {
      return await _prepare(
        targetUrl: targetUrl,
        forceWebVpn: forceWebVpn,
        budget: budget,
      );
    } finally {
      budget.dispose();
    }
  }

  Future<AcademicWebEntryResult> _prepare({
    required String targetUrl,
    required bool forceWebVpn,
    required _EntryBudget budget,
  }) async {
    final zhengfang = ZhengfangAuth.instance;
    final unified = UnifiedAuthService.instance;

    // ENTRY：同时捕获两个认证域的账号 + revision。
    final zfRevision = zhengfang.sessionRevision;
    final zfAccount = zhengfang.currentStudentId?.trim() ?? '';
    final uaRevision = unified.sessionRevision;
    final uaAccount = unified.currentAccount?.trim() ?? '';

    bool identityCurrent() {
      final zfCurrent =
          zhengfang.sessionRevision == zfRevision &&
          (zhengfang.currentStudentId?.trim() ?? '') == zfAccount;
      final uaCurrent =
          unified.sessionRevision == uaRevision &&
          (unified.currentAccount?.trim() ?? '') == uaAccount;
      return zfCurrent && uaCurrent;
    }

    AcademicWebEntryResult? afterAwait() {
      if (!identityCurrent()) {
        budget.cancel('identity changed during academic entry preparation');
        return const AcademicWebEntryStale(
          AcademicWebEntryStaleReason.identityChanged,
        );
      }
      if (budget.exhausted) {
        return const AcademicWebEntryStale(
          AcademicWebEntryStaleReason.cancelled,
        );
      }
      return null;
    }

    try {
      await DioClient.instance.ensureInitialized();
    } catch (error, stackTrace) {
      AppLogger.instance.auth(
        LogLevel.warn,
        '教务 H5 入口准备：网络层初始化失败',
        error: error,
        stackTrace: stackTrace,
      );
      return const AcademicWebEntryUnavailable('网络层初始化失败');
    }
    final initGuard = afterAwait();
    if (initGuard != null) return initGuard;

    // 1) 选路：默认按目标 origin 判定，forceWebVpn 跳过直连偏好。
    final ZhengfangMode selectedMode;
    if (forceWebVpn) {
      selectedMode = ZhengfangMode.webVpn;
    } else {
      ZhengfangMode? resolved;
      try {
        resolved = await _modeResolver(targetUrl);
      } catch (error, stackTrace) {
        AppLogger.instance.auth(
          LogLevel.warn,
          '教务 H5 入口准备：连接模式判定失败',
          error: error,
          stackTrace: stackTrace,
        );
        return const AcademicWebEntryUnavailable('连接模式判定失败');
      }
      final modeGuard = afterAwait();
      if (modeGuard != null) return modeGuard;
      if (resolved == null) {
        return const AcademicWebEntryUnavailable('直连与 WebVPN 均不可达');
      }
      selectedMode = resolved;
    }

    final String finalUrl;
    if (selectedMode == ZhengfangMode.direct) {
      // 直连无需 CAS 网关；只用当前内存中的教务 owner。
      if (!zhengfang.isLoggedIn) {
        return const AcademicWebEntryNeedsAcademicLogin();
      }
      final probe = await _probe(
        mode: ZhengfangMode.direct,
        requestUrl: targetUrl,
        budget: budget,
      );
      final probeGuard = afterAwait();
      if (probeGuard != null) return probeGuard;
      final probeResult = _interpretProbe(probe);
      if (probeResult != null) return probeResult;
      finalUrl = targetUrl;
    } else {
      // 校外 WebVPN：网关需要统一认证 CAS，只用当前内存 owner，不冷恢复。
      if (!unified.isLoggedIn) {
        return const AcademicWebEntryNeedsUnifiedLogin();
      }

      try {
        await _gatewaySessionEnsurer(budget.token, budget.deadline);
      } on CasAuthExpiredException {
        final gatewayGuard = afterAwait();
        if (gatewayGuard != null) return gatewayGuard;
        return const AcademicWebEntryNeedsUnifiedLogin();
      } on DioException catch (error) {
        final gatewayGuard = afterAwait();
        if (gatewayGuard != null) return gatewayGuard;
        AppLogger.instance.auth(
          LogLevel.warn,
          '教务 H5 入口准备：WebVPN 网关会话失败 ${error.type}',
        );
        return const AcademicWebEntryUnavailable('WebVPN 网关会话校验失败');
      } catch (error, stackTrace) {
        final gatewayGuard = afterAwait();
        if (gatewayGuard != null) return gatewayGuard;
        AppLogger.instance.auth(
          LogLevel.warn,
          '教务 H5 入口准备：WebVPN 网关会话异常',
          error: error,
          stackTrace: stackTrace,
        );
        return const AcademicWebEntryUnavailable('WebVPN 网关会话校验失败');
      }
      final gatewayGuard = afterAwait();
      if (gatewayGuard != null) return gatewayGuard;

      // 网关就绪不代表教务业务会话就绪：必须单独验证。
      if (!zhengfang.isLoggedIn) {
        return const AcademicWebEntryNeedsAcademicLogin();
      }
      final proxyUrl = zhengfang.buildWebVpnProxyUrl(targetUrl);
      if (Uri.tryParse(proxyUrl)?.host.toLowerCase() != 'webvpn.zjxu.edu.cn') {
        return const AcademicWebEntryUnavailable('目标无法构造 WebVPN 代理地址');
      }
      final probe = await _probe(
        mode: ZhengfangMode.webVpn,
        requestUrl: proxyUrl,
        budget: budget,
      );
      final probeGuard = afterAwait();
      if (probeGuard != null) return probeGuard;
      final probeResult = _interpretProbe(probe);
      if (probeResult != null) return probeResult;
      finalUrl = proxyUrl;
    }

    // 2) 按本次选中的 mode 同步 Cookie（不读 / 不写全局 mode）。
    try {
      await _cookieSyncer(
        selectedMode,
        () => identityCurrent() && !budget.exhausted,
      );
    } catch (error, stackTrace) {
      AppLogger.instance.auth(
        LogLevel.warn,
        '教务 H5 入口准备：Cookie 同步失败',
        error: error,
        stackTrace: stackTrace,
      );
      final cookieGuard = afterAwait();
      if (cookieGuard != null) return cookieGuard;
      return const AcademicWebEntryUnavailable('Cookie 同步失败');
    }
    final cookieGuard = afterAwait();
    if (cookieGuard != null) return cookieGuard;

    // 3) 生成 WebView 初始请求头。
    final Map<String, String> headers;
    try {
      headers = await _headerBuilder(selectedMode, finalUrl);
    } catch (error, stackTrace) {
      AppLogger.instance.auth(
        LogLevel.warn,
        '教务 H5 入口准备：请求头构造失败',
        error: error,
        stackTrace: stackTrace,
      );
      final headerGuard = afterAwait();
      if (headerGuard != null) return headerGuard;
      return const AcademicWebEntryUnavailable('请求头构造失败');
    }
    final headerGuard = afterAwait();
    if (headerGuard != null) return headerGuard;

    AppLogger.instance.auth(
      LogLevel.info,
      '教务 H5 入口就绪 [${selectedMode == ZhengfangMode.webVpn ? 'WebVPN' : '直连'}]',
    );
    return AcademicWebEntryReady(
      url: finalUrl,
      headers: headers,
      selectedMode: selectedMode,
    );
  }

  /// 把 fail-closed 探测结果映射为类型化准备结果；返回 null 表示可继续。
  AcademicWebEntryResult? _interpretProbe(AcademicEntrySessionStatus probe) {
    switch (probe) {
      case AcademicEntrySessionStatus.authenticated:
        return null;
      case AcademicEntrySessionStatus.academicLoginRequired:
        return const AcademicWebEntryNeedsAcademicLogin();
      case AcademicEntrySessionStatus.unifiedLoginRequired:
        return const AcademicWebEntryNeedsUnifiedLogin();
      case AcademicEntrySessionStatus.unknown:
        return const AcademicWebEntryUnavailable('无法确认教务会话状态');
    }
  }

  Future<AcademicEntrySessionStatus> _probe({
    required ZhengfangMode mode,
    required String requestUrl,
    required _EntryBudget budget,
  }) async {
    try {
      return await _academicSessionProber(mode, requestUrl, budget.token);
    } catch (error, stackTrace) {
      AppLogger.instance.auth(
        LogLevel.warn,
        '教务 H5 入口准备：业务会话探测异常',
        error: error,
        stackTrace: stackTrace,
      );
      return AcademicEntrySessionStatus.unknown;
    }
  }

  // ── 生产默认实现 ────────────────────────────────────────────────────────

  static Future<ZhengfangMode?> _defaultModeResolver(String targetUrl) =>
      ConnectModeResolver.instance.resolve(targetUrl: targetUrl);

  /// 复用 CAS broker 的真实重定向 / 回调链建立 WebVPN 网关会话；目标
  /// URL 是注册的 [CasService.webVpnGateway]，不是业务资源，也不伪造 ticket。
  static Future<void> _defaultGatewaySessionEnsurer(
    CancelToken token,
    DateTime deadline,
  ) async {
    await CasAuthBroker.getResource(
      CasService.webVpnGateway.serviceUrl,
      cancelToken: token,
      deadline: deadline,
      needsLogin: webVpnGatewayResponseNeedsLogin,
    );
  }

  static Future<AcademicEntrySessionStatus> _defaultAcademicSessionProber(
    ZhengfangMode mode,
    String requestUrl,
    CancelToken token,
  ) {
    return ZhengfangAuth.instance.probeTrustedEntrySession(
      mode: mode,
      requestUrl: requestUrl,
      cancelToken: token,
    );
  }

  static Future<void> _defaultCookieSyncer(
    ZhengfangMode mode,
    bool Function() isIdentityCurrent,
  ) {
    return ZhengfangAuth.instance.syncCookiesToWebViewForMode(
      mode,
      isIdentityCurrent: isIdentityCurrent,
      // 教务 H5 入口准备要求 fail closed：部分 / 失败 / 缺失 Cookie 一律
      // 抛错，绝不能据此判定 Ready。
      strict: true,
    );
  }

  static Future<Map<String, String>> _defaultHeaderBuilder(
    ZhengfangMode mode,
    String resolvedUrl,
  ) {
    return ZhengfangAuth.instance.buildWebViewHeadersForMode(
      mode: mode,
      resolvedUrl: resolvedUrl,
    );
  }
}

/// 单次准备的总预算 + 取消令牌。预算到期会真实 cancel 底层传输。
class _EntryBudget {
  _EntryBudget(this.token, this.totalBudget) {
    if (token.isCancelled) {
      _taken = true;
      return;
    }
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      _taken = true;
      token.cancel('academic entry budget exceeded');
      return;
    }
    _timer = Timer(remaining, () {
      _taken = true;
      if (!token.isCancelled) {
        token.cancel('academic entry budget exceeded');
      }
    });
  }

  final CancelToken token;
  final Duration totalBudget;
  final DateTime startedAt = DateTime.now();
  Timer? _timer;
  bool _taken = false;

  /// 本次准备的总截止时间；贯穿所有网络跳转。
  DateTime get deadline => startedAt.add(totalBudget);

  /// 是否已取消 / 超预算。
  bool get taken => _taken || token.isCancelled;
  bool get exhausted => taken || DateTime.now().isAfter(deadline);

  void cancel(String reason) {
    _taken = true;
    if (!token.isCancelled) token.cancel(reason);
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
