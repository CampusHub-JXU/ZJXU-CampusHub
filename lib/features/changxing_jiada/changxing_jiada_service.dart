import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../core/auth/unified_auth.dart';
import '../../core/auth/zhengfang_auth.dart';
import '../../core/logging/app_logger.dart';
import '../../core/network/dio_client.dart';
import 'changxing_jiada_model.dart';
import 'changxing_jiada_token_binding.dart';

class ChangxingAuthExpiredException implements Exception {
  ChangxingAuthExpiredException([this.message = '畅行嘉大登录已失效，请重新登录']);

  final String message;

  @override
  String toString() => message;
}

class ChangxingCasLoginException implements Exception {
  ChangxingCasLoginException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// CAS session 无效，需要重新登录一卡通。
class ChangxingNeedUnifiedAuthException implements Exception {
  @override
  String toString() => '一卡通登录已失效，请重新登录';
}

@immutable
class ChangxingSubmitRequest {
  const ChangxingSubmitRequest({required this.path, required this.payload});

  final String path;
  final Map<String, dynamic> payload;
}

class ChangxingJiadaService {
  ChangxingJiadaService._() : _tokenBinding = ChangxingTokenBinding();

  static final ChangxingJiadaService instance = ChangxingJiadaService._();

  static const _baseUrl = 'https://zhx.zjxu.edu.cn/api';
  static const _casLoginUrl = 'https://zhx.zjxu.edu.cn/api/cas_wap_login';
  static const _unifiedAuthLoginUrl = 'https://newca.zjxu.edu.cn/cas/login';

  /// token 的 owner 绑定 / 持久化（fail closed），见 [ChangxingTokenBinding]。
  final ChangxingTokenBinding _tokenBinding;

  bool get hasToken => _tokenBinding.hasToken;

  /// 读取归属当前统一认证账号的落盘 token；CAS 身份未就绪时不标记已恢复，
  /// 页面在身份就绪后会再次调用，仍能绑定到正确 owner。
  Future<void> restoreSession() => _tokenBinding.restore();

  Future<void> logout() => _tokenBinding.clear();

  /// 测试用：新存储 key（单条 JSON envelope）。
  @visibleForTesting
  static const tokenStorageKeyV2 = ChangxingTokenBinding.storageKeyV2;

  /// 测试用：旧的无 owner key（一律按不可用处理）。
  @visibleForTesting
  static const legacyTokenStorageKey = ChangxingTokenBinding.legacyStorageKey;

