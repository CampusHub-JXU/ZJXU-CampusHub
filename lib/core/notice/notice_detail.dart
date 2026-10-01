import 'package:flutter/foundation.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

/// 教务处（jwc.zjxu.edu.cn，博达 VSB 站群）公告详情的原生阅读模型。
///
/// 站点没有移动版（无 viewport、模板 `_hiddenMobile = true`），WebView
/// 只能缩放桌面页；这里把正文抽成结构化块交给原生页面排版。解析只认
/// 已抓包确认的模板结构（`.newsDetail .title` / `.newsInfo` /
/// `#vsb_content .v_news_content` / `DownloadAttachUrl` 附件），结构缺失即
/// 返回 null，调用方回退原网页，不猜测内容。
@immutable
class NoticeDetail {
  const NoticeDetail({
    required this.url,
    required this.title,
    required this.blocks,
    required this.attachments,
    this.publishedAt,
    this.source,
  });

  final String url;
  final String title;

  /// 发表时间，规范化为 `yyyy-MM-dd HH:mm`；缺失为 null。
  final String? publishedAt;

  /// 来源（多数公告为空）。
  final String? source;

  final List<NoticeBlock> blocks;
  final List<NoticeAttachment> attachments;
}

@immutable
class NoticeAttachment {
  const NoticeAttachment({required this.name, required this.url});

  final String name;
  final String url;
}

/// 正文块。
@immutable
sealed class NoticeBlock {
  const NoticeBlock();
}

enum NoticeAlign { start, center, end }

@immutable
class NoticeParagraph extends NoticeBlock {
  const NoticeParagraph(
    this.spans, {
    this.indent = false,
    this.align = NoticeAlign.start,
  });

  final List<NoticeSpan> spans;

  /// 原文带首行缩进（`text-indent`）。
  final bool indent;
  final NoticeAlign align;

  String get plainText => spans.map((s) => s.text).join();
}

@immutable
class NoticeSpan {
  const NoticeSpan(
    this.text, {
    this.bold = false,
    this.emphasis = false,
    this.link,
  });

  final String text;
  final bool bold;

  /// 原文用红色强调（截止时间、「逾期不接受」之类）。
  final bool emphasis;

  /// 绝对链接；null 表示普通文本。
  final String? link;
}

@immutable
class NoticeImage extends NoticeBlock {
  const NoticeImage(this.url, {this.width, this.height});

  final String url;
  final double? width;
  final double? height;
}

@immutable
class NoticeTable extends NoticeBlock {
  const NoticeTable(this.rows, {required this.hasMergedCells});

  /// 行 → 单元格纯文本（单元格内多段以换行连接）。
  final List<List<String>> rows;

  /// 存在 rowspan/colspan 合并单元格：原生网格无法忠实还原，页面应引导
  /// 查看原网页而不是画出错位的表。
  final bool hasMergedCells;
}

/// 是否为可原生阅读的教务处公告详情 URL（`content.jsp` 或静态
/// `info/<栏目>/<id>.htm`）。其余站点 / 页面仍走 WebView。
bool isJwcNoticeDetailUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.toLowerCase() != 'jwc.zjxu.edu.cn') return false;
  final path = uri.path;
  return path == '/content.jsp' ||
      RegExp(r'^/info/\d+/\d+\.htm$').hasMatch(path);
}

/// 是否为教务处附件下载 URL：必须是 `https://jwc.zjxu.edu.cn`（默认端口、无
/// 用户信息）上的 `DownloadAttachUrl` 链接。只有命中才当作附件，并允许把统一
/// 认证 CookieJar 的 Cookie 注入下载请求；其它主机一律不当附件、不带 Cookie。
bool isJwcAttachmentUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  return uri.scheme == 'https' &&
      uri.host.toLowerCase() == 'jwc.zjxu.edu.cn' &&
      uri.userInfo.isEmpty &&
      (!uri.hasPort || uri.port == 443) &&
      url.contains('DownloadAttachUrl');
}

