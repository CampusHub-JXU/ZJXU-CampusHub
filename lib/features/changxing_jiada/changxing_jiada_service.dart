import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/digests/md5.dart';

import '../../core/logging/app_logger.dart';
import '../../core/network/dio_client.dart';
import 'changxing_jiada_model.dart';

class ChangxingAuthExpiredException implements Exception {
  ChangxingAuthExpiredException([this.message = '畅行嘉大登录已失效，请重新登录']);

  final String message;

  @override
  String toString() => message;
}

class ChangxingLoginFailure implements Exception {
  ChangxingLoginFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

class ChangxingJiadaService {
  ChangxingJiadaService._();
  static final ChangxingJiadaService instance = ChangxingJiadaService._();

  static const _baseUrl = 'https://zhx.zjxu.edu.cn/api';
  static const _storage = FlutterSecureStorage();
  static const _keyToken = 'zjxu_changxing_token';
  static const _keyUsername = 'zjxu_changxing_username';
  static const _keyPassword = 'zjxu_changxing_password';

  final Dio _dio = DioClient.instance.dio;

  String? _token;
  bool _restored = false;

  bool get hasToken => (_token ?? '').isNotEmpty;

  Future<void> restoreSession() async {
    if (_restored) return;
    _token = await _storage.read(key: _keyToken);
    _restored = true;
  }

  Future<(String, String)?> loadRememberedCredentials() async {
    final username = await _storage.read(key: _keyUsername);
    final password = await _storage.read(key: _keyPassword);
    if (username == null || password == null) return null;
    return (username, password);
  }

  Future<void> _saveRememberedCredentials(
    String username,
    String password,
  ) async {
    await _storage.write(key: _keyUsername, value: username);
    await _storage.write(key: _keyPassword, value: password);
  }

  Future<void> clearRememberedCredentials() async {
    await _storage.delete(key: _keyUsername);
    await _storage.delete(key: _keyPassword);
  }

  Future<void> _saveToken(String token) async {
    _token = token;
    await _storage.write(key: _keyToken, value: token);
  }

  Future<void> _clearToken() async {
    _token = null;
    await _storage.delete(key: _keyToken);
  }

  Future<void> logout() async {
    await _clearToken();
  }

  Future<Uint8List> fetchCaptcha() async {
    final json = await _get('/valiCode', requiresToken: false);
    final code = _extractCode(json);
    if (code != '20000') {
      throw ChangxingLoginFailure(_extractMessage(json, fallback: '验证码获取失败'));
    }
    final base64Text = _extractDataMap(json)['base64']?.toString() ?? '';
    if (base64Text.isEmpty) {
      throw ChangxingLoginFailure('验证码为空，请刷新后重试');
    }
    try {
      return base64Decode(base64Text);
    } catch (_) {
      throw ChangxingLoginFailure('验证码解析失败，请刷新后重试');
    }
  }

  Future<void> login(
    String username,
    String password,
    String captcha, {
    required bool rememberPassword,
  }) async {
    final json = await _postForm('/login', {
      'userName': username,
      'password': _md5Hex(password),
      'code': captcha,
    }, requiresToken: false);

    final code = _extractCode(json);
    if (code != '20000') {
      final message = _extractMessage(json, fallback: '账号、密码或验证码错误');
      throw ChangxingLoginFailure(message);
    }

    final token = _extractDataMap(json)['body']?.toString().trim() ?? '';
    if (token.isEmpty) {
      throw ChangxingLoginFailure('登录成功但未获取到 token');
    }

    await _saveToken(token);
    if (rememberPassword) {
      await _saveRememberedCredentials(username, password);
    } else {
      await clearRememberedCredentials();
    }
    AppLogger.instance.info('畅行嘉大登录成功');
  }

  Future<ChangxingUserProfile> fetchUserProfile() async {
    final json = await _postJson('/user/getUserDetail', {});
    final code = _extractCode(json);
    if (code != '20000') {
      throw ChangxingLoginFailure(_extractMessage(json, fallback: '获取用户信息失败'));
    }
    final body = _extractDataMap(json)['body'] as Map<String, dynamic>? ?? {};
    return ChangxingUserProfile.fromJson(body);
  }

