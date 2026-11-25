import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:cookie_jar/cookie_jar.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:pointycastle/export.dart';

import '../logging/app_logger.dart';
import '../network/cancel_token_x.dart';
import '../network/dio_client.dart';
import '../network/network_settings.dart';
import '../network/proxy_fallback.dart';
import '../network/proxy_mode.dart';
import '../network/route_failure.dart';
import '../network/route_gate.dart';
import 'cas_auth_broker.dart';
import 'cas_routed_access.dart';
import 'auth_failure.dart';
import 'auth_operation_coordinator.dart';
import 'auth_recovery_state_store.dart';
import 'auth_session_persistence.dart';
import 'captcha_challenge.dart';
import 'credential_store.dart';
import 'connect_mode_resolver.dart';
import 'isolated_auth_session.dart';
import 'login_page_detection.dart';
import 'unified_auth.dart';

// 登录页 URL / HTML 判定的唯一实现在 login_page_detection.dart；这里 re-export
// 以保持既有 `import 'zhengfang_auth.dart'` 调用点不变。
export 'login_page_detection.dart'
    show
        isZhengfangGatewayLoginUrl,
        isZhengfangLoginEntryUrl,
        looksLikeLoginExpiredMessage,
        looksLikeZhengfangLoginHtml;

part 'zhengfang_auth_webvpn.dart';
part 'zhengfang_auth_direct.dart';
part 'zhengfang_auth_challenge.dart';

bool isZhengfangAuthenticatedUrl(String currentUrl) {
  final normalizedUrl = currentUrl.trim().toLowerCase();
  if (normalizedUrl.isEmpty) return false;
  return normalizedUrl.contains('index_initmenu') ||
      normalizedUrl.contains('index_cxyhxxindex') ||
      normalizedUrl.contains('/xtgl/index');
}

/// 教务系统连接模式
enum ZhengfangMode {
  /// 直连教务系统 (校园网)
  direct,

  /// 通过 WebVPN 连接 (非校园网)
  webVpn,
}

sealed class LoginResult {
  const LoginResult();
}

class LoginSuccess extends LoginResult {
  const LoginSuccess({this.receipt});

  /// 自动恢复路径下**真实**提交产出的 typed receipt；人工登录或已有可信
  /// 会话短路成功均为 null（短路绝不在自动路径伪造提交）。
  final SessionCommitResult? receipt;
}

class LoginFailure extends LoginResult {
  final String message;

  /// 失败分类；默认 [AuthFailureKind.unknown]，不得被当作密码错误或自动重试。
  final AuthFailureKind kind;

  LoginFailure(this.message, {this.kind = AuthFailureKind.unknown});
}

/// Thrown when captcha loading fails due to network or server issues.
class CaptchaException implements Exception {
  final String message;
  CaptchaException(this.message);

  @override
  String toString() => message;
}

/// 教务验证码事务私有快照：绑定**独立网络会话**（isolated jar/dio）+ 表单
/// 上下文（csrftoken/模式），提交时只使用它，禁止重新 fetch。
class _ZhengfangChallengeContext {
  const _ZhengfangChallengeContext({
    required this.mode,
    required this.baseUrl,
    required this.loginPageUrl,
    required this.origin,
    required this.csrfToken,
    required this.timestampMs,
    required this.session,
    required this.expectedEpoch,
    this.indicatesLoggedIn = false,
  });

  /// 本事务**显式**绑定的连接模式：请求、cookie 源与提交目标 jar 都按它选，
  /// 不读全局 [ZhengfangAuth.mode]；提交成功后全局模式收敛到它。
  final ZhengfangMode mode;
  final String baseUrl;
  final String loginPageUrl;
  final String origin;
  final String csrfToken;
  final int timestampMs;
  final IsolatedAuthSession session;

  /// prepare 时捕获的持久会话 epoch；提交必须使用它做条件提交，
  /// **不得**在提交时重新读取当前 epoch。
  final int expectedEpoch;

  /// 登录入口直接跳首页（已有网络会话，未绑定身份）。只属于本事务，
  /// 不再是跨事务共享的全局标志。
  final bool indicatesLoggedIn;
}

class ZhengfangAuth extends ChangeNotifier {
  ZhengfangAuth._();
  static final ZhengfangAuth instance = ZhengfangAuth._();

  static const _directOrigin = 'https://jwzx.zjxu.edu.cn';
  static const _directLoginPath = '/jwglxt/xtgl/login_slogin.html';
  static const _directBase = 'https://jwzx.zjxu.edu.cn/jwglxt';