/// 解析详情页 HTML；模板结构缺失返回 null。
NoticeDetail? parseNoticeDetailHtml(String html, {required String pageUrl}) {
  final doc = html_parser.parse(html);
  final detail = doc.querySelector('.newsDetail');
  final content = doc.querySelector('#vsb_content .v_news_content');
  if (detail == null || content == null) return null;

  final title = _collapse(detail.querySelector('.title')?.text ?? '');
  if (title.isEmpty) return null;

  final base = Uri.parse(pageUrl);
  String? publishedAt;
  String? source;
  for (final info in detail.querySelectorAll('.leftInfo .newsInfo')) {
    final text = _collapse(info.text);
    if (text.startsWith('发表时间')) {
      publishedAt = _normalizePublishedAt(_afterColon(text));
    } else if (text.startsWith('来源')) {
      final value = _afterColon(text);
      source = value.isEmpty ? null : value;
    }
  }

  final blocks = <NoticeBlock>[];
  _BlockCollector(base, blocks).collectChildren(content);

  final attachments = <NoticeAttachment>[];
  final seen = <String>{};
  for (final link in detail.querySelectorAll('a[href]')) {
    final href = link.attributes['href']!.trim();
    if (!href.contains('DownloadAttachUrl')) continue;
    final url = _resolve(base, href);
    final name = _collapse(link.text);
    if (url == null || !isJwcAttachmentUrl(url)) continue;
    if (name.isEmpty || !seen.add(url)) continue;
    attachments.add(NoticeAttachment(name: name, url: url));
  }

  return NoticeDetail(
    url: pageUrl,
    title: title,
    publishedAt: publishedAt,
    source: source,
    blocks: List.unmodifiable(blocks),
    attachments: List.unmodifiable(attachments),
  );
}

String _afterColon(String text) {
  final index = text.indexOf(RegExp('[:：]'));
  return index < 0 ? '' : text.substring(index + 1).trim();
}

/// `26-09-18 10:26:49` → `2026-09-18 10:26`；其它格式原样保留。
String? _normalizePublishedAt(String raw) {
  if (raw.isEmpty) return null;
  final match = RegExp(
    r'^(\d{2}|\d{4})-(\d{1,2})-(\d{1,2})(?:\s+(\d{1,2}):(\d{2}))?',
  ).firstMatch(raw);
  if (match == null) return raw;
  final year = match.group(1)!.length == 2
      ? '20${match.group(1)}'
      : match.group(1)!;
  final date =
      '$year-${match.group(2)!.padLeft(2, '0')}-'
      '${match.group(3)!.padLeft(2, '0')}';
  final hour = match.group(4);
  return hour == null
      ? date
      : '$date ${hour.padLeft(2, '0')}:${match.group(5)}';
}

