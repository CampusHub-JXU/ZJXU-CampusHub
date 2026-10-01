import 'package:dio/dio.dart';

import '../auth/academic_auth_guard.dart';
import '../auth/zhengfang_auth.dart';

/// [postZhengfangQuery] 的结果：身份版本 receipt + 已通过校验的 `items` 列表。
class ZhengfangQueryResult {
  const ZhengfangQueryResult({required this.guarded, required this.items});

  final AcademicGuardedResponse<Map<String, dynamic>> guarded;
  final List<dynamic> items;
}

/// 正方「只读查询」POST 的共用流程（成绩 / 考试）。
///
/// 经 [AcademicAuthGuard.guardWithSession] 发送，保留有界再查询与身份 receipt
/// 语义；`su` 取 [owner]。返回前校验 receipt 的 account/epoch 与 [owner] 一致
/// （否则抛 [authExpiredException]）以及响应 200 且含 `items` 列表（否则抛
/// [unexpectedResponseException]）。
Future<ZhengfangQueryResult> postZhengfangQuery({
  required String path,
  required String gnmkdm,
  required String owner,
  required String formBody,
  required Object authExpiredException,
  required Object unexpectedResponseException,
}) async {
  final guarded =
      await AcademicAuthGuard.guardWithSession<Map<String, dynamic>>(
        authExpiredException: authExpiredException,
        request: () =>
            ZhengfangAuth.instance.academicDio.post<Map<String, dynamic>>(
              ZhengfangAuth.instance.buildPortalUrl(path),
              queryParameters: {
                'doType': 'query',
                'gnmkdm': gnmkdm,
                'su': owner,
              },
              data: formBody,
              options: Options(
                contentType: 'application/x-www-form-urlencoded',
                headers: {
                  'Referer': ZhengfangAuth.instance.academicServiceUrl,
                  'X-Requested-With': 'XMLHttpRequest',
                },
              ),
            ),
      );
  if (guarded.account != owner || guarded.epoch == null) {
    throw authExpiredException;
  }
  final items = guarded.response.data?['items'];
  if (guarded.response.statusCode != 200 || items is! List) {
    throw unexpectedResponseException;
  }
  return ZhengfangQueryResult(guarded: guarded, items: items);
}
