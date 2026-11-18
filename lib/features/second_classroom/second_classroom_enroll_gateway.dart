import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/auth/unified_auth.dart';
import '../../core/logging/app_logger.dart';
import '../../core/network/dio_client.dart';
import 'second_classroom_auth.dart';
import 'second_classroom_model.dart';
import 'second_classroom_route.dart';
import 'second_classroom_service.dart';

enum SecondClassroomEnrollResult {
  done,
  failed,
  pending,
  needsLogin,
  needsForm,
  unavailable,
}

class SecondClassroomEnrollGateway {
  SecondClassroomEnrollGateway();
  static final instance = SecondClassroomEnrollGateway();
  static const autoEnrollKey = 'second_classroom_auto_enroll';
  static const _prefix = 'second_classroom_enroll_v1_';
  String? lastFailureReason;

  Future<bool> isAutoEnrollEnabled() async =>
      (await SharedPreferences.getInstance()).getBool(autoEnrollKey) ?? false;

  Future<void> setAutoEnrollEnabled(bool enabled) async =>
      (await SharedPreferences.getInstance()).setBool(autoEnrollKey, enabled);

  Future<SecondClassroomEnrollResult> submit(
    SecondClassroomActivity activity,
  ) async {
    final auth = UnifiedAuthService.instance;
    lastFailureReason = null;
    if (auth.verifiedAccount == null) {
      await auth.restoreSession(syncWebViewCookies: false);
    }
    final account = auth.verifiedAccount;
    if (account == null || activity.id <= 0) {
      return SecondClassroomEnrollResult.needsLogin;
    }
    final revision = auth.sessionRevision;
    if (await SecondClassroomAuth.instance.ensureSession(force: true) !=
            SecondClassroomAuthState.authenticated ||
        auth.verifiedAccount != account ||
        auth.sessionRevision != revision) {
      return SecondClassroomEnrollResult.needsLogin;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final key =
        '$_prefix${base64Url.encode(utf8.encode(account))}_${activity.id}';
    final stored = prefs.getString(key);
    Map<String, dynamic>? record;
    if (stored != null) {
      try {
        record = Map<String, dynamic>.from(jsonDecode(stored) as Map);
      } catch (_) {
        return SecondClassroomEnrollResult.unavailable;
      }
    }
    if (record?['state'] == 'done') return SecondClassroomEnrollResult.done;
    if (record?['state'] == 'failed') {
      lastFailureReason = record?['reason'] as String?;
      return SecondClassroomEnrollResult.failed;
    }
    if (record?['state'] == 'pending') {
      final at = DateTime.tryParse(record?['at']?.toString() ?? '');
      if (at == null ||
          DateTime.now().difference(at) < const Duration(minutes: 15)) {
        return SecondClassroomEnrollResult.pending;
      }
    }
    try {
      final detail = await SecondClassroomService.instance.fetchActivityDetail(
        activity.id,
        authenticated: true,
      );
      if (auth.verifiedAccount != account ||
          auth.sessionRevision != revision ||
          !SecondClassroomAuth.instance.isAuthenticated) {
        return SecondClassroomEnrollResult.needsLogin;
      }
      if (detail.registrationState ==
          SecondClassroomRegistrationState.registered) {
        await _save(prefs, key, 'done');
        return SecondClassroomEnrollResult.done;
      }
      if (detail.registrationState !=
              SecondClassroomRegistrationState.notRegistered ||
          detail.requiresRegistrationForm == null) {
        return SecondClassroomEnrollResult.unavailable;
      }
      if (detail.requiresRegistrationForm!) {
        return SecondClassroomEnrollResult.needsForm;
      }
      await _save(prefs, key, 'pending');
      await DioClient.instance.ensureInitialized();
      if (auth.verifiedAccount != account ||
          auth.sessionRevision != revision ||
          !SecondClassroomAuth.instance.isAuthenticated) {
        return SecondClassroomEnrollResult.pending;
      }
      Future<Response<Object?>> post() {
        final route = SecondClassroomAuth.instance.authenticatedRoute;
        if (route == null) throw StateError('第二课堂会话已失效');
        final uri = route.uriFor(
          SecondClassroomRoute.mobileUri('bm', {'hdId': '${activity.id}'}),
        );
        return DioClient.instance.unifiedAuthDio.postUri<Object?>(
          uri,
          options: Options(
            responseType: ResponseType.json,
            followRedirects: false,
            headers: route.xhrHeaders(uri),
          ),
        );
      }

      var response = await post();
      var payload = response.data;
      var message = payload is Map ? payload['msg']?.toString() ?? '' : '';
      if (payload is Map &&
          payload['code'] == -1 &&
          (message.contains('登录成功') || message.contains('查验'))) {
        final recovered = await SecondClassroomAuth.instance.ensureSession(
          force: true,
        );
        if (recovered != SecondClassroomAuthState.authenticated ||
            auth.verifiedAccount != account ||
            auth.sessionRevision != revision) {
          await _save(prefs, key, 'failed', reason: '登录失效');
          return SecondClassroomEnrollResult.needsLogin;
        }
        response = await post();
        payload = response.data;
        message = payload is Map ? payload['msg']?.toString() ?? '' : '';
        if (payload is Map &&
            payload['code'] == -1 &&
            (message.contains('登录成功') || message.contains('查验'))) {
          await _save(prefs, key, 'failed', reason: '登录失效');
          return SecondClassroomEnrollResult.needsLogin;
        }
      }
      if (payload is Map &&
          payload['code'] == -1 &&
          (message.contains('已结束') ||
              message.contains('已截止') ||
              message.contains('已开始'))) {
        lastFailureReason = message;
        await _save(prefs, key, 'failed', reason: message);
        return SecondClassroomEnrollResult.failed;
      }
      final success =
          payload is Map && payload['code'] == 0 && payload['success'] == true;
      AppLogger.instance.storage(
        LogLevel.info,
        success ? '第二课堂报名请求已提交，等待核验' : '第二课堂报名请求未成功，等待核验',
      );
      final verified = await SecondClassroomService.instance
          .fetchActivityDetail(activity.id, authenticated: true);
      if (auth.verifiedAccount != account ||
          auth.sessionRevision != revision ||
          !SecondClassroomAuth.instance.isAuthenticated) {
        return SecondClassroomEnrollResult.pending;
      }
      if (verified.registrationState ==
          SecondClassroomRegistrationState.registered) {
        await _save(prefs, key, 'done');
        return SecondClassroomEnrollResult.done;
      }
      if (verified.registrationState ==
          SecondClassroomRegistrationState.unknown) {
        return SecondClassroomEnrollResult.pending;
      }
      if (success) return SecondClassroomEnrollResult.pending;
      lastFailureReason = '报名接口返回失败';
      await _save(prefs, key, 'failed', reason: success ? '核验未报名' : '报名接口返回失败');
      return SecondClassroomEnrollResult.failed;
    } catch (_) {
      AppLogger.instance.storage(LogLevel.warn, '第二课堂报名或核验暂不可用');
      return SecondClassroomEnrollResult.unavailable;
    }
  }

  Future<void> _save(
    SharedPreferences prefs,
    String key,
    String state, {
    String? reason,
  }) async {
    await prefs.setString(
      key,
      jsonEncode({
        'state': state,
        'at': DateTime.now().toIso8601String(),
        'reason': ?reason,
      }),
    );
  }
}
