/// 图书馆（汇图/知书 huitu.zhishulib.com）接口的数据模型。
///
/// 字段来源是 2026-09-12 设备抓包实测的响应结构，不做推测：
/// `GET /book/detail` →
/// `{bid, callNo, total, count, libraries:[{group, groupName, location,
/// locationName, count, total, cids[], shelfNo}], isLogin}`。
library;

/// 一条馆藏位置记录（PRD 0.7.0 §34：馆藏位置 / 可借状态）。
class LibraryHolding {
  const LibraryHolding({
    required this.group,
    required this.groupName,
    required this.location,
    required this.locationName,
    required this.count,
    required this.total,
    required this.cids,
    required this.shelfNo,
  });

  /// 馆藏地代码，例如 `0011`。
  final String group;

  /// 馆藏地名称，例如 `嘉兴学院图书馆`。
  final String groupName;

  /// 书库/阅览室代码，例如 `00088`。
  final String location;

  /// 书库/阅览室名称，例如 `密集书库`。
  final String locationName;

  /// 可借册数。
  final int count;

  /// 馆藏册数。
  final int total;

  /// 条码号列表。
  final List<String> cids;

  /// 索书号，例如 `L0001845`。
  final String shelfNo;

  bool get hasAvailable => count > 0;

  static LibraryHolding? fromJson(Object? raw) {
    if (raw is! Map) return null;
    return LibraryHolding(
      group: _str(raw['group']),
      groupName: _str(raw['groupName']),
      location: _str(raw['location']),
      locationName: _str(raw['locationName']),
      count: _int(raw['count']),
      total: _int(raw['total']),
      cids: raw['cids'] is List
          ? (raw['cids']! as List).map(_str).toList(growable: false)
          : const <String>[],
      shelfNo: _str(raw['shelfNo']),
    );
  }
}

/// 一本书的馆藏详情。
class LibraryBookDetail {
  const LibraryBookDetail({
    required this.bid,
    required this.callNo,
    required this.total,
    required this.count,
    required this.libraries,
  });

  /// 书目号（接口要求补零到 10 位，如 `0001123876`）。
  final String bid;

  /// 索书号，例如 `TS974.14/51`。
  final String callNo;

  /// 馆藏总册数。
  final int total;

  /// 可借总册数。
  final int count;

  final List<LibraryHolding> libraries;

  bool get hasAvailable => count > 0;

  /// 一句话馆藏摘要，例如 `密集书库 4/4 · 索书号 L0001845`。
  String get summary {
    if (libraries.isEmpty) return '暂无馆藏信息';
    final first = libraries.first;
    final place = first.locationName.isEmpty
        ? first.groupName
        : first.locationName;
    final parts = <String>['$place ${first.count}/${first.total}'];
    if (first.shelfNo.isNotEmpty) parts.add('索书号 ${first.shelfNo}');
    return parts.join(' · ');
  }

  static LibraryBookDetail? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final bid = _str(raw['bid']);
    if (bid.isEmpty) return null;
    return LibraryBookDetail(
      bid: bid,
      callNo: _str(raw['callNo']),
      total: _int(raw['total']),
      count: _int(raw['count']),
      libraries: raw['libraries'] is List
          ? (raw['libraries']! as List)
                .map(LibraryHolding.fromJson)
                .whereType<LibraryHolding>()
                .toList(growable: false)
          : const <LibraryHolding>[],
    );
  }
}

/// 借阅列表分页（`GET /user/borrows`、`/user/borrows/history`）。
///
/// 抓包时该账号没有借阅，响应为 `{items: [], page, pageSize}`，因此条目字段
/// 尚未实测，这里保留原始映射，等有真实借阅记录（或逆出字段）再建类型模型。
class LibraryBorrowPage {
  const LibraryBorrowPage({
    required this.items,
    required this.page,
    required this.pageSize,
  });

  final List<Map<String, Object?>> items;
  final int page;
  final int pageSize;

  bool get isEmpty => items.isEmpty;

  static LibraryBorrowPage fromJson(Object? raw) {
    if (raw is! Map) {
      return const LibraryBorrowPage(
        items: <Map<String, Object?>>[],
        page: 1,
        pageSize: 0,
      );
    }
    final items = raw['items'];
    return LibraryBorrowPage(
      items: items is List
          ? items
                .whereType<Map>()
                .map((e) => e.cast<String, Object?>())
                .toList(growable: false)
          : const <Map<String, Object?>>[],
      page: _int(raw['page'], fallback: 1),
      pageSize: _int(raw['pageSize']),
    );
  }
}

/// 图书馆接口返回异常。
class LibraryApiException implements Exception {
  const LibraryApiException(this.message);

  final String message;

  @override
  String toString() => 'LibraryApiException: $message';
}

String _str(Object? value) => value == null ? '' : value.toString();

int _int(Object? value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}
