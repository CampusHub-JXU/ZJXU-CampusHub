import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../core/auth/unified_auth.dart';
import '../../core/network/dio_client.dart';
import 'changxing_api_client.dart';
import 'changxing_cas_login.dart';
import 'changxing_jiada_exceptions.dart';
import 'changxing_jiada_model.dart';
import 'changxing_jiada_token_binding.dart';
import 'changxing_sso_urls.dart';
import 'changxing_submit_requests.dart' as submit;

export 'changxing_jiada_exceptions.dart';

/// 畅行嘉大服务门面：对外 API 与改造前一致。登录流程在
/// `changxing_cas_login.dart`，选路 / 请求管线在 `changxing_api_client.dart`，
/// 提交体构造在 `changxing_submit_requests.dart`，本文件只保留业务接口。
class ChangxingJiadaService {
  ChangxingJiadaService._() : this._with(ChangxingTokenBinding());

  ChangxingJiadaService._with(ChangxingTokenBinding binding)
    : _tokenBinding = binding,
      _api = ChangxingApiClient(binding) {
    _login = ChangxingCasLogin(_api);
  }

  static final ChangxingJiadaService instance = ChangxingJiadaService._();

  /// token 的 owner 绑定 / 持久化（fail closed），见 [ChangxingTokenBinding]。
  final ChangxingTokenBinding _tokenBinding;

  final ChangxingApiClient _api;

  late final ChangxingCasLogin _login;

  /// 测试用：缩短登录总预算（生产恒为 30 秒）。
  @visibleForTesting
  Duration? get debugLoginBudget => _login.debugLoginBudget;

  @visibleForTesting
  set debugLoginBudget(Duration? value) => _login.debugLoginBudget = value;

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
  /// 前提：用户已通过 UnifiedAuthService 完成一卡通登录；校内直连、校外经
  /// WebVPN 由 `CasRoutedAccess` 按目标 origin 选路（不读写全局模式）。
  /// 全程绑定发起时的 owner + `sessionRevision`，详见 [ChangxingCasLogin]。
  Future<void> loginViaCas() => _login.loginViaCas();

  Future<ChangxingUserProfile> fetchUserProfile() async {
    final json = await _api.postJson('/user/getUserDetail', {});
    final code = _api.extractCode(json);
    if (code != '20000') {
      throw ChangxingCasLoginException(
        _api.extractMessage(json, fallback: '获取用户信息失败'),
      );
    }
    final body =
        _api.extractDataMap(json)['body'] as Map<String, dynamic>? ?? {};
    return ChangxingUserProfile.fromJson(body);
  }

  Future<int> fetchUnreadCount() async {
    final json = await _api.get('/msg/getNoReadCount');
    final code = _api.extractCode(json);
    if (code != '20000') return 0;
    final data = _api.extractDataMap(json);
    final count = data['count'];
    if (count is int) return count;
    return int.tryParse(count?.toString() ?? '') ?? 0;
  }

