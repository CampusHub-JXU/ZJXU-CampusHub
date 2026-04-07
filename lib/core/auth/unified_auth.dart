import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:pointycastle/export.dart';

import '../logging/app_logger.dart';
import '../network/dio_client.dart';

sealed class UnifiedAuthLoginResult {}

class UnifiedAuthLoginSuccess extends UnifiedAuthLoginResult {}

class UnifiedAuthLoginFailure extends UnifiedAuthLoginResult {
  UnifiedAuthLoginFailure(this.message);

  final String message;
}

class UnifiedAuthCaptchaException implements Exception {
  UnifiedAuthCaptchaException(this.message);

  final String message;

  @override
  String toString() => message;
}

class _UnifiedAuthLoginContext {
  const _UnifiedAuthLoginContext({
    required this.serviceUrl,
    required this.lt,
    required this.execution,
    required this.actionUri,
  });

  final String serviceUrl;
  final String lt;
  final String execution;
  final Uri actionUri;
}

class UnifiedAuthService {
  UnifiedAuthService._();
  static final UnifiedAuthService instance = UnifiedAuthService._();

  static const defaultServiceUrl =
      'https://newca.zjxu.edu.cn/casClient/login/ydd';

  static const _newcaOrigin = 'https://newca.zjxu.edu.cn';
  static const _serviceHallOrigin = 'https://mobilehall.zjxu.edu.cn';
  static const _paymentOrigin = 'https://app.xiaoyuan.ccb.com';
  static const _aesKey = 'key_value_123456';
  static const _aesIv = '0987654321123456';

  final _dio = DioClient.instance.dio;
  final _cookieJar = DioClient.instance.cookieJar;
  final _cookieManager = CookieManager.instance();

  _UnifiedAuthLoginContext? _cachedContext;
  bool _sessionActive = false;
  String? currentAccount;

  bool get isLoggedIn => _sessionActive;

  Future<Uint8List> fetchCaptcha({
    String serviceUrl = defaultServiceUrl,
  }) async {
    await _refreshLoginContext(serviceUrl);
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final referer = _buildLoginUri(serviceUrl).toString();
    final captchaUri = Uri.parse('$_newcaOrigin/cas/captcha.html?t=$timestamp');
    final resp = await _dio.getUri<List<int>>(
      captchaUri,
      options: Options(
        responseType: ResponseType.bytes,
        headers: {'Referer': referer},
      ),
    );

    final contentType = resp.headers.value('content-type') ?? '';
    if (contentType.contains('text/html')) {
      throw UnifiedAuthCaptchaException('统一认证验证码加载失败，请稍后重试');
    }

    final bytes = resp.data;
    if (bytes == null || bytes.isEmpty) {
      throw UnifiedAuthCaptchaException('统一认证验证码为空，请刷新后重试');
    }

    final data = Uint8List.fromList(bytes);
    if (!_isValidImage(data)) {
      throw UnifiedAuthCaptchaException('统一认证验证码无效，请刷新后重试');
    }

    return data;
  }

  Future<UnifiedAuthLoginResult> login(
    String username,
    String password,
    String captcha, {
    String serviceUrl = defaultServiceUrl,
  }) async {
    try {
      final context = await _ensureLoginContext(serviceUrl);
      if (context.lt.isEmpty || context.execution.isEmpty) {
        return UnifiedAuthLoginFailure('统一认证初始化失败，请刷新验证码后重试');
      }

      final encryptedPassword = _encryptPassword(password);
      final referer = _buildLoginUri(serviceUrl).toString();
      final response = await _dio.postUri<String>(
        context.actionUri,
        data: {
          'username': username,
          'password': encryptedPassword,
          'veriyCode': captcha,
          'lt': context.lt,
          'execution': context.execution,
          '_eventId': 'submit',
        },
        options: Options(
          contentType: 'application/x-www-form-urlencoded',
          responseType: ResponseType.plain,
          followRedirects: false,
          validateStatus: (status) => status != null && status < 1000,
          headers: {'Referer': referer, 'Origin': _newcaOrigin},
        ),
      );

      final location = response.headers.value('location') ?? '';
      final html = response.data ?? '';
      if (_isLoginSuccess(response.statusCode, location, html)) {
        await _followRedirectChain(context.actionUri, location);
        await syncCookiesToWebView();
        _sessionActive = true;
        currentAccount = username;
        _cachedContext = null;
        AppLogger.instance.info('统一认证登录成功，已同步 WebView Cookie');
        return UnifiedAuthLoginSuccess();
      }

      _cachedContext = null;
      return UnifiedAuthLoginFailure(_extractLoginFailureMessage(html));
    } on DioException catch (error) {
      _cachedContext = null;
      return UnifiedAuthLoginFailure('统一认证网络异常：${error.message}');
    } catch (error) {
      _cachedContext = null;
      return UnifiedAuthLoginFailure('统一认证登录失败：$error');
    }
  }

  Future<void> syncCookiesToWebView() async {
    // loadForRequest 需要带 path 的完整 URI 才能匹配到子路径 cookie
    final uris = [
      Uri.parse('$_newcaOrigin/cas/login'),
      Uri.parse('$_serviceHallOrigin/webroot/decision/view/form'),
      Uri.parse(_paymentOrigin),
    ];

    for (final uri in uris) {
      final cookies = await _cookieJar.loadForRequest(uri);
      AppLogger.instance.debug('syncCookies ${uri.host}: ${cookies.map((c) => c.name).join(', ')}');
      for (final cookie in cookies) {
        await _setWebViewCookie(uri, cookie);
      }
    }
  }

  void markLoggedOut() {
    _sessionActive = false;
    currentAccount = null;
    _cachedContext = null;
  }

