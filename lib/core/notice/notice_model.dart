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
