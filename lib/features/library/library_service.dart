import 'package:dio/dio.dart';

import '../../core/network/dio_client.dart';
import 'library_models.dart';

/// 图书馆数据服务（PRD 0.7.0 §32–§34）。
///
/// 数据源是图书馆 SPA 背后的「汇图/知书」接口 `api.huitu.zhishulib.com`。
/// 2026-09-12 设备抓包 + 本机直连实测确认：
/// * 馆藏详情 `GET /book/detail?bid=&orgId=101&schoolId=0` **无需凭据**，
///   返回 `{bid, callNo, total, count, libraries[], isLogin}`；
/// * 借阅 `/user/borrows`、`/user/borrows/history` 需要
///   `Authorization: Bearer <access_token>`（token 来自图书馆 WebView 里
///   Parse 用户对象的 `access_token`，尚未原生化）；
/// * `bid` 必须补零到 10 位，`1123876` 会 500 `book_not_exists`；
/// * `/book/search` 各种参数组合均 403，检索仍走 H5（PRD §33 允许）。
class LibraryService {
  LibraryService._();

  static final LibraryService instance = LibraryService._();

  static const String host = 'https://api.huitu.zhishulib.com';
  static const int orgId = 101;
  static const int schoolId = 0;

  /// 书目号补零到 10 位。
  static String padBid(String bid) => bid.padLeft(10, '0');

  /// 从图书馆 SPA 的书目详情链接里解析书目号。
  ///
  /// 实测形如 `.../Book/Index/bookDetail/id/1123876/b_id/0001123876`
  /// （WebVPN 前缀与查询串可省略）；识别不到返回 null，交回 WebView 继续。
  static String? bidFromDetailUrl(Uri uri) {
    final segments = uri.pathSegments;
    final bIdIndex = segments.indexOf('b_id');
    if (bIdIndex >= 0 && bIdIndex + 1 < segments.length) {
      final value = segments[bIdIndex + 1].trim();
      if (value.isNotEmpty) return value;
    }
    final idIndex = segments.indexOf('id');
    if (segments.contains('bookDetail') &&
        idIndex >= 0 &&
        idIndex + 1 < segments.length) {
      final value = segments[idIndex + 1].trim();
      if (value.isNotEmpty) return padBid(value);
    }
    return null;
  }

  /// 拉取馆藏详情（无需登录）。
  Future<LibraryBookDetail> fetchBookDetail(String bid) async {
    final trimmed = bid.trim();
    if (trimmed.isEmpty) {
      throw const LibraryApiException('缺少书目号');
    }
    await DioClient.instance.ensureInitialized();
    final response = await DioClient.instance.dio.get<Object?>(
      '$host/book/detail',
      queryParameters: <String, Object?>{
        'bid': padBid(trimmed),
        'orgId': orgId,
        'schoolId': schoolId,
      },
    );
    final detail = LibraryBookDetail.fromJson(response.data);
    if (detail == null) {
      throw const LibraryApiException('馆藏信息解析失败');
    }
    return detail;
  }

  /// 拉取当前借阅（[history] 为 true 时拉历史借阅）。
  Future<LibraryBorrowPage> fetchBorrows({
    required String accessToken,
    bool history = false,
  }) async {
    final token = accessToken.trim();
    if (token.isEmpty) {
      throw const LibraryApiException('缺少图书馆登录凭据');
    }
    await DioClient.instance.ensureInitialized();
    final response = await DioClient.instance.dio.get<Object?>(
      history ? '$host/user/borrows/history' : '$host/user/borrows',
      queryParameters: <String, Object?>{
        'orgId': orgId,
        'schoolId': schoolId,
      },
      options: Options(
        headers: <String, Object?>{'Authorization': 'Bearer $token'},
      ),
    );
    return LibraryBorrowPage.fromJson(response.data);
  }
}
