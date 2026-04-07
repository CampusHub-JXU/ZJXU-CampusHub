import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:pointycastle/export.dart';

import '../logging/app_logger.dart';
import '../network/dio_client.dart';

/// 教务系统连接模式
enum ZhengfangMode {
  /// 直连教务系统 (校园网)
  direct,

  /// 通过 WebVPN 连接 (非校园网)
  webVpn,
}

sealed class LoginResult {}

class LoginSuccess extends LoginResult {}

class LoginFailure extends LoginResult {
  final String message;
  LoginFailure(this.message);
}

/// Thrown when captcha loading fails due to network or server issues.
class CaptchaException implements Exception {
  final String message;
  CaptchaException(this.message);

  @override
  String toString() => message;
}

/// WebVPN CAS 认证结果
sealed class WebVpnCasResult {}

class WebVpnCasSuccess extends WebVpnCasResult {}

class WebVpnCasFailure extends WebVpnCasResult {
  WebVpnCasFailure(this.message);
  final String message;
}

class ZhengfangAuth {
  ZhengfangAuth._();
  static final ZhengfangAuth instance = ZhengfangAuth._();

  static const _directOrigin = 'https://jwzx.zjxu.edu.cn';
  static const _directLoginPath = '/jwglxt/xtgl/login_slogin.html';
  static const _directBase = 'https://jwzx.zjxu.edu.cn/jwglxt';

  static const _webVpnBase = 'https://webvpn.zjxu.edu.cn';
  static const _portalPrefix =
      '/http/77726476706e69737468656265737421fae05b84692a62486b468ca88d1b203b';
  static const _webVpnJwglxtPrefix = '$_portalPrefix/jwglxt';
  static const _webVpnLoginPath = '$_portalPrefix/jwglxt/xtgl/login_slogin.html';

  /// WebVPN CAS 登录路径
  static const _webVpnCasPath = '/login';

  final _cookieJar = DioClient.instance.cookieJar;
  String? _cachedCsrfToken;

  ZhengfangMode _mode = ZhengfangMode.direct;
  ZhengfangMode get mode => _mode;

  bool _sessionActive = false;
  String? currentStudentId;

  Dio get _dio => DioClient.instance.dio;

  String get _baseUrl =>
      _mode == ZhengfangMode.direct ? _directBase : '$_webVpnBase$_webVpnJwglxtPrefix';

  String get _loginPageUrl =>
      _mode == ZhengfangMode.direct ? '$_directOrigin$_directLoginPath' : _webVpnLoginPath;