String _collapse(String text) =>
    text.replaceAll(' ', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

String? _resolve(Uri base, String href) {
  final lower = href.toLowerCase();
  if (href.isEmpty ||
      lower.startsWith('javascript:') ||
      lower.startsWith('#') ||
      lower.startsWith('mailto:')) {
    return null;
  }
  try {
    final uri = base.resolve(href);
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    return uri.toString();
  } on FormatException {
    return null;
  }
}

const _blockTags = {
  'p',
  'div',
  'section',
  'article',
  'blockquote',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'ul',
  'ol',
  'li',
  'center',
};

class _InlineStyle {
  const _InlineStyle({this.bold = false, this.emphasis = false, this.link});

  final bool bold;
  final bool emphasis;
  final String? link;

  _InlineStyle merge({bool? bold, bool? emphasis, String? link}) =>
      _InlineStyle(
        bold: bold ?? this.bold,
        emphasis: emphasis ?? this.emphasis,
        link: link ?? this.link,
      );
}

class _BlockCollector {
  _BlockCollector(this.base, this.out);

  final Uri base;
  final List<NoticeBlock> out;

  final List<NoticeSpan> _spans = [];
  bool _indent = false;
  NoticeAlign _align = NoticeAlign.start;

  void collectChildren(Element parent) {
    for (final node in parent.nodes) {
      _visit(node, const _InlineStyle());
    }
    _flush();
  }

  void _visit(Node node, _InlineStyle style) {
    if (node is Text) {
      _addText(node.text, style);
      return;
    }
    if (node is! Element) return;
    final tag = node.localName ?? '';
    switch (tag) {
      case 'script':
      case 'style':
        return;
      case 'br':
        _addText('\n', style);
        return;
      case 'img':
        _flush();
        final image = _image(node);
        if (image != null) out.add(image);
        return;
      case 'table':
        _flush();
        final table = _table(node);
        if (table != null) out.add(table);
        return;
    }

    if (_blockTags.contains(tag)) {
      _flush();
      _indent = _hasIndent(node);
      _align = _alignOf(node);
      final bold = tag.length == 2 && tag.startsWith('h') ? true : null;
      final prefix = tag == 'li' ? '• ' : null;
      if (prefix != null) _addText(prefix, style);
      for (final child in node.nodes) {
        _visit(child, style.merge(bold: bold));
      }
      _flush();
      return;
    }

    var next = style;
    if (tag == 'strong' || tag == 'b') next = next.merge(bold: true);
    if (_isEmphasisColor(node)) next = next.merge(emphasis: true);
    if (tag == 'a') {
      final href = node.attributes['href'];
      final link = href == null ? null : _resolve(base, href.trim());
      if (link != null) next = next.merge(link: link);
    }
    for (final child in node.nodes) {
      _visit(child, next);
    }
  }

  void _addText(String raw, _InlineStyle style) {
    // 源码换行是排版噪音，只有 <br> 传入的 '\n' 才是真换行。
    final text = raw == '\n'
        ? raw
        : raw.replaceAll(' ', ' ').replaceAll(RegExp(r'\s+'), ' ');
    if (text.isEmpty) return;
    if (_spans.isNotEmpty) {
      final last = _spans.last;
      if (last.bold == style.bold &&
          last.emphasis == style.emphasis &&
          last.link == style.link) {
        _spans[_spans.length - 1] = NoticeSpan(
          last.text + text,
          bold: last.bold,
          emphasis: last.emphasis,
          link: last.link,
        );
        return;
      }
    }
    _spans.add(
      NoticeSpan(
        text,
        bold: style.bold,
        emphasis: style.emphasis,
        link: style.link,
      ),
    );
  }

  void _flush() {
    if (_spans.isEmpty) return;
    final spans = _trimSpans(_spans);
    _spans.clear();
    if (spans.isNotEmpty) {
      out.add(NoticeParagraph(spans, indent: _indent, align: _align));
    }
    _indent = false;
    _align = NoticeAlign.start;
  }

  NoticeImage? _image(Element node) {
    final src = node.attributes['src']?.trim() ?? '';
    final url = _resolve(base, src);
    if (url == null) return null;
    return NoticeImage(
      url,
      width: _dimension(node, 'width'),
      height: _dimension(node, 'height'),
    );
  }

  NoticeTable? _table(Element node) {
    final rows = <List<String>>[];
    var merged = false;
    for (final tr in node.querySelectorAll('tr')) {
      // 嵌套表格的行归外层单元格文本，不单独成行。
      if (_closestTable(tr) != node) continue;
      final cells = <String>[];
      for (final cell in tr.children) {
        if (cell.localName != 'td' && cell.localName != 'th') continue;
        final rowSpan = int.tryParse(cell.attributes['rowspan'] ?? '') ?? 1;
        final colSpan = int.tryParse(cell.attributes['colspan'] ?? '') ?? 1;
        if (rowSpan > 1 || colSpan > 1) merged = true;
        cells.add(_cellText(cell));
      }
      if (cells.any((c) => c.isNotEmpty)) rows.add(cells);
    }
    if (rows.isEmpty) return null;
    final width = rows.map((r) => r.length).reduce((a, b) => a > b ? a : b);
    if (rows.any((r) => r.length != width)) merged = true;
    return NoticeTable(
      List.unmodifiable(rows.map(List<String>.unmodifiable)),
      hasMergedCells: merged,
    );
  }
}

Element? _closestTable(Element element) {
  Element? current = element.parent;
  while (current != null && current.localName != 'table') {
    current = current.parent;
  }
  return current;
}

String _cellText(Element cell) {
  final blocks = cell.querySelectorAll('p, div, li');
  if (blocks.isEmpty) return _collapse(cell.text);
  final lines = <String>[];
  for (final block in blocks) {
    if (block.querySelector('p, div, li') != null) continue;
    final text = _collapse(block.text);
    if (text.isNotEmpty) lines.add(text);
  }
  return lines.isEmpty ? _collapse(cell.text) : lines.join('\n');
}

List<NoticeSpan> _trimSpans(List<NoticeSpan> spans) {
  final result = List<NoticeSpan>.of(spans);
  NoticeSpan copy(NoticeSpan s, String text) =>
      NoticeSpan(text, bold: s.bold, emphasis: s.emphasis, link: s.link);
  while (result.isNotEmpty) {
    final trimmed = result.first.text.trimLeft();
    if (trimmed.isEmpty) {
      result.removeAt(0);
      continue;
    }
    result[0] = copy(result.first, trimmed);
    break;
  }
  while (result.isNotEmpty) {
    final trimmed = result.last.text.trimRight();
    if (trimmed.isEmpty) {
      result.removeLast();
      continue;
    }
    result[result.length - 1] = copy(result.last, trimmed);
    break;
  }
  return result;
}

String _style(Element node) =>
    (node.attributes['style'] ?? '').toLowerCase().replaceAll(' ', '');

bool _hasIndent(Element node) {
  final match = RegExp(r'text-indent:([\d.]+)').firstMatch(_style(node));
  return match != null && (double.tryParse(match.group(1)!) ?? 0) > 0;
}

NoticeAlign _alignOf(Element node) {
  final style = _style(node);
  final attr = (node.attributes['align'] ?? '').toLowerCase();
  if (style.contains('text-align:center') ||
      attr == 'center' ||
      node.localName == 'center') {
    return NoticeAlign.center;
  }
  if (style.contains('text-align:right') || attr == 'right') {
    return NoticeAlign.end;
  }
  return NoticeAlign.start;
}

double? _dimension(Element node, String name) {
  final attr = double.tryParse(node.attributes[name] ?? '');
  if (attr != null && attr > 0) return attr;
  final match = RegExp('(?:^|;)$name:([\\d.]+)px').firstMatch(_style(node));
  final value = match == null ? null : double.tryParse(match.group(1)!);
  return value != null && value > 0 ? value : null;
}

/// 红色系文字视为强调：`rgb(192,0,0)` / `#c00000` / `red` 等。
bool _isEmphasisColor(Element node) {
  final style = _style(node);
  final match = RegExp(r'(?:^|;)color:([^;]+)').firstMatch(style);
  final value =
      match?.group(1) ?? (node.attributes['color'] ?? '').toLowerCase();
  if (value.isEmpty) return false;
  if (value == 'red') return true;
  int? r, g, b;
  final rgb = RegExp(r'rgb\((\d+),(\d+),(\d+)').firstMatch(value);
  if (rgb != null) {
    r = int.parse(rgb.group(1)!);
    g = int.parse(rgb.group(2)!);
    b = int.parse(rgb.group(3)!);
  } else {
    final hex = RegExp(r'^#([0-9a-f]{6})$').firstMatch(value);
    if (hex == null) return false;
    final v = int.parse(hex.group(1)!, radix: 16);
    r = v >> 16 & 0xff;
    g = v >> 8 & 0xff;
    b = v & 0xff;
  }
  return r >= 150 && g < 90 && b < 90;
}