  static const _webVpnBase = 'https://webvpn.zjxu.edu.cn';
  static const webVpnGatewayServiceUrl =
      'https://webvpn.zjxu.edu.cn/login?cas_login=true';
  static const _portalPrefix =
      '/https/77726476706e69737468656265737421fae05b84692a62486b468ca88d1b203b';
  static const _webVpnJwglxtPrefix = '$_portalPrefix/jwglxt';
  static const _webVpnLoginPath =
      '$_portalPrefix/jwglxt/xtgl/login_slogin.html';
  static const _webVpnHostPrefixes = <String, String>{
    'jwzx.zjxu.edu.cn':
        '77726476706e69737468656265737421fae05b84692a62486b468ca88d1b203b',
    'twdekt.zjxu.edu.cn':
        '77726476706e69737468656265737421e4e045992c24264a74109ce29d51367bc8e6',
    'libapp.zjxu.edu.cn':
        '77726476706e69737468656265737421fcfe439d3720264a74109ce29d51367b2b47',
    'zhx.zjxu.edu.cn':
        '77726476706e69737468656265737421eaff59d23d3a7045300d8db9d6562d',
    'newca.zjxu.edu.cn':
        '77726476706e69737468656265737421fef2569f267e725a661dc7a99c406d362a',
    'sjjx.zjxu.edu.cn':
        '77726476706e69737468656265737421e3fd4b84692a62486b468ca88d1b203b',
    'jkjy.zjxu.edu.cn':
        '77726476706e69737468656265737421fafc4b85692a62486b468ca88d1b203b',
    'mobilehall.zjxu.edu.cn': '77726476706e69737468656265737421fdf843952b3560517204c7b6924d367bdd166b13aa07',
    'ecard.zjxu.edu.cn':
        '77726476706e69737468656265737421f5f4408e237e725a661dc7a99c406d363e',
  };

  /// WebVPN CAS 登录路径
  static const _webVpnCasPath = '/login';
  static const webVpnGatewayLoginUrl = '$_webVpnBase$_webVpnCasPath';

  ZhengfangMode _mode = ZhengfangMode.direct;
  ZhengfangMode get mode => _mode;

  bool _sessionActive = false;
  bool _webVpnSessionActive = false;
  String? currentStudentId;

  /// 身份修订号：login/logout/切账号/恢复时递增，供调用方丢弃过期结果。
  int _sessionRevision = 0;

  /// 对外只读身份修订号，供其他模块判定账号/epoch 是否变化；
  /// 不改变 [notifyListeners] 契约。
  int get sessionRevision => _sessionRevision;

  /// 验证码事务分两条互不干扰的通道：人工（登录页）与自动恢复（OCR）。
  /// 过去共用一个单槽，自动恢复 arm 会顶掉用户正在看的验证码，表现为
  /// 「验证码正常显示、提交却失败」。身份变化/登出仍同时失效两条通道。
  final CaptchaChallengeStore<_ZhengfangChallengeContext> _captchaChallenges =
      CaptchaChallengeStore<_ZhengfangChallengeContext>();
  final CaptchaChallengeStore<_ZhengfangChallengeContext>
  _automaticCaptchaChallenges =
      CaptchaChallengeStore<_ZhengfangChallengeContext>();

  CaptchaChallengeStore<_ZhengfangChallengeContext> _challengeStore({
    required bool automatic,
  }) => automatic ? _automaticCaptchaChallenges : _captchaChallenges;

  void _invalidateAllChallenges() {
    _captchaChallenges.invalidate();
    _automaticCaptchaChallenges.invalidate();
  }

  void _touchSessionRevision() => _sessionRevision++;

  /// 同状态不 bump、不 notify；空白身份不视为已登录。
  ///
  /// [forceRevision] 供「成功提交了一次新会话」的调用方使用：即使 active/account
  /// 与当前完全相同（同账号重登），也必须推进 [sessionRevision]，让此前捕获旧
  /// revision 的在途结果（含 guard 的旧失效响应）失效，绝不允许旧响应进入新会话。
  /// 普通重复状态通知保持默认 false（不 bump）。
  void _applySessionIdentity({
    required bool active,
    String? studentId,
    bool forceRevision = false,
  }) {
    final trimmed = studentId?.trim();
    final nextActive = active && trimmed != null && trimmed.isNotEmpty;
    final nextStudentId = nextActive ? trimmed : null;
    final unchanged =
        _sessionActive == nextActive && currentStudentId == nextStudentId;
    if (unchanged && !forceRevision) {
      return;
    }
    _touchSessionRevision();
    _sessionActive = nextActive;
    currentStudentId = nextStudentId;
    // 身份变化：已备好的验证码事务（两条通道）立即失效。
    _invalidateAllChallenges();
  }

