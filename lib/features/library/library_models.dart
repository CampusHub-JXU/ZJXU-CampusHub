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

/// 一条借阅记录（`GET /user/borrows`、`/user/borrows/history` 的 `items[]`）。
///
/// 字段来自图书馆 SPA 借阅行组件的 propTypes 与调用点（2026-09-12 反查
/// `app.es6.min.js`），不是推测；接口 Joi 校验通过 `orgId`/`schoolId`/`page`。
class LibraryBorrowItem {
  const LibraryBorrowItem({
    required this.bookName,
    required this.author,
    required this.desc,
    required this.bookImage,
    required this.borrowTime,
    required this.endTime,
    required this.returnTime,
    required this.infoDay,
    required this.overDay,
    required this.overTime,
    required this.renewId,
    required this.willEnd,
    required this.returnCode,
  });

  final String bookName;
  final String author;

  /// 两行副信息（索书号/出版社等）。
  final String desc;
  final String bookImage;

  /// 借入时间。
  final String borrowTime;

  /// 到期时间。
  final String endTime;

  /// 归还时间（历史借阅）。
  final String returnTime;

  /// 剩余天数。
  final int infoDay;

  /// 超期天数。
  final int overDay;

  final String overTime;

  /// 可续借时接口给出的 `renewID`，即 `POST /book/renew` 的 `cid`。
  final String renewId;

  /// `'1'` 表示即将到期。
  final String willEnd;

  /// 归还码。
  final String returnCode;

  bool get canRenew => renewId.isNotEmpty;

  bool get isOverdue => overDay > 0 || overTime.isNotEmpty;

  bool get isWillEnd => willEnd == '1';

  /// 到期提醒文案：超期优先，其次 1–3 天内到期。
  String? get dueHint {
    if (isOverdue) {
      return overDay > 0 ? '超期 $overDay 天' : '已超期';
    }
    if (infoDay > 0 && infoDay < 4) return '$infoDay 天后到期';
    return null;
  }

  static LibraryBorrowItem? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final name = _str(raw['bookName']);
    if (name.isEmpty) return null;
    return LibraryBorrowItem(
      bookName: name,
      author: _str(raw['author']),
      desc: _str(raw['desc']),
      bookImage: _str(raw['bookImage']),
      borrowTime: _str(raw['borrowTime']),
      endTime: _str(raw['endTime']),
      returnTime: _str(raw['returnTime']),
      infoDay: _int(raw['infoDay']),
      overDay: _int(raw['overDay']),
      overTime: _str(raw['overTime']),
      renewId: _str(raw['renewID']),
      willEnd: _str(raw['willEnd']),
      returnCode: _str(raw['returnCode']),
    );
  }
}

/// 借阅列表分页（`GET /user/borrows`、`/user/borrows/history`）。
///
/// 响应形如 `{items, page, pageSize, nextUrl}`；`nextUrl` 供 SPA 无限滚动，
/// 原生分页用 `page`/`pageSize` 即可。
class LibraryBorrowPage {
  const LibraryBorrowPage({
    required this.items,
    required this.page,
    required this.pageSize,
    required this.nextUrl,
  });

  final List<LibraryBorrowItem> items;
  final int page;
  final int pageSize;

  /// 下一页地址（无更多数据时为空）。
  final String nextUrl;

  bool get isEmpty => items.isEmpty;

  static LibraryBorrowPage fromJson(Object? raw) {
    if (raw is! Map) {
      return const LibraryBorrowPage(
        items: <LibraryBorrowItem>[],
        page: 1,
        pageSize: 0,
        nextUrl: '',
      );
    }
    final items = raw['items'];
    return LibraryBorrowPage(
      items: items is List
          ? items
                .map(LibraryBorrowItem.fromJson)
                .whereType<LibraryBorrowItem>()
                .toList(growable: false)
          : const <LibraryBorrowItem>[],
      page: _int(raw['page'], fallback: 1),
      pageSize: _int(raw['pageSize']),
      nextUrl: _str(raw['nextUrl']),
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
