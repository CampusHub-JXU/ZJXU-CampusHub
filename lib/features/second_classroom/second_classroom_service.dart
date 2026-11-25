import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../core/auth/login_page_detection.dart';
import '../../core/logging/app_logger.dart';
import '../../core/network/dio_client.dart';
import '../../core/util/json_coerce.dart';
import 'second_classroom_auth.dart';
import 'second_classroom_model.dart';
import 'second_classroom_route.dart';

const _secondClassroomHost = 'twdekt.zjxu.edu.cn';
const _secondClassroomBasePath = '/dekt';
const _secondClassroomMenuToken = 'c3lzLmluZGV4Lm0=';
const _secondClassroomReferer =
    'https://twdekt.zjxu.edu.cn/dekt/wx/index?_WXFTL=0';

class SecondClassroomServiceException implements Exception {
  const SecondClassroomServiceException(this.message);

  final String message;

  @override
  String toString() => message;
}

class SecondClassroomService {
  SecondClassroomService({Dio? dio, SecondClassroomAuth? auth})
    : _debugDio = dio,
      _injectedAuth = auth;

  static final SecondClassroomService instance = SecondClassroomService();

  Dio? _debugDio;
  final SecondClassroomAuth? _injectedAuth;
  SecondClassroomAuth get _auth =>
      _injectedAuth ?? SecondClassroomAuth.instance;

  Future<SecondClassroomCatalog> fetchCatalog() async {
    final payload = await _post('hdList', data: _menuData());
    return parseSecondClassroomCatalogPayload(payload);
  }

  Future<SecondClassroomActivityPage> searchActivities(
    SecondClassroomActivityQuery query,
  ) async {
    final payload = await _post(
      'search',
      data: query.toFormData(menuToken: _secondClassroomMenuToken),
    );
    return parseSecondClassroomActivityPagePayload(payload);
  }

  Future<SecondClassroomActivityPage> fetchAllActivities(
    SecondClassroomActivityQuery query,
  ) async {
    final pageSize = query.limit <= 0 ? 20 : query.limit;
    final firstPage = await searchActivities(
      query.copyWith(page: 1, limit: pageSize),
    );
    final activitiesById = <int, SecondClassroomActivity>{};
    for (final activity in firstPage.items) {
      activitiesById[activity.id] = activity;
    }

    final totalPages = firstPage.totalPages <= 0 ? 1 : firstPage.totalPages;
    for (var pageIndex = 2; pageIndex <= totalPages; pageIndex += 1) {
      final page = await searchActivities(
        query.copyWith(page: pageIndex, limit: pageSize),
      );
      for (final activity in page.items) {
        activitiesById[activity.id] = activity;
      }
    }

    return SecondClassroomActivityPage(
      items: activitiesById.values.toList(growable: false),
      pageIndex: totalPages,
      pageSize: pageSize,
      totalPages: totalPages,
      count: firstPage.count,
    );
  }

  Future<SecondClassroomActivityDetail> fetchActivityDetail(
    int id, {
    bool authenticated = false,
  }) async {
    final payload = await _post(
      'detail',
      queryParameters: {'hdId': '$id', '.me': _secondClassroomMenuToken},
      data: _menuData(),
      authenticated: authenticated,
    );
    return parseSecondClassroomActivityDetailPayload(
      payload,
      authenticated: authenticated,
    );
  }

  Future<SecondClassroomMySummary> fetchMySummary() async {
    final payload = await _post('my', data: _menuData(), authenticated: true);
    return parseSecondClassroomMySummaryPayload(payload);
  }

  /// 拉取「我的活动」全部页面：服务端按 `page`/`limit` 分页，报名记录多的
  /// 账号单页 100 条可能装不下。按 `totalPages` 翻页，[maxPages] 兜底防止
  /// 服务端分页元信息异常导致的死循环；按报名记录 ID 去重。
  Future<List<SecondClassroomMyActivityRecord>> fetchMyActivities({
    int page = 1,
    int limit = 100,
    int maxPages = 20,
  }) async {
    final firstPage = await _fetchMyActivitiesPage(page: page, limit: limit);
    final recordsById = <int, SecondClassroomMyActivityRecord>{
      for (final record in firstPage.items) record.recordId: record,
    };
    // 无分页元信息（totalPages <= 0）时按单页处理，不盲目翻页。
    final totalPages = firstPage.totalPages <= 0 ? 1 : firstPage.totalPages;
    final lastPage = totalPages < maxPages ? totalPages : maxPages;
    for (var pageIndex = page + 1; pageIndex <= lastPage; pageIndex += 1) {
      final nextPage = await _fetchMyActivitiesPage(
        page: pageIndex,
        limit: limit,
      );
      for (final record in nextPage.items) {
        recordsById[record.recordId] = record;
      }
    }
    return recordsById.values.toList(growable: false);
  }