  Future<List<ChangxingApplication>> fetchApplications({
    int page = 1,
    int pageSize = 20,
    int status = 999,
  }) async {
    final json = await _api.get(
      '/approvalForm/listPage/bystudent',
      query: {'current': '$page', 'pageSize': '$pageSize', 'status': '$status'},
    );
    final code = _api.extractCode(json);
    if (code != '20000') {
      throw ChangxingCasLoginException(
        _api.extractMessage(json, fallback: '获取申请列表失败'),
      );
    }
    final body =
        _api.extractDataMap(json)['body'] as Map<String, dynamic>? ?? {};
    final records = (body['records'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(ChangxingApplication.fromJson)
        .toList();
    return records;
  }

  Future<ChangxingApplicationDetail> fetchApplicationDetail(int id) async {
    final json = await _api.postForm('/approvalForm/getOne', {'id': '$id'});
    _api.ensureSuccess(json, fallback: '获取申请详情失败');
    final data =
        _api.extractDataMap(json)['data'] as Map<String, dynamic>? ?? {};
    return ChangxingApplicationDetail.fromJson(data);
  }

  Future<List<ChangxingAreaNode>> fetchAreaChildren(int parentId) async {
    final json = await _api.get(
      '/area/getChildArea',
      query: {'parentId': '$parentId'},
    );
    _api.ensureSuccess(json, fallback: '获取地区信息失败');
    final body =
        _api.extractDataMap(json)['body'] as List<dynamic>? ??
        const <dynamic>[];
    return body
        .whereType<Map<String, dynamic>>()
        .map(ChangxingAreaNode.fromJson)
        .toList();
  }

  Future<List<ChangxingAreaNode>> fetchAreaParents(int areaId) async {
    final json = await _api.get(
      '/area/getParentArea',
      query: {'areaId': '$areaId'},
    );
    _api.ensureSuccess(json, fallback: '获取上级地区失败');
    final body =
        _api.extractDataMap(json)['body'] as List<dynamic>? ??
        const <dynamic>[];
    return body
        .whereType<Map<String, dynamic>>()
        .map(ChangxingAreaNode.fromJson)
        .toList();
  }

  Future<bool> fetchFanxiaoEnableFlag() async {
    try {
      final json = await _api.get(
        '/dict/getDictList',
        query: {'labels': 'SYSTEM_LABEL_fanxiaoEnable', 'pageSize': '10000'},
      );
      final code = _api.extractCode(json);
      if (code != '20000') return false;
      final body =
          _api.extractDataMap(json)['body'] as Map<String, dynamic>? ?? {};
      final records = body['records'] as List<dynamic>? ?? const <dynamic>[];
      if (records.isEmpty) return false;
      final first = records.first as Map<String, dynamic>? ?? {};
      return first['ename']?.toString() == '1';
    } catch (_) {
      return false;
    }
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

    // 选路（首次 / 过期时会确认 CAS service 并补 WebVPN 网关会话）；
    // 之后再次复核身份，避免 A 发起的附件经 B 的路由 / token 发出。
    final route = await _api.routeForApi(entryOwner, entryRevision);
    ensureEntryIdentityCurrent();
    if (!_tokenBinding.isBindingCurrent(entryOwner, entryRevision)) {
      throw ChangxingAuthExpiredException('登录状态已变化，请重试');
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

    final response = await _api.sendApi(
      route,
      Uri.parse(route.url('${ChangxingApiClient.baseUrl}/image/add/single')),
      method: 'POST',
      data: formData,
      headers: {'token': token},
    );

    final Map<String, dynamic> json;
    try {
      json = _api.jsonOrBounce(response);
    } on ChangxingApiLoginBounce {
      _api.invalidateRouteLease();
      throw ChangxingAuthExpiredException();
    }
    // 迟到结果守卫：等待期间身份 / token 绑定已变化，响应不属于当前会话。
    if (!_tokenBinding.isCurrent(entryOwner, entryRevision) ||
        !_tokenBinding.isBindingCurrent(entryOwner, entryRevision)) {
      throw ChangxingAuthExpiredException('登录状态已变化，请重试');
    }
    final code = _api.extractCode(json);
    if (code == '500001') {
      await _tokenBinding.clearIfCurrent(entryOwner, entryRevision);
      throw ChangxingAuthExpiredException(
        _api.extractMessage(json, fallback: '令牌错误，请重新登录'),
      );
    }
    _api.ensureSuccess(json, fallback: '上传附件失败');
    final data =
        _api.extractDataMap(json)['data'] as Map<String, dynamic>? ?? {};
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
    final request = submit.buildLeaveRequestSubmitRequest(
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
    final json = await _api.postJson(request.path, request.payload);
    _api.ensureSuccess(json, fallback: id == null ? '提交请假失败' : '修改请假失败');
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
    final request = submit.buildLeaveSchoolSubmitRequest(
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
    final json = await _api.postJson(request.path, request.payload);
    _api.ensureSuccess(json, fallback: id == null ? '提交离校失败' : '修改离校失败');
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
    final request = submit.buildBackSchoolSubmitRequest(
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
    final json = await _api.postJson(request.path, request.payload);
    _api.ensureSuccess(json, fallback: id == null ? '提交返校失败' : '修改返校失败');
  }

  Future<void> submitOvertime({int? id, required String descr}) async {
    final request = submit.buildOvertimeSubmitRequest(id: id, descr: descr);
    final json = await _api.postJson(request.path, request.payload);
    _api.ensureSuccess(json, fallback: id == null ? '提交超时失败' : '修改超时失败');
  }

  /// 提交体里的时间统一为本地墙钟 `yyyy-MM-dd HH:mm:ss` 字符串，见
  /// [submit.formatSubmitTime]。
  @visibleForTesting
  static String formatSubmitTime(DateTime value) =>
      submit.formatSubmitTime(value);

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
  }) => submit.buildLeaveRequestSubmitRequest(
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
  }) => submit.buildLeaveSchoolSubmitRequest(
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
  }) => submit.buildBackSchoolSubmitRequest(
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

  @visibleForTesting
  static ChangxingSubmitRequest buildOvertimeSubmitRequest({
    int? id,
    required String descr,
  }) => submit.buildOvertimeSubmitRequest(id: id, descr: descr);

  @visibleForTesting
  static String normalizeSsoRedirectUrl(String url) =>
      normalizeChangxingSsoRedirectUrl(url);

  @visibleForTesting
  static bool isUnifiedAuthLoginFormResponse(String url, String html) =>
      isChangxingUnifiedAuthLoginFormResponse(url, html);

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
  void debugReset() {
    _api.reset();
    _tokenBinding.debugReset();
  }
}
