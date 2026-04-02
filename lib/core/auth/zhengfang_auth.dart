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

class ZhengfangAuth {
  ZhengfangAuth._();
  static final ZhengfangAuth instance = ZhengfangAuth._();

  final _dio = DioClient.instance.dio;
  final _cookieJar = DioClient.instance.cookieJar;

  // ── RSA encryption ──────────────────────────────────────────────────────────

  String _encryptPassword(String password, String modulusB64, String exponentB64) {
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

  // ── Public API ───────────────────────────────────────────────────────────────

  Future<Uint8List> fetchCaptcha() async {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final resp = await _dio.get<List<int>>(
      '/kaptcha',
      queryParameters: {'time': ts},
      options: Options(responseType: ResponseType.bytes),
    );
    return Uint8List.fromList(resp.data!);
  }

  Future<LoginResult> login(
    String username,
    String password,
    String captcha,
  ) async {
    try {
      final ts = DateTime.now().millisecondsSinceEpoch;

      // 1. GET login page → extract csrftoken
      final pageResp = await _dio.get<String>('/xtgl/login_slogin.html');
      final pageHtml = pageResp.data ?? '';
      final csrfMatch = RegExp(r'id="csrftoken"[^>]*value="([^"]+)"')
          .firstMatch(pageHtml);
      final csrftoken = csrfMatch?.group(1) ?? '';

      // 2. GET public key
      final keyResp = await _dio.get<Map<String, dynamic>>(
        '/xtgl/login_getPublicKey.html',
        queryParameters: {'time': ts},
      );
      final modulus = keyResp.data!['modulus'] as String;
      final exponent = keyResp.data!['exponent'] as String;

      // 3. Encrypt password
      final encryptedPwd = _encryptPassword(password, modulus, exponent);

      // 4. Pre-logout
      await _dio.post<void>('/xtgl/login_logoutAccount.html');

      // 5. POST login
      final loginResp = await _dio.post<String>(
        '/xtgl/login_slogin.html',
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
          validateStatus: (s) => s != null && s < 400,
        ),
      );

      // Success: 302 redirect to index_initMenu
      final location = loginResp.headers.value('location') ?? '';
      if (loginResp.statusCode == 302 &&
          location.contains('index_initMenu')) {
        currentStudentId = username;
        return LoginSuccess();
      }

      // Parse error message from response HTML
      final html = loginResp.data ?? '';
      final tipMatch = RegExp(r'id="tips"[^>]*>(.*?)</[^>]+>', dotAll: true)
          .firstMatch(html);
      final msg = tipMatch?.group(1)?.replaceAll(RegExp(r'<[^>]+>'), '').trim() ??
          '登录失败，请检查用户名、密码和验证码';
      return LoginFailure(msg.isEmpty ? '登录失败' : msg);
    } on DioException catch (e) {
      return LoginFailure('网络错误：${e.message}');
    } catch (e) {
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
  void markLoggedOut() => _sessionActive = false;

  Future<void> logout() async {
    try {
      await _dio.post<void>('/xtgl/login_logoutAccount.html');
    } catch (_) {}
    await _cookieJar.deleteAll();
    _sessionActive = false;
  }
}