  Future<SecondClassroomMyActivitiesPage> _fetchMyActivitiesPage({
    required int page,
    required int limit,
  }) async {
    final payload = await _post(
      'wdhd',
      data: {'page': page, 'limit': limit, '.me': _secondClassroomMenuToken},
      authenticated: true,
    );
    return parseSecondClassroomMyActivitiesPagePayload(payload);
  }

  /// 用户主动点击「立即报名」时调用（`POST /dekt/mobile/bm?hdId=N`）。
  Future<SecondClassroomEnrollmentActionResult> enrollActivity(
    int activityId,
  ) async {
    try {
      await _post(
        'bm',
        queryParameters: {'hdId': '$activityId'},
        authenticated: true,
      );
      return const SecondClassroomEnrollmentActionResult(
        success: true,
        message: '报名请求已提交',
      );
    } on SecondClassroomServiceException catch (error) {
      final msg = error.message;
      final needsLogin =
          msg.contains('需要登录') ||
          msg.contains('登录成功') ||
          msg.contains('查验') ||
          msg.contains('会话');
      return SecondClassroomEnrollmentActionResult(
        success: false,
        message: msg,
        needsLogin: needsLogin,
      );
    }
  }

  /// 用户主动点击并二次确认「取消报名」时调用（`POST /dekt/mobile/qxbm`）。
  Future<SecondClassroomEnrollmentActionResult> cancelRegistration(
    int activityId, {
    int? recordId,
  }) async {
    try {
      await _post(
        'qxbm',
        queryParameters: {
          'hdId': '$activityId',
          if (recordId != null && recordId > 0) 'id': '$recordId',
        },
        data: _menuData(),
        authenticated: true,
      );
      return const SecondClassroomEnrollmentActionResult(
        success: true,
        message: '已取消报名',
      );
    } on SecondClassroomServiceException catch (error) {
      final msg = error.message;
      final needsLogin =
          msg.contains('需要登录') ||
          msg.contains('登录成功') ||
          msg.contains('查验') ||
          msg.contains('会话');
      return SecondClassroomEnrollmentActionResult(
        success: false,
        message: msg,
        needsLogin: needsLogin,
      );
    }
  }

  String portalWebUrl({bool mobile = false}) {
    final route = _auth.authenticatedRoute ?? SecondClassroomRoute.direct;
    final uri = mobile
        ? Uri.parse(_secondClassroomReferer)
        : Uri.parse('https://$_secondClassroomHost$_secondClassroomBasePath/');
    return route.uriFor(uri).toString();
  }

  String imageUrl(String imageId) {
    final trimmedId = imageId.trim();
    if (trimmedId.isEmpty) return '';
    return Uri.https(
      _secondClassroomHost,
      '$_secondClassroomBasePath/common/file/download',
      {'id': trimmedId, 'key': 'undefined', '.me': _secondClassroomMenuToken},
    ).toString();
  }

  String activityWebUrl(int activityId) {
    if (activityId <= 0) return _secondClassroomReferer;
    return 'https://$_secondClassroomHost$_secondClassroomBasePath'
        '/wx/index?_WXFTL=0#/hd-detail?hdId=$activityId';
  }

