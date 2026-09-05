/// 教务处通知条目。
class Notice {
  const Notice({
    required this.title,
    required this.url,
    required this.category,
    this.date,
  });

  final String title;
  final String url;

  /// 栏目分类，如 '通知公告'。
  final String category;

  /// 发布日期文本（页面原样截取），如 '2026-04-02'。
  final String? date;

  static final RegExp _dateTextPattern = RegExp(
    r'^(\d{4})[-./](\d{1,2})[-./](\d{1,2})$',
  );

  /// 解析后的发布日期；缺失或格式异常返回 null。兼容 '/'、'.' 分隔与
  /// 非补零写法（与列表解析器的规范化规则一致）。
  DateTime? get parsedDate {
    final text = (date ?? '').trim();
    if (text.isEmpty) return null;
    final parts = _dateTextPattern.firstMatch(text);
    if (parts == null) return DateTime.tryParse(text);
    return DateTime.tryParse(
      '${parts.group(1)}-${parts.group(2)!.padLeft(2, '0')}-'
      '${parts.group(3)!.padLeft(2, '0')}',
    );
  }

  /// 按发布日期倒序比较（新 → 旧）；缺日期视为最旧沉底。
  /// 仅用于排序键，同日期的先后由稳定排序保证。
  static int compareByDateDesc(Notice a, Notice b) {
    final da = a.parsedDate;
    final db = b.parsedDate;
    if (da == null && db == null) return 0;
    if (da == null) return 1;
    if (db == null) return -1;
    return db.compareTo(da);
  }

  /// 稳定按日期倒序排序（新 → 旧，缺日期沉底）。
  ///
  /// Dart 的 List.sort 不保证稳定，这里以原下标为次键显式稳定化：
  /// 同日期条目保持输入相对顺序（教务处列表的置顶/同日多条场景）。
  static List<Notice> sortByDateDescStable(Iterable<Notice> notices) {
    final list = notices.toList(growable: false);
    final decorated =
        <(int, Notice)>[for (var i = 0; i < list.length; i++) (i, list[i])]
          ..sort((a, b) {
            final byDate = compareByDateDesc(a.$2, b.$2);
            if (byDate != 0) return byDate;
            return a.$1.compareTo(b.$1);
          });
    return [for (final entry in decorated) entry.$2];
  }

  /// 稳定 ID：详情 URL 的 `wbnewsid`；URL 没有该参数时回退为完整 URL。
  ///
  /// 快照去重、未读、待播报全部以它为准，不依赖日期或列表位置
  /// （抗置顶、重排）。不用 hashCode 做回退——它跨进程不稳定，
  /// 会破坏持久化快照的去重。
  String get id {
    final newsId = Uri.tryParse(url)?.queryParameters['wbnewsid']?.trim();
    if (newsId != null && newsId.isNotEmpty) return newsId;
    return url;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'title': title,
    'url': url,
    'category': category,
    if (date != null) 'date': date,
  };

  /// 解析失败返回 null，调用方按脏数据丢弃。
  static Notice? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final title = raw['title']?.toString() ?? '';
    final url = raw['url']?.toString() ?? '';
    if (title.isEmpty || url.isEmpty) return null;
    return Notice(
      title: title,
      url: url,
      category: raw['category']?.toString() ?? '通知公告',
      date: raw['date']?.toString(),
    );
  }

  @override
  bool operator ==(Object other) => other is Notice && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