  Future<void> _setWebViewCookie(Uri uri, io.Cookie cookie) async {
    final domain = (cookie.domain ?? '').trim();
    final path = (cookie.path ?? '').trim();
    await _cookieManager.setCookie(
      url: WebUri('${uri.scheme}://${uri.host}/'),
      name: cookie.name,
      value: cookie.value,
      domain: domain.isNotEmpty ? domain : uri.host,
      path: path.isNotEmpty ? path : '/',
      isSecure: cookie.secure,
      isHttpOnly: cookie.httpOnly,
      expiresDate: cookie.expires?.millisecondsSinceEpoch,
    );
  }

  Future<_UnifiedAuthLoginContext> _ensureLoginContext(
    String serviceUrl,
  ) async {
    final context = _cachedContext;
    if (context != null && context.serviceUrl == serviceUrl) {
      return context;
    }
    return _refreshLoginContext(serviceUrl);
  }

  Future<_UnifiedAuthLoginContext> _refreshLoginContext(
    String serviceUrl,
  ) async {
    final loginUri = _buildLoginUri(serviceUrl);
    final response = await _dio.getUri<String>(
      loginUri,
      options: Options(
        responseType: ResponseType.plain,
        headers: {'Referer': loginUri.toString()},
      ),
    );

    final html = response.data ?? '';
    final lt = _extractHiddenField(html, 'lt');
    final execution = _extractHiddenField(html, 'execution');
    final action = _extractFormAction(html);
    final context = _UnifiedAuthLoginContext(
      serviceUrl: serviceUrl,
      lt: lt,
      execution: execution,
      actionUri: _resolveUri(loginUri, action),
    );
    _cachedContext = context;
    return context;
  }

  Uri _buildLoginUri(String serviceUrl) {
    return Uri.parse(
      '$_newcaOrigin/cas/login',
    ).replace(queryParameters: {'service': serviceUrl});
  }

  Uri _resolveUri(Uri baseUri, String location) {
    if (location.isEmpty) return baseUri;
    final resolved = Uri.tryParse(location);
    if (resolved == null) return baseUri;
    if (resolved.hasScheme) return resolved;
    return baseUri.resolveUri(resolved);
  }

  Future<void> _followRedirectChain(Uri baseUri, String location) async {
    var nextUri = _resolveUri(baseUri, location);
    for (var i = 0; i < 8; i++) {
      final response = await _dio.getUri<String>(
        nextUri,
        options: Options(
          responseType: ResponseType.plain,
          followRedirects: false,
          validateStatus: (status) => status != null && status < 1000,
          headers: {'Referer': baseUri.toString()},
        ),
      );

      final redirect = response.headers.value('location') ?? '';
      if (redirect.isEmpty) return;
      nextUri = _resolveUri(nextUri, redirect);
    }
  }

  String _encryptPassword(String password) {
    final keyBytes = Uint8List.fromList(utf8.encode(_aesKey));
    final ivBytes = Uint8List.fromList(utf8.encode(_aesIv));
    final input = Uint8List.fromList(utf8.encode(password));
    final paddedInput = _pkcs7Pad(input, 16);
    final cipher = CBCBlockCipher(AESEngine())
      ..init(true, ParametersWithIV(KeyParameter(keyBytes), ivBytes));

    final output = Uint8List(paddedInput.length);
    for (var offset = 0; offset < paddedInput.length; offset += 16) {
      cipher.processBlock(paddedInput, offset, output, offset);
    }

    final buffer = StringBuffer();
    for (final byte in output) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0').toUpperCase());
    }
    return buffer.toString();
  }

  Uint8List _pkcs7Pad(Uint8List input, int blockSize) {
    final padding = blockSize - (input.length % blockSize);
    return Uint8List.fromList([
      ...input,
      ...List<int>.filled(padding, padding),
    ]);
  }

  bool _isLoginSuccess(int? statusCode, String location, String html) {
    final normalizedLocation = location.toLowerCase();
    if (statusCode == 302 || statusCode == 303) {
      if (normalizedLocation.contains('/cas/login')) return false;
      return normalizedLocation.isNotEmpty;
    }

    final lowerHtml = html.toLowerCase();
    return lowerHtml.contains('登录中') ||
        lowerHtml.contains('/oauth/forward/') ||
        lowerHtml.contains('casclient/login');
  }

  String _extractLoginFailureMessage(String html) {
    final match = RegExp(
      r'''id=["']msg["'][^>]*>([\s\S]*?)</[^>]+>''',
      caseSensitive: false,
    ).firstMatch(html);
    final message = _decodeHtmlEntities(
      (match?.group(1) ?? '').replaceAll(RegExp(r'<[^>]+>'), '').trim(),
    );
    if (message.isNotEmpty) return message;

    if (html.contains('验证码')) return '验证码错误或已过期，请刷新后重试';
    if (html.contains('用户名') || html.contains('密码')) {
      return '账号或密码错误，请检查后重试';
    }

    return '统一认证登录失败，请检查账号、密码和验证码';
  }

  String _extractHiddenField(String html, String fieldName) {
    final pattern = RegExp(
      'name=["\']$fieldName["\'][^>]*value=["\']([^"\']+)["\']',
      caseSensitive: false,
    );
    return pattern.firstMatch(html)?.group(1)?.trim() ?? '';
  }

  String _extractFormAction(String html) {
    final pattern = RegExp(
      r'''<form[^>]+id=["']fm1["'][^>]+action=["']([^"']+)["']''',
      caseSensitive: false,
    );
    return pattern.firstMatch(html)?.group(1)?.trim() ?? '';
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

  bool _isValidImage(Uint8List data) {
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
}