  Future<Map<String, dynamic>> _post(
    String path, {
    Map<String, dynamic>? data,
    Map<String, dynamic>? queryParameters,
    bool authenticated = false,
  }) async {
    final (dio, initialRoute) = await _resolveDio();
    final directUri = SecondClassroomRoute.mobileUri(path, queryParameters);
    var route = initialRoute;
    var uri = route.uriFor(directUri);
    final verifyIdentity =
        authenticated && (_debugDio == null || _injectedAuth != null);
    final owner = verifyIdentity ? _auth.currentUserId : null;
    if (verifyIdentity && owner == null) {
      throw const SecondClassroomServiceException('暂时无法确认第二课堂会话，请稍后重试');
    }

    try {
      Future<Response<Object?>> send() => dio.postUri<Object?>(
        uri,
        data: data,
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          responseType: ResponseType.json,
          followRedirects: false,
          headers: route.xhrHeaders(uri),
          validateStatus: (status) => status != null && status < 500,
        ),
      );

      var response = await send();
      var redirect = SecondClassroomRoute.redirectTarget(response);
      if (route == SecondClassroomRoute.direct &&
          redirect != null &&
          SecondClassroomRoute.forUri(redirect) ==
              SecondClassroomRoute.webVpn &&
          !SecondClassroomRoute.isLoginUrl(redirect)) {
        // 列表等读取可用已存 Cookie 改道，不触发后台登录。详情要先验证代理
        // SESSION 的身份，避免把代理侧的游客数据解释成「未报名」。
        if (authenticated) {
          final state = await _auth.ensureSession(
            force: true,
            forceWebVpn: true,
          );
          if (state != SecondClassroomAuthState.authenticated ||
              (verifyIdentity && _auth.currentUserId != owner) ||
              _auth.authenticatedRoute != SecondClassroomRoute.webVpn) {
            throw SecondClassroomServiceException(
              state == SecondClassroomAuthState.needsLogin
                  ? '第二课堂 WebVPN 会话需要登录'
                  : '暂时无法确认第二课堂 WebVPN 会话，请稍后重试',
            );
          }
        }
        route = SecondClassroomRoute.webVpn;
        uri = route.uriFor(directUri);
        response = await send();
        redirect = SecondClassroomRoute.redirectTarget(response);
      }

      if (SecondClassroomRoute.isLoginResponse(response, redirect)) {
        throw const SecondClassroomServiceException('第二课堂会话需要登录');
      }
      if (verifyIdentity &&
          (_auth.currentUserId != owner || _auth.authenticatedRoute != route)) {
        throw const SecondClassroomServiceException('第二课堂会话已变化，请稍后重试');
      }
      final status = response.statusCode ?? 0;
      if (status < 200 || status >= 300) {
        throw const SecondClassroomServiceException('第二课堂连接失败，请稍后重试');
      }

      final payload = _payloadFromResponse(response.data, route);
      final success = payload['success'];
      final code = payload['code'];
      if (success == false || (code is num && code != 0)) {
        throw SecondClassroomServiceException(
          _messageFromPayload(payload, fallback: '第二课堂请求失败'),
        );
      }
      return payload;
    } on DioException catch (error, stackTrace) {
      AppLogger.instance.network(
        LogLevel.warn,
        '第二课堂接口请求失败: ${uri.path}',
        error: error,
        stackTrace: stackTrace,
      );
      throw const SecondClassroomServiceException('第二课堂连接失败，请稍后重试');
    } on FormatException catch (error, stackTrace) {
      AppLogger.instance.network(
        LogLevel.warn,
        '第二课堂接口返回格式异常: ${uri.path}',
        error: error,
        stackTrace: stackTrace,
      );
      throw const SecondClassroomServiceException('第二课堂数据解析失败');
    } on SecondClassroomServiceException {
      rethrow;
    }
  }

  Future<(Dio, SecondClassroomRoute)> _resolveDio() async {
    final debugDio = _debugDio;
    if (debugDio != null) {
      return (
        debugDio,
        _injectedAuth?.authenticatedRoute ?? SecondClassroomRoute.direct,
      );
    }

    await DioClient.instance.ensureInitialized();
    // 两种路由均使用统一认证 jar，Cookie 拦截器按实际请求的域 / 路径携带 Cookie。
    return (
      DioClient.instance.unifiedAuthDio,
      _auth.authenticatedRoute ?? SecondClassroomRoute.direct,
    );
  }

  Map<String, dynamic> _payloadFromResponse(
    Object? data,
    SecondClassroomRoute route,
  ) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    if (data is String) {
      final text = data.trimLeft();
      if (route == SecondClassroomRoute.direct &&
          looksLikeWeChatAuthHtml(text)) {
        throw const SecondClassroomServiceException('第二课堂登录态失效，请在微信中重新授权');
      }
      final decoded = jsonDecode(data);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    }
    throw const FormatException('第二课堂响应不是 JSON 对象');
  }

  Map<String, dynamic> _menuData() {
    return {'.me': _secondClassroomMenuToken};
  }

  String _messageFromPayload(
    Map<String, dynamic> payload, {
    required String fallback,
  }) {
    final msg = payload['msg']?.toString().trim() ?? '';
    return msg.isEmpty ? fallback : msg;
  }

  @visibleForTesting
  void debugSetDio(Dio? dio) {
    _debugDio = dio;
  }

  @visibleForTesting
  void debugReset() {
    _debugDio = null;
  }
}