  /// 通过 CAS SSO 登录畅行嘉大。
  /// 前提：用户已通过 UnifiedAuthService 完成一卡通登录，且当前处于校园网环境。
  /// 全程绑定发起时的 owner + `sessionRevision`：每个 await 边界之后复核，
  /// 任一环节发现身份变化即放弃，且**绝不**把旧身份的 token 写入新会话。
  Future<void> loginViaCas() async {
    final owner = _tokenBinding.currentOwner;
    final revisionAtStart = UnifiedAuthService.instance.sessionRevision;
    if (owner == null) {
      // 没有可信的统一认证身份：token 无归属可绑，不发起无主 SSO。
      throw ChangxingNeedUnifiedAuthException();
    }

    await DioClient.instance.ensureInitialized();
    final dio = DioClient.instance.unifiedAuthDio;

    void ensureIdentityCurrent() {
      if (_tokenBinding.isCurrent(owner, revisionAtStart)) return;
      AppLogger.instance.auth(LogLevel.warn, '畅行嘉大 CAS 登录放弃：统一认证身份或会话修订已变化');
      throw ChangxingCasLoginException('登录状态已变化，请重试');
    }

    ensureIdentityCurrent();

    try {
      // 发起 CAS 登录并在同一条重定向链里提取 tokenId，避免预校验消耗 ticket。
      var nextUrl = _casLoginUrl;
      String? tokenId;

      // WebVPN 网关会话未建立时，代理请求会被 302 到网关登录页，并一路走到
      // wengine-vpn-token-login；该页以 200 HTML 返回（浏览器里靠页面 JS 跳回
      // 原地址，dio 不会执行 JS），链路会在此断掉。记录被劫持前的地址，待
      // token 登录响应种下网关会话 cookie 后从原地址续走，否则首次进入必然
      // 拿不到 tokenId、第二次点击才能成功。
      String? hijackedUrl;

      for (var i = 0; i < 16; i++) {
        final response = await dio.get<String>(
          nextUrl,
          options: Options(
            followRedirects: false,
            validateStatus: (status) => status != null && status < 1000,
            responseType: ResponseType.plain,
          ),
        );
        ensureIdentityCurrent();

        final statusCode = response.statusCode ?? 0;
        final location = response.headers.value('location') ?? '';
        final body = response.data ?? '';

        if (statusCode >= 300 && statusCode < 400 && location.isNotEmpty) {
          final resolvedLocation = normalizeSsoRedirectUrl(
            _resolveRedirectUrl(nextUrl, location),
          );
          // 检查重定向 URL 中是否包含 tokenId
          final tid = _extractTokenId(resolvedLocation);
          if (tid != null) {
            tokenId = tid;
            break;
          }
          if (hijackedUrl == null &&
              (isWebVpnGatewayLoginPage(resolvedLocation) ||
                  isWebVpnTokenLoginUrl(resolvedLocation))) {
            hijackedUrl = nextUrl;
          }
          nextUrl = resolvedLocation;
          continue;
        }

        // 非重定向响应，检查最终 URL 是否包含 tokenId
        final finalUrl = normalizeSsoRedirectUrl(response.realUri.toString());
        final tid = _extractTokenId(finalUrl);
        if (tid != null) {
          tokenId = tid;
          break;
        }

        if (hijackedUrl != null && isWebVpnTokenLoginUrl(finalUrl)) {
          // 网关会话已随 200 响应建立，回到被劫持前的地址继续走链路。
          nextUrl = hijackedUrl;
          hijackedUrl = null;
          continue;
        }

        if (isUnifiedAuthLoginFormResponse(finalUrl, body)) {
          AppLogger.instance.auth(LogLevel.warn, '畅行嘉大：统一认证会话已失效，需要重新登录一卡通');
          throw ChangxingNeedUnifiedAuthException();
        }
        break;
      }

      if (tokenId == null || tokenId.isEmpty) {
        AppLogger.instance.auth(LogLevel.warn, '畅行嘉大：SSO 链路结束但未获取到 tokenId');
        throw ChangxingCasLoginException('畅行嘉大登录未完成，请稍后重试');
      }

      // 2. 用 tokenId 换取 JWT token
      final tokenResp = await dio.get<Map<String, dynamic>>(
        '$_baseUrl/getToken',
        queryParameters: {'tokenId': tokenId},
        options: Options(
          responseType: ResponseType.json,
          headers: {'token': '0'},
        ),
      );
      ensureIdentityCurrent();

      final json = tokenResp.data ?? <String, dynamic>{};
      final data = json['data'] as Map<String, dynamic>? ?? {};
      final code = data['code']?.toString() ?? '';
      if (code != '20000') {
        final msg = data['msg']?.toString() ?? '获取 token 失败';
        throw ChangxingCasLoginException(msg);
      }

      final jwtToken = data['token']?.toString().trim() ?? '';
      if (jwtToken.isEmpty) {
        throw ChangxingCasLoginException('CAS 认证成功但未获取到 token');
      }

      // 写入前最后一次复核：身份已变化则拒绝保存（含绑定 owner）。
      final saved = await _tokenBinding.saveIfCurrent(
        token: jwtToken,
        owner: owner,
        revision: revisionAtStart,
      );
      if (!saved) {
        AppLogger.instance.auth(LogLevel.warn, '畅行嘉大 CAS 登录放弃：写入前身份已变化');
        throw ChangxingCasLoginException('登录状态已变化，请重试');
      }
      AppLogger.instance.auth(LogLevel.info, '畅行嘉大 CAS SSO 登录成功');
    } on DioException catch (e) {
      AppLogger.instance.auth(
        LogLevel.error,
        '畅行嘉大 CAS 登录网络异常: ${e.type} ${e.message}',
      );
      throw ChangxingCasLoginException('网络异常：${e.message}');
    }
  }

