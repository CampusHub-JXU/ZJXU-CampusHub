import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:pointycastle/export.dart';

import '../network/dio_client.dart';

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

class ZhengfangAuth {
  ZhengfangAuth._();
  static final ZhengfangAuth instance = ZhengfangAuth._();

  static const _loginPath = '/xtgl/login_slogin.html';
  static const _loginPageUrl =
      'https://jwzx.zjxu.edu.cn/jwglxt/xtgl/login_slogin.html';
  static const _origin = 'https://jwzx.zjxu.edu.cn';

  final _dio = DioClient.instance.dio;
  final _cookieJar = DioClient.instance.cookieJar;
  String? _cachedCsrfToken;

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

  /// Check PNG (89 50 4E 47), JPEG (FF D8 FF), or GIF (47 49 46) magic bytes.
  static bool _isValidImage(Uint8List data) {
    if (data.length < 4) return false;
    // PNG
    if (data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4E && data[3] == 0x47) return true;
    // JPEG
    if (data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF) return true;
    // GIF
    if (data[0] == 0x47 && data[1] == 0x49 && data[2] == 0x46) return true;
    return false;
  }

  // ── Public API ───────────────────────────────────────────────────────────────

  Future<Uint8List> fetchCaptcha() async {
    await _refreshLoginContext();
    final ts = DateTime.now().millisecondsSinceEpoch;
    final resp = await _dio.get<List<int>>(
      '/kaptcha',
      queryParameters: {'time': ts},
      options: Options(
        responseType: ResponseType.bytes,
        headers: {'Referer': _loginPageUrl},
      ),
    );

    // Check content-type: if HTML is returned, it's likely a redirect/error page
    // (happens when not on campus network)
    final contentType = resp.headers.value('content-type') ?? '';
    if (contentType.contains('text/html')) {
      throw CaptchaException('无法连接到教务系统，请确保在校园网环境或已连接VPN');
    }

    final bytes = resp.data;
    if (bytes == null || bytes.isEmpty) {
      throw CaptchaException('验证码数据为空，请重试');
    }

    final data = Uint8List.fromList(bytes);

    // Validate image magic bytes (PNG / JPEG / GIF)
    if (!_isValidImage(data)) {
      throw CaptchaException('无法连接到教务系统，请确保在校园网环境或已连接VPN');
    }

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

      // 2. GET public key
      final keyResp = await _dio.get<Map<String, dynamic>>(
        '/xtgl/login_getPublicKey.html',
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

      // 3. Encrypt password
      final encryptedPwd = _encryptPassword(password, modulus, exponent);

      // 4. Pre-logout
      await _dio.post<void>(
        '/xtgl/login_logoutAccount.html',
        options: Options(
          headers: {'Referer': _loginPageUrl, 'Origin': _origin},
        ),
      );

      // 5. POST login
      final loginResp = await _dio.post<String>(
        _loginPath,
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

      // Success: redirect into index pages after login.
      final location = loginResp.headers.value('location') ?? '';
      final html = loginResp.data ?? '';
      if (_isLoginSuccess(loginResp.statusCode, location, html)) {
        currentStudentId = username;
        _sessionActive = true;
        _cachedCsrfToken = null;
        return LoginSuccess();
      }

      // Parse error message from response HTML
      final msg = _extractLoginFailureMessage(html);
      return LoginFailure(msg);
    } on DioException catch (e) {
      _cachedCsrfToken = null;
      return LoginFailure('网络错误：${e.message}');
    } catch (e) {
      _cachedCsrfToken = null;
      return LoginFailure('登录异常：$e');
    }
  }

  bool get isLoggedIn {
    // Synchronous check: look for JSESSIONID in cookie jar
    // CookieJar.loadForRequest is async, so we use a cached flag instead
    return _sessionActive;
  }

  bool _sessionActive = false;
  String? currentStudentId;

  void markLoggedIn() => _sessionActive = true;
  void markLoggedOut() {
    _sessionActive = false;
    currentStudentId = null;
  }

  Future<void> logout() async {
    try {
      await _dio.post<void>('/xtgl/login_logoutAccount.html');
    } catch (_) {}
    await _cookieJar.deleteAll();
    _sessionActive = false;
    currentStudentId = null;
    _cachedCsrfToken = null;
  }

  Future<void> _refreshLoginContext() async {
    await _refreshCsrfToken();
  }

  Future<String> _ensureCsrfToken() async {
    final token = _cachedCsrfToken?.trim();
    if (token != null && token.isNotEmpty) return token;
    return _refreshCsrfToken();
  }

  Future<String> _refreshCsrfToken() async {
    final pageResp = await _dio.get<String>(
      _loginPath,
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