  Dio get _dio => _mode == ZhengfangMode.webVpn
      ? DioClient.instance.unifiedAuthDio
      : DioClient.instance.dio;

  /// 当前连接模式对应的教务请求客户端。
  ///
  /// WebVPN 模式必须复用统一认证 CookieJar，否则业务接口虽然请求了
  /// WebVPN URL，却不会携带网关 ticket。
  Dio get academicDio => _dio;

  Dio academicDioFor(ZhengfangMode mode) => _dioFor(mode);
  PersistCookieJar get _cookieJar => DioClient.instance.zhengfangCookieJar;
  PersistCookieJar get _webVpnCookieJar =>
      DioClient.instance.unifiedAuthCookieJar;

  Dio _dioFor(ZhengfangMode mode) => mode == ZhengfangMode.webVpn
      ? DioClient.instance.unifiedAuthDio
      : DioClient.instance.dio;

  PersistCookieJar _cookieJarFor(ZhengfangMode mode) =>
      mode == ZhengfangMode.webVpn ? _webVpnCookieJar : _cookieJar;

  void _notifyAuthListeners() => notifyListeners();

  Future<Response<T>> _sendWithProxyFallback<T>({
    required String label,
    required Future<Response<T>> Function(Dio dio, CancelToken token) request,
    CancelToken? cancelToken,
    ZhengfangMode? mode,
  }) {
    final effectiveMode = mode ?? _mode;
    return sendWithSystemProxyFallback<T>(
      primary: _dioFor(effectiveMode),
      createFallback: () => createSystemProxyFallbackDio(
        template: _dioFor(effectiveMode),
        jar: _cookieJarFor(effectiveMode),
      ),
      label: label,
      request: request,
      cancelToken: cancelToken,
    );
  }

  String _baseUrlFor(ZhengfangMode mode) => mode == ZhengfangMode.direct
      ? _directBase
      : '$_webVpnBase$_webVpnJwglxtPrefix';

  String _loginPageUrlFor(ZhengfangMode mode) => mode == ZhengfangMode.direct
      ? '$_directOrigin$_directLoginPath'
      : '$_webVpnBase$_webVpnLoginPath';

  String _originFor(ZhengfangMode mode) =>
      mode == ZhengfangMode.direct ? _directOrigin : _webVpnBase;

  String get _baseUrl => _baseUrlFor(_mode);

  String get _loginPageUrl => _loginPageUrlFor(_mode);

  String get academicServiceUrl => buildPortalUrl(
    '/xtgl/index_initMenu.html',
    queryParameters: {'jsdm': 'xs'},
  );

  static const directAcademicServiceUrl =
      'https://jwzx.zjxu.edu.cn/jwglxt/xtgl/index_initMenu.html?jsdm=xs';

  // Gateway setup is a prerequisite of the business gate and of automatic
  // login. Its own queue keeps prerequisite calls from waiting on themselves.
  static final _gatewayRoutes = RouteGate();

  String buildPortalUrl(
    String path, {
    Map<String, dynamic>? queryParameters,
    ZhengfangMode? mode,
  }) {
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    final uri = Uri.parse('${_baseUrlFor(mode ?? _mode)}$normalizedPath');
    if (queryParameters == null || queryParameters.isEmpty) {
      return uri.toString();
    }
    return uri
        .replace(
          queryParameters: queryParameters.map(
            (key, value) => MapEntry(key, value.toString()),
          ),
        )
        .toString();
  }

  String resolvePortalUrl(String urlOrPath) {
    final raw = urlOrPath.trim();
    if (raw.isEmpty) return raw;

    final uri = Uri.tryParse(raw);
    if (uri == null) return buildPortalUrl(raw);
    if (!uri.hasScheme) {
      return buildPortalUrl(uri.path, queryParameters: uri.queryParameters);
    }
    if (_mode != ZhengfangMode.webVpn ||
        uri.host.toLowerCase() != 'jwzx.zjxu.edu.cn') {
      return raw;
    }

    return Uri.parse('$_webVpnBase$_portalPrefix${uri.path}')
        .replace(
          queryParameters: uri.queryParameters.isEmpty
              ? null
              : uri.queryParameters,
        )
        .toString();
  }

  String buildWebVpnProxyUrl(String rawUrl) {
    final url = rawUrl.trim();
    if (url.isEmpty) return url;

    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return url;
    }
    if (uri.host.toLowerCase() == 'webvpn.zjxu.edu.cn') {
      return url;
    }