  Future<ChangxingUserProfile> fetchUserProfile() async {
    final json = await _postJson('/user/getUserDetail', {});
    final code = _extractCode(json);
    if (code != '20000') {
      throw ChangxingCasLoginException(
        _extractMessage(json, fallback: '获取用户信息失败'),
      );
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
      throw ChangxingCasLoginException(
        _extractMessage(json, fallback: '获取申请列表失败'),
      );
    }
    final body = _extractDataMap(json)['body'] as Map<String, dynamic>? ?? {};
    final records = (body['records'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(ChangxingApplication.fromJson)
        .toList();
    return records;
  }

  Future<ChangxingApplicationDetail> fetchApplicationDetail(int id) async {
    final json = await _postForm('/approvalForm/getOne', {'id': '$id'});
    _ensureSuccess(json, fallback: '获取申请详情失败');
    final data = _extractDataMap(json)['data'] as Map<String, dynamic>? ?? {};
    return ChangxingApplicationDetail.fromJson(data);
  }

  Future<List<ChangxingAreaNode>> fetchAreaChildren(int parentId) async {
    final json = await _get(
      '/area/getChildArea',
      query: {'parentId': '$parentId'},
    );
    _ensureSuccess(json, fallback: '获取地区信息失败');
    final body =
        _extractDataMap(json)['body'] as List<dynamic>? ?? const <dynamic>[];
    return body
        .whereType<Map<String, dynamic>>()
        .map(ChangxingAreaNode.fromJson)
        .toList();
  }

  Future<List<ChangxingAreaNode>> fetchAreaParents(int areaId) async {
    final json = await _get(
      '/area/getParentArea',
      query: {'areaId': '$areaId'},
    );
    _ensureSuccess(json, fallback: '获取上级地区失败');
    final body =
        _extractDataMap(json)['body'] as List<dynamic>? ?? const <dynamic>[];
    return body
        .whereType<Map<String, dynamic>>()
        .map(ChangxingAreaNode.fromJson)
        .toList();
  }

  Future<bool> fetchFanxiaoEnableFlag() async {
    try {
      final json = await _get(
        '/dict/getDictList',
        query: {'labels': 'SYSTEM_LABEL_fanxiaoEnable', 'pageSize': '10000'},
      );
      final code = _extractCode(json);
      if (code != '20000') return false;
      final body = _extractDataMap(json)['body'] as Map<String, dynamic>? ?? {};
      final records = body['records'] as List<dynamic>? ?? const <dynamic>[];
      if (records.isEmpty) return false;
      final first = records.first as Map<String, dynamic>? ?? {};
      return first['ename']?.toString() == '1';
    } catch (_) {
      return false;
    }
  }

  Future<String?> fetchImageByMd5(String md5) async {
    if (md5.trim().isEmpty) return null;
    final json = await _get('/image/getOne', query: {'md5': md5.trim()});
    _ensureSuccess(json, fallback: '获取附件预览失败');
    final data = _extractDataMap(json)['data'] as Map<String, dynamic>? ?? {};
    final base64 = data['base64']?.toString().trim() ?? '';
    if (base64.isEmpty) return null;
    return 'data:image/png;base64,$base64';
  }

  Future<ChangxingUploadResult> uploadAttachment(
    String filePath,
    String fileName,
  ) async {
    // 调用方发起时的身份：文件准备（`await`）前后、发送之前都必须复核，
    // 绝不把 A 发起的附件以 B 的 token 发出。
    final entryOwner = _tokenBinding.currentOwner;
    final entryRevision = UnifiedAuthService.instance.sessionRevision;
    if (entryOwner == null) {
      throw ChangxingAuthExpiredException();
    }

    void ensureEntryIdentityCurrent() {
      if (_tokenBinding.isCurrent(entryOwner, entryRevision)) return;
      throw ChangxingAuthExpiredException('登录状态已变化，请重试');
    }

    await DioClient.instance.ensureInitialized();
    ensureEntryIdentityCurrent();

    await restoreSession();
    ensureEntryIdentityCurrent();
    if (!_tokenBinding.isBindingCurrent(entryOwner, entryRevision)) {
      throw ChangxingAuthExpiredException('登录状态已变化，请重试');
    }
    if (_tokenBinding.currentToken == null) {
      throw ChangxingAuthExpiredException();
    }

    final effectiveName = fileName.trim().isEmpty
        ? filePath.split(RegExp(r'[\\/]')).last
        : fileName.trim();
    final multipartFile = await MultipartFile.fromFile(
      filePath,
      filename: effectiveName,
    );

    // 文件准备之后、发送之前：再次复核身份与绑定，并使用复核后的 token。
    ensureEntryIdentityCurrent();
    final token = _tokenBinding.currentToken;
    if (token == null ||
        !_tokenBinding.isBindingCurrent(entryOwner, entryRevision)) {
      throw ChangxingAuthExpiredException('登录状态已变化，请重试');
    }

    final formData = FormData.fromMap({
      'valiFace': 'false',
      'file': multipartFile,
    });

    final response = await DioClient.instance.unifiedAuthDio
        .postUri<Map<String, dynamic>>(
          Uri.parse('https://zhx.zjxu.edu.cn/api/image/add/single'),
          data: formData,
          options: Options(
            headers: {'token': token},
            responseType: ResponseType.json,
          ),
        );

    final json = response.data ?? <String, dynamic>{};
    // 迟到结果守卫：等待期间身份 / token 绑定已变化，响应不属于当前会话。
    if (!_tokenBinding.isCurrent(entryOwner, entryRevision) ||
        !_tokenBinding.isBindingCurrent(entryOwner, entryRevision)) {
      throw ChangxingAuthExpiredException('登录状态已变化，请重试');
    }
    final code = _extractCode(json);
    if (code == '500001') {
      await _tokenBinding.clearIfCurrent(entryOwner, entryRevision);
      throw ChangxingAuthExpiredException(
        _extractMessage(json, fallback: '令牌错误，请重新登录'),
      );
    }
    _ensureSuccess(json, fallback: '上传附件失败');
    final data = _extractDataMap(json)['data'] as Map<String, dynamic>? ?? {};
    return ChangxingUploadResult(
      md5: data['md5']?.toString().trim() ?? '',
      base64: data['base64']?.toString().trim() ?? '',
    );
  }

  Future<void> submitLeaveRequest({
    int? id,
    required DateTime startTime,
    required DateTime endTime,
    required String descr,
    required int toAreaCode,
    required String toAddr,
    required String emergencyContact,
    required String emergencyPhone,
    required String userPhone,
    required List<String> trafficTools,
    String img = '',
    String annex = '',
  }) async {
    final request = buildLeaveRequestSubmitRequest(
      id: id,
      startTime: startTime,
      endTime: endTime,
      descr: descr,
      toAreaCode: toAreaCode,
      toAddr: toAddr,
      emergencyContact: emergencyContact,
      emergencyPhone: emergencyPhone,
      userPhone: userPhone,
      trafficTools: trafficTools,
      img: img,
      annex: annex,
    );
    final json = await _postJson(request.path, request.payload);
    _ensureSuccess(json, fallback: id == null ? '提交请假失败' : '修改请假失败');
  }

  Future<void> submitLeaveSchool({
    int? id,
    required DateTime startTime,
    required DateTime endTime,
    required String descr,
    required int toAreaCode,
    required String toAddr,
    required String emergencyContact,
    required String emergencyPhone,
    required String userPhone,
    required List<String> trafficTools,
  }) async {
    final request = buildLeaveSchoolSubmitRequest(
      id: id,
      startTime: startTime,
      endTime: endTime,
      descr: descr,
      toAreaCode: toAreaCode,
      toAddr: toAddr,
      emergencyContact: emergencyContact,
      emergencyPhone: emergencyPhone,
      userPhone: userPhone,
      trafficTools: trafficTools,
    );
    final json = await _postJson(request.path, request.payload);
    _ensureSuccess(json, fallback: id == null ? '提交离校失败' : '修改离校失败');
  }

  Future<void> submitBackSchool({
    int? id,
    required String userPhone,
    required DateTime startTime,
    required String trafficTool,
    required String trafficDetail,
    required String nativePlace,
    required int fromAreaCode,
    required String emergencyContact,
    required String emergencyPhone,
    required int backStatus,
    required String notBackReason,
    String img = '',
    String annex = '',
  }) async {
    final request = buildBackSchoolSubmitRequest(
      id: id,
      userPhone: userPhone,
      startTime: startTime,
      trafficTool: trafficTool,
      trafficDetail: trafficDetail,
      nativePlace: nativePlace,
      fromAreaCode: fromAreaCode,
      emergencyContact: emergencyContact,
      emergencyPhone: emergencyPhone,
      backStatus: backStatus,
      notBackReason: notBackReason,
      img: img,
      annex: annex,
    );
    final json = await _postJson(request.path, request.payload);
    _ensureSuccess(json, fallback: id == null ? '提交返校失败' : '修改返校失败');
  }

  Future<void> submitOvertime({int? id, required String descr}) async {
    final request = buildOvertimeSubmitRequest(id: id, descr: descr);
    final json = await _postJson(request.path, request.payload);
    _ensureSuccess(json, fallback: id == null ? '提交超时失败' : '修改超时失败');
  }

  /// 提交体里的时间统一为本地墙钟 `yyyy-MM-dd HH:mm:ss` 字符串。
  ///
  /// `DateTime` 不能被 `jsonEncode` 直接序列化（会抛 `JsonUnsupportedObjectError`），
  /// 且服务端读到的时间是不带时区的墙钟。格式与服务端返回值（`DateTime.tryParse`
  /// 可解析）同构；尚未对真实服务端做设备端到端验证。
  @visibleForTesting
  static String formatSubmitTime(DateTime value) {
    String two(int n) => n.toString().padLeft(2, '0');
    final local = value.toLocal();
    return '${local.year.toString().padLeft(4, '0')}-${two(local.month)}-'
        '${two(local.day)} ${two(local.hour)}:${two(local.minute)}:'
        '${two(local.second)}';
  }

  @visibleForTesting
  static ChangxingSubmitRequest buildLeaveRequestSubmitRequest({
    int? id,
    required DateTime startTime,
    required DateTime endTime,
    required String descr,
    required int toAreaCode,
    required String toAddr,
    required String emergencyContact,
    required String emergencyPhone,
    required String userPhone,
    required List<String> trafficTools,
    String img = '',
    String annex = '',
  }) {
    final payload = <String, dynamic>{
      'startTime': formatSubmitTime(startTime),
      'endTime': formatSubmitTime(endTime),
      'descr': descr,
      'toAreaCode': toAreaCode,
      'toAddr': toAddr,
      'emergencyContact': emergencyContact,
      'emergencyPhone': emergencyPhone,
      'userPhone': userPhone,
      'trafficTool': trafficTools.join(','),
      'img': img,
      'annex': annex,
      'type': 1,
    };
    if (id != null) payload['id'] = id;
    return ChangxingSubmitRequest(
      path: id == null ? '/approvalForm/qingjia/add' : '/approvalForm/edit',
      payload: payload,
    );
  }

  @visibleForTesting
  static ChangxingSubmitRequest buildLeaveSchoolSubmitRequest({
    int? id,
    required DateTime startTime,
    required DateTime endTime,
    required String descr,
    required int toAreaCode,
    required String toAddr,
    required String emergencyContact,
    required String emergencyPhone,
    required String userPhone,
    required List<String> trafficTools,
  }) {
    final payload = <String, dynamic>{
      'startTime': formatSubmitTime(startTime),
      'endTime': formatSubmitTime(endTime),
      'descr': descr,
      'toAreaCode': toAreaCode,
      'toAddr': toAddr,
      'emergencyContact': emergencyContact,
      'emergencyPhone': emergencyPhone,
      'userPhone': userPhone,
      'trafficTool': trafficTools.join(','),
      'type': 2,
    };
    if (id != null) payload['id'] = id;
    return ChangxingSubmitRequest(
      path: id == null ? '/approvalForm/lixiao/add' : '/approvalForm/edit',
      payload: payload,
    );
  }

  @visibleForTesting
  static ChangxingSubmitRequest buildBackSchoolSubmitRequest({
    int? id,
    required String userPhone,
    required DateTime startTime,
    required String trafficTool,
    required String trafficDetail,
    required String nativePlace,
    required int fromAreaCode,
    required String emergencyContact,
    required String emergencyPhone,
    required int backStatus,
    required String notBackReason,
    String img = '',
    String annex = '',
  }) {
    final payload = <String, dynamic>{
      'userPhone': userPhone,
      'startTime': formatSubmitTime(startTime),
      'trafficTool': trafficTool,
      'trafficDetail': trafficDetail,
      'nativePlace': nativePlace,
      'fromAreaCode': fromAreaCode,
      'emergencyContact': emergencyContact,
      'emergencyPhone': emergencyPhone,
      'backStatus': backStatus,
      'notBackReason': notBackReason,
      'img': img,
      'annex': annex,
      'type': 3,
    };
    if (id != null) payload['id'] = id;
    return ChangxingSubmitRequest(
      path: id == null ? '/approvalForm/fanxiao/add' : '/approvalForm/edit',
      payload: payload,
    );
  }

  @visibleForTesting
  static ChangxingSubmitRequest buildOvertimeSubmitRequest({
    int? id,
    required String descr,
  }) {
    final payload = <String, dynamic>{'type': 4, 'descr': descr};
    if (id != null) payload['id'] = id;
    return ChangxingSubmitRequest(
      path: '/approvalForm/overtime/add',
      payload: payload,
    );
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
    Map<String, dynamic> body, {
    bool requiresToken = true,
  }) async {
    return _request(
      path: path,
      method: 'POST',
      requiresToken: requiresToken,
      data: body,
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
    // 调用方发起时的身份：必须在任何 await 之前捕获。A 发起的请求（含表单
    // payload）在 ensureInitialized / restoreSession 期间身份切到 B 之后，
    // 绝不允许以 B 的 token 继续发出。
    final entryOwner = _tokenBinding.currentOwner;
    final entryRevision = UnifiedAuthService.instance.sessionRevision;
    final identityCaptured = requiresToken && entryOwner != null;

    void ensureEntryIdentityCurrent() {
      if (!identityCaptured) return;
      if (_tokenBinding.isCurrent(entryOwner, entryRevision)) return;
      throw ChangxingAuthExpiredException('登录状态已变化，请重试');
    }

    if (requiresToken && entryOwner == null) {
      // 没有可验证的调用方身份：与无 token 路径同分类，直接视为会话失效。
      throw ChangxingAuthExpiredException();
    }

    await DioClient.instance.ensureInitialized();
    ensureEntryIdentityCurrent();

    await restoreSession();
    ensureEntryIdentityCurrent();

    final token = _tokenBinding.currentToken;
    if (requiresToken && token == null) {
      // 无 token / token 归属与当前 CAS 身份不一致 / 绑定 revision 已漂移
      // 一律视为没有可用会话（分类保持原样）。
      throw ChangxingAuthExpiredException();
    }
    if (identityCaptured &&
        !_tokenBinding.isBindingCurrent(entryOwner, entryRevision)) {
      // restore 恢复出来的绑定不属于调用方身份（恢复期间换号）。
      throw ChangxingAuthExpiredException('登录状态已变化，请重试');
    }

    final uri = Uri.parse(
      Uri.parse('$_baseUrl$path').replace(queryParameters: query).toString(),
    );
    final headers = <String, String>{};
    if (requiresToken) {
      headers['token'] = token!;
    }

    // 发送前最后一次复核（URI / headers 构造是同步代码，无 await 间隙）：
    // 身份或绑定任一变化都不得把 A 的 payload 以 B 的 token 发出。
    ensureEntryIdentityCurrent();
    if (identityCaptured &&
        !_tokenBinding.isBindingCurrent(entryOwner, entryRevision)) {
      throw ChangxingAuthExpiredException('登录状态已变化，请重试');
    }

    final response = await DioClient.instance.unifiedAuthDio
        .requestUri<Map<String, dynamic>>(
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
    // 迟到结果守卫：等待期间身份 / token 绑定已变化，响应不属于当前会话，
    // 不得把旧身份数据返回给新会话；此后的 500001 也不得清掉新 token。
    if (identityCaptured &&
        (!_tokenBinding.isCurrent(entryOwner, entryRevision) ||
            !_tokenBinding.isBindingCurrent(entryOwner, entryRevision))) {
      throw ChangxingAuthExpiredException('登录状态已变化，请重试');
    }
    final code = _extractCode(json);
    if (code == '500001') {
      if (identityCaptured) {
        await _tokenBinding.clearIfCurrent(entryOwner, entryRevision);
      }
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

  void _ensureSuccess(Map<String, dynamic> json, {required String fallback}) {
    final code = _extractCode(json);
    if (code != '20000') {
      throw ChangxingCasLoginException(
        _extractMessage(json, fallback: fallback),
      );
    }
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

  String _resolveRedirectUrl(String baseUrl, String location) {
    if (location.startsWith('/') || !location.contains('://')) {
      return Uri.parse(baseUrl).resolve(location).toString();
    }
    return location;
  }

  String? _extractTokenId(String url) {
    final uri = Uri.tryParse(url);
    final tokenId = uri?.queryParameters['tokenId']?.trim() ?? '';
    return tokenId.isEmpty ? null : tokenId;
  }

  /// WebVPN 网关登录页：代理请求在网关会话缺失时会被 302 到这里。
  /// 网关自身 CAS 回跳（?cas_login=true&ticket=...）属于正常链路，不算劫持点。
  @visibleForTesting
  static bool isWebVpnGatewayLoginPage(String url) {
    final uri = Uri.tryParse(url);
    return uri != null &&
        uri.host.toLowerCase() == 'webvpn.zjxu.edu.cn' &&
        uri.path == '/login' &&
        uri.queryParameters.isEmpty;
  }

  /// WebVPN 网关会话引导页（wengine-vpn-token-login）：以 200 HTML 返回，
  /// 浏览器里靠页面 JS 跳回原地址；响应已种下网关会话 cookie。
  @visibleForTesting
  static bool isWebVpnTokenLoginUrl(String url) {
    final uri = Uri.tryParse(url);
    return uri != null &&
        uri.host.toLowerCase() == 'webvpn.zjxu.edu.cn' &&
        uri.path.toLowerCase().contains('wengine-vpn-token-login');
  }

  @visibleForTesting
  static String normalizeSsoRedirectUrl(String url) {
    final raw = url.trim();
    if (raw.isEmpty) return raw;

    final unwrappedUnifiedAuthUrl = _unwrapProxiedUnifiedAuthLoginUrl(raw);
    if (unwrappedUnifiedAuthUrl != null) {
      return unwrappedUnifiedAuthUrl;
    }

    final uri = Uri.tryParse(raw);
    if (uri == null) return raw;
    final host = uri.host.toLowerCase();
    if (host == 'zhx.zjxu.edu.cn' && uri.path.contains('/cas_login_back')) {
      return ZhengfangAuth.instance.buildWebVpnProxyUrl(raw);
    }
    return raw;
  }

  static String? _unwrapProxiedUnifiedAuthLoginUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.toLowerCase() != 'webvpn.zjxu.edu.cn') {
      return null;
    }

    if (!uri.path.toLowerCase().endsWith('/cas/login')) {
      return null;
    }

    final service = uri.queryParameters['service']?.trim() ?? '';
    if (service.isEmpty) return null;

    return Uri.parse(_unifiedAuthLoginUrl)
        .replace(queryParameters: uri.queryParameters)
        .toString();
  }

  @visibleForTesting
  static bool isUnifiedAuthLoginFormResponse(String url, String html) {
    final normalizedUrl = normalizeSsoRedirectUrl(url);
    return isUnifiedAuthLoginEntryUrl(normalizedUrl) &&
        looksLikeUnifiedAuthLoginHtml(html);
  }

  /// 测试用：以真实落盘格式（owner + token 单条 JSON）构造 envelope。
  @visibleForTesting
  static String encodeTokenEnvelope({
    required String owner,
    required String token,
  }) => ChangxingTokenBinding.encodeEnvelope(owner: owner, token: token);

  /// 测试用：当前内存绑定的 owner（无绑定 / 身份不符时为 null）。
  @visibleForTesting
  String? get debugBoundOwner => _tokenBinding.debugBoundOwner;

  /// 测试用：当前内存绑定对应的 `sessionRevision`（供断言同账号重登）。
  @visibleForTesting
  int? get debugBoundRevision => _tokenBinding.debugBoundRevision;

  @visibleForTesting
  void debugReset() => _tokenBinding.debugReset();
}