@visibleForTesting
SecondClassroomCatalog parseSecondClassroomCatalogPayload(
  Map<String, dynamic> payload,
) {
  final extend = _mapValue(payload['extend']);
  return SecondClassroomCatalog(
    categories: _optionList(extend['hdflList']),
    departments: _optionList(extend['zzjgList']),
    organizationTypes: _optionList(extend['zzlbList']),
  );
}

@visibleForTesting
SecondClassroomActivityPage parseSecondClassroomActivityPagePayload(
  Map<String, dynamic> payload,
) {
  final data = payload['data'];
  final items = data is List
      ? data
            .whereType<Map>()
            .map(
              (json) => SecondClassroomActivity.fromJson(
                Map<String, dynamic>.from(json),
              ),
            )
            .toList()
      : <SecondClassroomActivity>[];

  return SecondClassroomActivityPage(
    items: items,
    pageIndex: asInt(payload['pageIndex']),
    pageSize: asInt(payload['pageSize']),
    totalPages: asInt(payload['totalPages']),
    count: asInt(payload['count']),
  );
}

@visibleForTesting
SecondClassroomActivityDetail parseSecondClassroomActivityDetailPayload(
  Map<String, dynamic> payload, {
  bool authenticated = false,
}) {
  return SecondClassroomActivityDetail.fromExtend(
    _mapValue(payload['extend']),
    authenticated: authenticated,
  );
}

@visibleForTesting
SecondClassroomMySummary parseSecondClassroomMySummaryPayload(
  Map<String, dynamic> payload,
) {
  return SecondClassroomMySummary.fromExtend(_mapValue(payload['extend']));
}

@visibleForTesting
List<SecondClassroomMyActivityRecord> parseSecondClassroomMyActivitiesPayload(
  Map<String, dynamic> payload,
) {
  return parseSecondClassroomMyActivitiesPagePayload(payload).items;
}

@visibleForTesting
SecondClassroomMyActivitiesPage parseSecondClassroomMyActivitiesPagePayload(
  Map<String, dynamic> payload,
) {
  final extend = _mapValue(payload['extend']);
  final data = payload['data'] ?? extend['list'];
  final items = data is! List
      ? const <SecondClassroomMyActivityRecord>[]
      : data
            .whereType<Map>()
            .map(
              (json) => SecondClassroomMyActivityRecord.fromJson(
                Map<String, dynamic>.from(json),
              ),
            )
            .where((record) => record.activity.id > 0)
            .toList(growable: false);
  // 分页元信息与 search 同构在顶层；若嵌在 extend 内（如 total/count）也接受。
  int readInt(String key) {
    final top = payload[key];
    if (top != null) return asInt(top);
    return asInt(extend[key]);
  }

  return SecondClassroomMyActivitiesPage(
    items: items,
    pageIndex: readInt('pageIndex'),
    pageSize: readInt('pageSize'),
    totalPages: readInt('totalPages') != 0
        ? readInt('totalPages')
        : readInt('pages'),
    count: readInt('count') != 0 ? readInt('count') : readInt('total'),
  );
}

Map<String, dynamic> _mapValue(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  return const <String, dynamic>{};
}

List<SecondClassroomFilterOption> _optionList(Object? value) {
  if (value is! List) return const <SecondClassroomFilterOption>[];
  return value
      .whereType<Map>()
      .map(
        (json) => SecondClassroomFilterOption.fromJson(
          Map<String, dynamic>.from(json),
        ),
      )
      .where((option) => option.value.isNotEmpty && option.text.isNotEmpty)
      .toList(growable: false);
}