    final protocol = uri.scheme.toLowerCase();
    final portSegment = uri.hasPort ? '-${uri.port}' : '';
    final encryptedHost = _webVpnHostPrefixes[uri.host.toLowerCase()];
    if (encryptedHost == null) {
      return url;
    }
    final query = uri.hasQuery ? '?${uri.query}' : '';
    final fragment = uri.hasFragment ? '#${uri.fragment}' : '';

    return '$_webVpnBase/$protocol$portSegment/$encryptedHost${uri.path}$query$fragment';
  }

  // ── RSA encryption ──────────────────────────────────────────────────────────

  String _encryptPassword(
    String password,
    String modulusB64,
    String exponentB64,
  ) {
    BigInt decodeBigInt(String b64) {
      final bytes = base64.decode(b64);
      return bytes.fold(BigInt.zero, (acc, b) => (acc << 8) | BigInt.from(b));
    }

    final modulus = decodeBigInt(modulusB64);
    final exponent = decodeBigInt(exponentB64);
    final publicKey = RSAPublicKey(modulus, exponent);

    final cipher = PKCS1Encoding(RSAEngine())
      ..init(true, PublicKeyParameter<RSAPublicKey>(publicKey));

    final input = Uint8List.fromList(utf8.encode(password));
    final encrypted = cipher.process(input);
    return base64.encode(encrypted);
  }

  // ── Image validation ─────────────────────────────────────────────────────────

  static bool _isValidImage(Uint8List data) {
    if (data.length < 4) return false;
    if (data[0] == 0x89 &&
        data[1] == 0x50 &&
        data[2] == 0x4E &&
        data[3] == 0x47) {
      return true;
    }
    if (data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF) return true;
    if (data[0] == 0x47 && data[1] == 0x49 && data[2] == 0x46) return true;
    return false;
  }

  // ── 连通性检测 ────────────────────────────────────────────────────────────────

  /// 测试直连教务系统是否可达
  static Future<bool> checkDirectReachable() async {
    try {
      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 3),
          receiveTimeout: const Duration(seconds: 3),
          followRedirects: false,
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      applyProxyModeToDio(
        dio,
        ignoreSystemProxy: NetworkSettings.instance.ignoreSystemProxy.value,
      );
      final resp = await dio.get<String>('$_directOrigin$_directLoginPath');
      final statusCode = resp.statusCode ?? 0;

      // 检查是否有重定向到 WebVPN
      final location = resp.headers.value('location') ?? '';
      final isRedirectedToWebVpn = location.contains('webvpn.zjxu.edu.cn');

      if (isRedirectedToWebVpn) {
        AppLogger.instance.auth(
          LogLevel.warn,
          '教务系统直连: 被重定向到 WebVPN，需要 WebVPN 登录',
        );
        return false;
      }

      final reachable =
          statusCode < 400 && statusCode != 302 && statusCode != 303;
      AppLogger.instance.auth(
        LogLevel.info,
        '教务系统直连: ${reachable ? "可达" : "不可达"} ($statusCode)',
      );
      return reachable;
    } catch (e) {
      AppLogger.instance.auth(LogLevel.warn, '教务系统直连不可达: $e');
      return false;
    }
  }

  /// 测试 WebVPN 是否可达
  static Future<bool> checkWebVpnReachable() async =>
      await probeWebVpnFailure() == null;

  static Future<RouteFailureReason?> probeWebVpnFailure() async {
    final token = CancelToken();
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 6),
        receiveTimeout: const Duration(seconds: 6),
        followRedirects: false,
        validateStatus: (s) => s != null && s < 600,
      ),
    );
    applyProxyModeToDio(
      dio,
      ignoreSystemProxy: NetworkSettings.instance.ignoreSystemProxy.value,
    );
    try {
      final resp = await dio
          .get<String>(webVpnGatewayLoginUrl, cancelToken: token)
          .timeout(
            const Duration(seconds: 8),
            onTimeout: () {
              token.cancel('WebVPN reachability probe timed out');
              throw TimeoutException('WebVPN reachability probe timed out');
            },
          );
      final uri = resp.realUri;
      AppLogger.instance.auth(
        LogLevel.info,
        'WebVPN 连通性 status=${resp.statusCode} at ${uri.host}${uri.path}',
      );
      return (resp.statusCode ?? 0) < 400
          ? null
          : RouteFailureReason.webVpnGatewayFailed;
    } catch (e) {
      AppLogger.instance.auth(
        LogLevel.warn,
        'WebVPN 不可达 webvpn.zjxu.edu.cn: ${e is DioException ? e.type : e.runtimeType}',
      );
      return RouteFailureReason.connectionFailed;
    } finally {
      dio.close(force: true);
    }
  }

  // Remaining ZhengfangAuth members are split into part files to keep source files under 1000 lines.
}