  Future<int> fetchUnreadCount() async {
    final json = await _get('/msg/getNoReadCount');
    final code = _extractCode(json);
    if (code != '20000') return 0;
    final data = _extractDataMap(json);
    final count = data['count'];
    if (count is int) return count;
    return int.tryParse(count?.toString() ?? '') ?? 0;
  }

  Future<List<ChangxingApplication>> fetchApplications({
    int page = 1,
    int pageSize = 20,
    int status = 999,
  }) async {
    final json = await _get(
      '/approvalForm/listPage/bystudent',
      query: {'current': '$page', 'pageSize': '$pageSize', 'status': '$status'},
    );
    final code = _extractCode(json);
    if (code != '20000') {
      throw ChangxingLoginFailure(_extractMessage(json, fallback: '获取申请列表失败'));
    }
    final body = _extractDataMap(json)['body'] as Map<String, dynamic>? ?? {};
    final records = (body['records'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(ChangxingApplication.fromJson)
        .toList();
    return records;
  }

  Future<Map<String, dynamic>> _get(
    String path, {
    bool requiresToken = true,
    Map<String, String>? query,
  }) async {
    return _request(
      path: path,
      method: 'GET',
      requiresToken: requiresToken,
      query: query,
    );
  }

  Future<Map<String, dynamic>> _postJson(
    String path,
    Map<String, dynamic> body, {
    bool requiresToken = true,
  }) async {
    return _request(
      path: path,
      method: 'POST',
      requiresToken: requiresToken,
      data: body,
      contentType: Headers.jsonContentType,
    );
  }

  Future<Map<String, dynamic>> _postForm(
    String path,
    Map<String, String> form, {
    bool requiresToken = true,
  }) async {
    return _request(
      path: path,
      method: 'POST',
      requiresToken: requiresToken,
      data: form.entries
          .map(
            (entry) =>
                '${Uri.encodeQueryComponent(entry.key)}=${Uri.encodeQueryComponent(entry.value)}',
          )
          .join('&'),
      contentType: Headers.formUrlEncodedContentType,
    );
  }

  Future<Map<String, dynamic>> _request({
    required String path,
    required String method,
    required bool requiresToken,
    Object? data,
    String? contentType,
    Map<String, String>? query,
  }) async {
    await restoreSession();
    final token = _token ?? '';
    if (requiresToken && token.isEmpty) {
      throw ChangxingAuthExpiredException();
    }

    final uri = Uri.parse('$_baseUrl$path').replace(queryParameters: query);
    final headers = <String, String>{};
    if (requiresToken) {
      headers['token'] = token;
    }

    final response = await _dio.requestUri<Map<String, dynamic>>(
      uri,
      data: data,
      options: Options(
        method: method,
        contentType: contentType,
        headers: headers,
        responseType: ResponseType.json,
      ),
    );

    final json = response.data ?? <String, dynamic>{};
    final code = _extractCode(json);
    if (code == '500001') {
      await _clearToken();
      throw ChangxingAuthExpiredException(
        _extractMessage(json, fallback: '令牌错误，请重新登录'),
      );
    }
    return json;
  }

  String _extractCode(Map<String, dynamic> json) {
    final data = _extractDataMap(json);
    return data['code']?.toString() ?? json['code']?.toString() ?? '';
  }

  String _extractMessage(
    Map<String, dynamic> json, {
    required String fallback,
  }) {
    final data = _extractDataMap(json);
    return data['msg']?.toString() ??
        data['errmsg']?.toString() ??
        json['msg']?.toString() ??
        fallback;
  }

  Map<String, dynamic> _extractDataMap(Map<String, dynamic> json) {
    final data = json['data'];
    if (data is Map<String, dynamic>) return data;
    return <String, dynamic>{};
  }

  String _md5Hex(String input) {
    final digest = MD5Digest().process(Uint8List.fromList(utf8.encode(input)));
    final buffer = StringBuffer();
    for (final byte in digest) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}
