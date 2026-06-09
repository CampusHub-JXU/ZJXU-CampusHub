import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../core/logging/app_logger.dart';
import '../../core/network/dio_client.dart';
import 'second_classroom_model.dart';

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
  SecondClassroomService({Dio? dio}) : _debugDio = dio;

  static final SecondClassroomService instance = SecondClassroomService();

  Dio? _debugDio;

  Future<SecondClassroomCatalog> fetchCatalog() async {
    final payload = await _post('/mobile/hdList', data: _menuData());
    return parseSecondClassroomCatalogPayload(payload);
  }

  Future<SecondClassroomActivityPage> searchActivities(
    SecondClassroomActivityQuery query,
  ) async {
    final payload = await _post(
      '/mobile/search',
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

  Future<SecondClassroomActivityDetail> fetchActivityDetail(int id) async {
    final payload = await _post(
      '/mobile/detail',
      queryParameters: {'hdId': '$id', '.me': _secondClassroomMenuToken},
      data: _menuData(),
    );
    return parseSecondClassroomActivityDetailPayload(payload);
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
  }) async {
    final dio = await _resolveDio();
    final uri = Uri.https(
      _secondClassroomHost,
      '$_secondClassroomBasePath$path',
      queryParameters,
    );

    try {
      final response = await dio.post<Object?>(
        uri.toString(),
        data: data,
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          responseType: ResponseType.json,
          followRedirects: true,
          headers: const {
            'Accept': 'application/json, text/plain, */*',
            'Origin': 'https://twdekt.zjxu.edu.cn',
            'Referer': _secondClassroomReferer,
            'X-Requested-With': 'XMLHttpRequest',
          },
          validateStatus: (status) => status != null && status < 500,
        ),
      );

      final payload = _payloadFromResponse(response.data);
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
    }
  }

  Future<Dio> _resolveDio() async {
    final debugDio = _debugDio;
    if (debugDio != null) return debugDio;

    await DioClient.instance.ensureInitialized();
    return DioClient.instance.dio;
  }

  Map<String, dynamic> _payloadFromResponse(Object? data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    if (data is String) {
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
    pageIndex: _intValue(payload['pageIndex']),
    pageSize: _intValue(payload['pageSize']),
    totalPages: _intValue(payload['totalPages']),
    count: _intValue(payload['count']),
  );
}

@visibleForTesting
SecondClassroomActivityDetail parseSecondClassroomActivityDetailPayload(
  Map<String, dynamic> payload,
) {
  return SecondClassroomActivityDetail.fromExtend(_mapValue(payload['extend']));
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

int _intValue(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}