  String get _origin =>
      _mode == ZhengfangMode.direct ? _directOrigin : _webVpnBase;

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
    if (data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4E && data[3] == 0x47) return true;
    if (data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF) return true;
    if (data[0] == 0x47 && data[1] == 0x49 && data[2] == 0x46) return true;
    return false;
  }

  // ── 连通性检测 ────────────────────────────────────────────────────────────────

  /// 测试直连教务系统是否可达
  static Future<bool> checkDirectReachable() async {
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 8),
        followRedirects: false,
        validateStatus: (s) => s != null && s < 500,
      ));
      AppLogger.instance.debug('正在测试教务系统直连...');
      final resp = await dio.get<String>('$_directOrigin$_directLoginPath');
      final reachable = resp.statusCode != null && resp.statusCode! < 400;
      AppLogger.instance.info('教务系统直连: ${reachable ? "可达" : "不可达"} (${resp.statusCode})');
      return reachable;
    } catch (e) {
      AppLogger.instance.info('教务系统直连不可达: $e');
      return false;
    }
  }

  /// 测试 WebVPN 是否可达
  static Future<bool> checkWebVpnReachable() async {
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 8),
        followRedirects: true,
        validateStatus: (s) => s != null && s < 500,
      ));
      AppLogger.instance.debug('正在测试 WebVPN 连通性...');
      final resp = await dio.get<String>('$_webVpnBase$_webVpnCasPath');
      AppLogger.instance.info('WebVPN 连通性: ${resp.statusCode}');
      return resp.statusCode != null && resp.statusCode! < 400;
    } catch (e) {
      AppLogger.instance.info('WebVPN 不可达: $e');
      return false;
    }
  }

  // ── WebVPN CAS 认证 (含验证码) ─────────────────────────────────────────────────

  String? _cachedCasExecution;
  String? _cachedCasLt;
  String? _cachedCasLoginUrl;  // 保存重定向后的 CAS 登录 URL

  /// 获取 WebVPN CAS 验证码
  Future<Uint8List> fetchWebVpnCasCaptcha() async {
    AppLogger.instance.debug('正在获取 WebVPN CAS 登录页面...');
    // WebVPN /login 会 302 重定向到 CAS 登录页面，需要跟随重定向
    final loginUri = '$_webVpnBase$_webVpnCasPath';
    final pageResp = await _dio.get<String>(
      loginUri,
      options: Options(
        responseType: ResponseType.plain,
        followRedirects: false,  // 手动处理重定向
        validateStatus: (s) => s != null && s < 400,
        headers: {'Referer': loginUri},
      ),
    );

    // 处理重定向，获取真实的 CAS 登录页面
    var casLoginUrl = pageResp.headers.value('location') ?? '';
    if (casLoginUrl.startsWith('/')) {
      casLoginUrl = '$_webVpnBase$casLoginUrl';
    }
    AppLogger.instance.debug('CAS 登录页面: $casLoginUrl');

    final casResp = await _dio.get<String>(
      casLoginUrl,
      options: Options(
        responseType: ResponseType.plain,
        headers: {'Referer': loginUri},
      ),
    );

    final html = casResp.data ?? '';
    _cachedCasExecution = _extractHiddenField(html, 'execution');
    _cachedCasLt = _extractHiddenField(html, 'lt');
    _cachedCasLoginUrl = casLoginUrl;  // 保存 CAS 登录 URL
    AppLogger.instance.debug('WebVPN CAS execution: ${_cachedCasExecution?.length ?? 0} 字符, lt: ${_cachedCasLt?.length ?? 0} 字符');

    final ts = DateTime.now().millisecondsSinceEpoch;
    // 验证码 URL：实际是 /cas/captcha.html，不是 /cas/login/captcha.html
    // 从 CAS 登录页面 path 提取 base 路径
    final casBaseUri = Uri.parse(casLoginUrl);
    final casPath = casBaseUri.path;
    // /cas/login -> /cas
    final casBasePath = casPath.substring(0, casPath.lastIndexOf('/cas/') + 4);
    final captchaUri = Uri(
      scheme: casBaseUri.scheme,
      host: casBaseUri.host,
      path: '$casBasePath/captcha.html',
      queryParameters: {'vpn-1': '', 't': ts.toString()},
    ).toString();
    AppLogger.instance.debug('正在获取 WebVPN CAS 验证码 from: $captchaUri');
    final resp = await _dio.get<List<int>>(
      captchaUri,
      options: Options(
        responseType: ResponseType.bytes,
        headers: {'Referer': casLoginUrl},
      ),
    );

    final contentType = resp.headers.value('content-type') ?? '';
    if (contentType.contains('text/html')) {
      throw CaptchaException('WebVPN 验证码加载失败，请稍后重试');
    }

    final bytes = resp.data;
    if (bytes == null || bytes.isEmpty) {
      throw CaptchaException('WebVPN 验证码数据为空，请重试');
    }

    final data = Uint8List.fromList(bytes);
    if (!_isValidImage(data)) {
      throw CaptchaException('WebVPN 验证码加载失败，请稍后重试');
    }

    AppLogger.instance.info('WebVPN CAS 验证码获取成功, ${data.length} 字节');
    return data;
  }

  /// WebVPN CAS 登录 (一卡通认证，含验证码)
  Future<WebVpnCasResult> loginWebVpnCas(
    String username,
    String password,
    String captcha,
  ) async {
    try {
      final execution = _cachedCasExecution;
      final lt = _cachedCasLt;
      if (execution == null || execution.isEmpty) {
        return WebVpnCasFailure('WebVPN 登录上下文缺失，请刷新验证码后重试');
      }

      AppLogger.instance.info('正在通过 WebVPN CAS 登录 (一卡通认证)...');
      final loginUri = _cachedCasLoginUrl ?? '$_webVpnBase$_webVpnCasPath';
      AppLogger.instance.debug('WebVPN CAS 登录参数: username=$username, veriyCode=$captcha, lt=${lt?.substring(0, 10)}..., execution=${execution.substring(0, 20)}...');
      final resp = await _dio.post<String>(
        loginUri,
        data: {
          'username': username,
          'password': password,
          'veriyCode': captcha,  // 注意：这里是 veriyCode 不是 captcha
          if (lt != null && lt.isNotEmpty) 'lt': lt,
          'execution': execution,
          '_eventId': 'submit',
        },
        options: Options(
          contentType: 'application/x-www-form-urlencoded',
          responseType: ResponseType.plain,
          followRedirects: true,
          validateStatus: (s) => s != null && s < 500,
          headers: {
            'Referer': loginUri,
            'Origin': _webVpnBase,
          },
        ),
      );

      final statusCode = resp.statusCode;
      final uri = resp.realUri.toString();
      AppLogger.instance.debug('WebVPN CAS 响应: $statusCode $uri');
      AppLogger.instance.debug('WebVPN CAS 响应 Body 前200字符: ${(resp.data ?? '').substring(0, resp.data!.length > 200 ? 200 : resp.data!.length)}');

      // 检查是否成功（不包含 login 或包含特定成功标识）
      final html = resp.data ?? '';
      if (statusCode == 200 && !uri.contains('login')) {
        _cachedCasExecution = null;
        _cachedCasLt = null;
        _cachedCasLoginUrl = null;
        AppLogger.instance.info('WebVPN CAS 认证成功，正在同步 Cookie...');
        await syncWebVpnCookiesToWebView();
        AppLogger.instance.info('WebVPN CAS 认证成功，Cookie 同步完成');
        return WebVpnCasSuccess();
      }

      // 登录失败，检查错误信息
      AppLogger.instance.debug('WebVPN CAS 登录失败，检查错误...');
      // 重新提取 execution 以备重试
      final newExec = _extractHiddenField(html, 'execution');
      if (newExec.isNotEmpty) _cachedCasExecution = newExec;

      // 检查错误消息
      final lowerHtml = html.toLowerCase();
      if (lowerHtml.contains('验证码')) {
        return WebVpnCasFailure('验证码错误或已过期，请刷新后重试');
      }
      if (lowerHtml.contains('密码错误') || lowerHtml.contains('用户名或密码错误')) {
        AppLogger.instance.info('WebVPN CAS 一卡通密码错误');
        return WebVpnCasFailure('一卡通账号或密码错误');
      }

      AppLogger.instance.info('WebVPN CAS 认证未知状态: $statusCode');
      return WebVpnCasFailure('WebVPN 登录失败，请检查账号密码和验证码');
    } on DioException catch (e) {
      AppLogger.instance.error('WebVPN CAS 网络异常: ${e.type} ${e.message}');
      return WebVpnCasFailure('网络异常: ${e.message}');
    } catch (e) {
      AppLogger.instance.error('WebVPN CAS 异常: $e');
      return WebVpnCasFailure('登录异常: $e');
    }
  }

  String _extractHiddenField(String html, String fieldName) {
    final pattern = RegExp(
      'name=["\']$fieldName["\'][^>]*value=["\']([^"\']+)["\']',
      caseSensitive: false,
    );
    return pattern.firstMatch(html)?.group(1)?.trim() ?? '';
  }

  /// 同步 WebVPN Cookie 到 WebView
  Future<void> syncWebVpnCookiesToWebView() async {
    if (_mode != ZhengfangMode.webVpn) return;

    final cookieManager = CookieManager.instance();
    final uris = [
      Uri.parse('$_webVpnBase/'),
      Uri.parse(_webVpnLoginPath),
      Uri.parse('$_webVpnBase$_webVpnJwglxtPrefix/'),
    ];

    for (final uri in uris) {
      try {
        final cookies = await _cookieJar.loadForRequest(uri);
        AppLogger.instance.debug('同步 WebVPN Cookie ${uri.host}: ${cookies.map((c) => c.name).join(', ')}');
        for (final cookie in cookies) {
          final domain = (cookie.domain ?? '').trim();
          await cookieManager.setCookie(
            url: WebUri('${uri.scheme}://${uri.host}/'),
            name: cookie.name,
            value: cookie.value,
            domain: domain.isNotEmpty ? domain : uri.host,
            path: (cookie.path ?? '').trim().isNotEmpty ? cookie.path!.trim() : '/',
            isSecure: cookie.secure,
            isHttpOnly: cookie.httpOnly,
            expiresDate: cookie.expires?.millisecondsSinceEpoch,
          );
        }
      } catch (e) {
        AppLogger.instance.error('同步 WebVPN Cookie 失败: $e');
      }
    }
  }

  // ── Public API ───────────────────────────────────────────────────────────────

  /// 设置连接模式
  void setMode(ZhengfangMode mode) {
    _mode = mode;
    AppLogger.instance.info('教务系统连接模式切换为: ${mode == ZhengfangMode.direct ? "直连" : "WebVPN"}');
  }

  Future<Uint8List> fetchCaptcha() async {
    await _refreshLoginContext();
    final ts = DateTime.now().millisecondsSinceEpoch;
    AppLogger.instance.debug('正在获取教务系统验证码 [${_mode == ZhengfangMode.direct ? "直连" : "WebVPN"}]...');
    final resp = await _dio.get<List<int>>(
      '$_baseUrl/kaptcha',
      queryParameters: {'time': ts},
      options: Options(
        responseType: ResponseType.bytes,
        headers: {'Referer': _loginPageUrl},
      ),
    );

    final contentType = resp.headers.value('content-type') ?? '';
    if (contentType.contains('text/html')) {
      AppLogger.instance.info('验证码返回 HTML，可能未在校园网环境');
      if (_mode == ZhengfangMode.direct) {
        throw CaptchaException('无法连接到教务系统，请确保在校园网环境或已连接VPN');
      } else {
        throw CaptchaException('WebVPN 认证已过期，请重新登录');
      }
    }

    final bytes = resp.data;
    if (bytes == null || bytes.isEmpty) {
      throw CaptchaException('验证码数据为空，请重试');
    }

    final data = Uint8List.fromList(bytes);

    if (!_isValidImage(data)) {
      AppLogger.instance.info('验证码数据非有效图片，可能未在校园网环境');
      if (_mode == ZhengfangMode.direct) {
        throw CaptchaException('无法连接到教务系统，请确保在校园网环境或已连接VPN');
      } else {
        throw CaptchaException('WebVPN 连接异常，请重试');
      }
    }

    AppLogger.instance.info('验证码获取成功, ${data.length} 字节');
    return data;
  }

  Future<LoginResult> login(
    String username,
    String password,
    String captcha,
  ) async {
    try {
      final ts = DateTime.now().millisecondsSinceEpoch;
      final csrftoken = await _ensureCsrfToken();
      if (csrftoken.isEmpty) {
        return LoginFailure('初始化登录参数失败，请刷新验证码后重试');
      }

      AppLogger.instance.debug('正在获取 RSA 公钥...');
      final keyResp = await _dio.get<Map<String, dynamic>>(
        '$_baseUrl/xtgl/login_getPublicKey.html',
        queryParameters: {'time': ts},
        options: Options(
          headers: {
            'Referer': _loginPageUrl,
            'X-Requested-With': 'XMLHttpRequest',
          },
        ),
      );
      final modulus = keyResp.data?['modulus'] as String?;
      final exponent = keyResp.data?['exponent'] as String?;
      if (modulus == null ||
          exponent == null ||
          modulus.isEmpty ||
          exponent.isEmpty) {
        return LoginFailure('获取登录公钥失败，请稍后重试');
      }
      AppLogger.instance.debug('公钥获取成功，正在加密密码...');

      final encryptedPwd = _encryptPassword(password, modulus, exponent);

      await _dio.post<void>(
        '$_baseUrl/xtgl/login_logoutAccount.html',
        options: Options(
          headers: {'Referer': _loginPageUrl, 'Origin': _origin},
        ),
      );

      AppLogger.instance.debug('正在发送教务系统登录请求...');
      final loginResp = await _dio.post<String>(
        '$_baseUrl/xtgl/login_slogin.html',
        queryParameters: {'time': ts},
        data: {
          'csrftoken': csrftoken,
          'language': 'zh_CN',
          'yhm': username,
          'mm': encryptedPwd,
          'yzm': captcha,
        },
        options: Options(
          contentType: 'application/x-www-form-urlencoded',
          followRedirects: false,
          responseType: ResponseType.plain,
          validateStatus: (s) => s != null && s < 400,
          headers: {'Referer': _loginPageUrl, 'Origin': _origin},
        ),
      );

      final location = loginResp.headers.value('location') ?? '';
      final html = loginResp.data ?? '';
      if (_isLoginSuccess(loginResp.statusCode, location, html)) {
        currentStudentId = username;
        _sessionActive = true;
        _cachedCsrfToken = null;
        AppLogger.instance.info('教务系统登录成功 [${_mode == ZhengfangMode.direct ? "直连" : "WebVPN"}]');
        return LoginSuccess();
      }

      final msg = _extractLoginFailureMessage(html);
      AppLogger.instance.info('教务系统登录失败: $msg');
      return LoginFailure(msg);
    } on DioException catch (e) {
      _cachedCsrfToken = null;
      AppLogger.instance.error('教务系统登录网络异常: ${e.type} ${e.message}');
      return LoginFailure('网络错误：${e.message}');
    } catch (e) {
      _cachedCsrfToken = null;
      return LoginFailure('登录异常：$e');
    }
  }

  bool get isLoggedIn => _sessionActive;

  void markLoggedIn() => _sessionActive = true;
  void markLoggedOut() {
    _sessionActive = false;
    currentStudentId = null;
  }

  Future<void> logout() async {
    try {
      await _dio.post<void>('$_baseUrl/xtgl/login_logoutAccount.html');
    } catch (_) {}
    await _cookieJar.deleteAll();
    _sessionActive = false;
    currentStudentId = null;
    _cachedCsrfToken = null;
  }

  Future<void> _refreshLoginContext() async {
    AppLogger.instance.debug('正在刷新教务系统登录上下文...');
    await _refreshCsrfToken();
  }

  Future<String> _ensureCsrfToken() async {
    final token = _cachedCsrfToken?.trim();
    if (token != null && token.isNotEmpty) return token;
    return _refreshCsrfToken();
  }

  Future<String> _refreshCsrfToken() async {
    AppLogger.instance.debug('正在获取 CSRF Token...');
    final pageResp = await _dio.get<String>(
      '$_baseUrl/xtgl/login_slogin.html',
      options: Options(
        responseType: ResponseType.plain,
        headers: {'Referer': _loginPageUrl},
      ),
    );
    final pageHtml = pageResp.data ?? '';
    final matchById = RegExp(
      r'''id=["']csrftoken["'][^>]*value=["']([^"']+)["']''',
    ).firstMatch(pageHtml);
    final matchByName = RegExp(
      r'''name=["']csrftoken["'][^>]*value=["']([^"']+)["']''',
    ).firstMatch(pageHtml);
    final token = (matchById?.group(1) ?? matchByName?.group(1) ?? '').trim();
    _cachedCsrfToken = token;
    if (token.isEmpty) {
      AppLogger.instance.info('CSRF Token 为空，可能连接异常');
    } else {
      AppLogger.instance.debug('CSRF Token 获取成功: ${token.length} 字符');
    }
    return token;
  }

  bool _isLoginSuccess(int? statusCode, String location, String html) {
    final normalizedLocation = location.toLowerCase();
    if (statusCode == 302 || statusCode == 303) {
      if (normalizedLocation.contains('login_slogin')) return false;
      if (normalizedLocation.contains('index_initmenu')) return true;
      if (normalizedLocation.contains('index_cxyhxxindex')) return true;
      if (normalizedLocation.contains('/xtgl/index')) return true;
      return normalizedLocation.isNotEmpty;
    }
    return html.contains('/xtgl/index_initMenu.html') ||
        html.contains('/xtgl/index_cxYhxxIndex.html');
  }

  String _extractLoginFailureMessage(String html) {
    final tipMatch = RegExp(
      r'''id=["']tips["'][^>]*>([\s\S]*?)</[^>]+>''',
      caseSensitive: false,
    ).firstMatch(html);
    if (tipMatch != null) {
      final message = _decodeHtmlEntities(
        (tipMatch.group(1) ?? '').replaceAll(RegExp(r'<[^>]+>'), '').trim(),
      );
      if (message.isNotEmpty) return message;
    }

    if (html.contains('验证码')) return '验证码错误或已过期，请刷新后重试';
    if (html.contains('用户名') || html.contains('密码')) return '用户名或密码错误';
    return '登录失败，请检查用户名、密码和验证码';
  }

  String _decodeHtmlEntities(String value) {
    return value
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&amp;', '&')
        .trim();
  }
}
