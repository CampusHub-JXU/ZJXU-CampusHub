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

/// 原生阅读的表格块：按单元格保留起始坐标与跨度，忠实还原 rowspan /
/// colspan / th 表头语义。
///
/// 解析阶段就完成占用矩阵与边界检查：结构过于复杂、跨度不可靠或超出上限的
/// 表格 [supported] 为 false，页面据此回退原网页，而不是硬画错位内容。
@immutable
class NoticeTable extends NoticeBlock {
  const NoticeTable({
    required this.rowCount,
    required this.columnCount,
    required this.cells,
    this.supported = true,
  });

  /// 无法在原生渲染器中忠实还原（嵌套表格、畸形跨度等）时的占位块。
  const NoticeTable.unsupported()
    : rowCount = 0,
      columnCount = 0,
      cells = const [],
      supported = false;

  final int rowCount;
  final int columnCount;

  /// 单元格按源码顺序排列；每个单元格带起始行列与跨度。
  final List<NoticeTableCell> cells;

  /// 原生阅读页是否可忠实渲染该表格。
  final bool supported;

  /// 是否存在 `<th>` 表头单元格。
  bool get hasHeaderCells => cells.any((c) => c.header);
}

/// 单个表格单元格：起始坐标 + 跨度 + 富文本（保留段内换行与字体样式）。
@immutable
class NoticeTableCell {
  const NoticeTableCell({
    required this.row,
    required this.column,
    required this.rowSpan,
    required this.columnSpan,
    required this.spans,
    required this.header,
  });

  /// 起始行（0 基）。
  final int row;

  /// 起始列（0 基）。
  final int column;

  final int rowSpan;
  final int columnSpan;

  /// 单元格文本带内联样式；段落 / `<br>` 之间以 `\n` 分隔。
  final List<NoticeSpan> spans;

  /// 来自 `<th>`：表头语义（加粗 + 表头底色 + 无障碍 header）。
  final bool header;

  String get plainText => spans.map((s) => s.text).join();
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

// 表格解析上限：超过即视为不可靠，回退原网页（避免畸形 HTML 无限扩张 / 卡死）。
const _tableMaxRows = 200;
const _tableMaxColumns = 64;
const _tableMaxCells = 4000;
const _tableMaxSpan = 200;

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

  /// 解析 `<table>` 为带坐标/跨度的单元格。占用矩阵 + 边界检查全部在这里
  /// 完成：结构不可靠（嵌套表格、畸形跨度、冲突/超限）返回
  /// [NoticeTable.unsupported] 交由页面回退原网页，绝不静默错位或丢单元格。
  NoticeTable? _table(Element node) {
    final trs = <Element>[];
    for (final tr in node.querySelectorAll('tr')) {
      // 嵌套表格的行归外层单元格文本，不单独成行。
      if (_closestTable(tr) != node) continue;
      trs.add(tr);
    }
    if (trs.isEmpty) return null;
    if (trs.length > _tableMaxRows) return const NoticeTable.unsupported();

    // 占用矩阵：occupied[r][c] = 该槽位所属单元格下标，-1 / 越界表示空闲。
    final occupied = <List<int>>[];
    bool isFree(int r, int c) =>
        r >= occupied.length || c >= occupied[r].length || occupied[r][c] < 0;
    void occupy(int r, int c, int index) {
      while (occupied.length <= r) {
        occupied.add(<int>[]);
      }
      final row = occupied[r];
      while (row.length <= c) {
        row.add(-1);
      }
      row[c] = index;
    }

    final cells = <NoticeTableCell>[];
    for (var r = 0; r < trs.length; r++) {
      var c = 0;
      for (final cell in trs[r].children) {
        final tag = cell.localName;
        if (tag != 'td' && tag != 'th') continue;
        // 跳过被上方 rowspan 占用的列。
        while (!isFree(r, c)) {
          c++;
          if (c > _tableMaxColumns) return const NoticeTable.unsupported();
        }

        final rowSpan = _spanOf(cell, 'rowspan');
        final columnSpan = _spanOf(cell, 'colspan');
        // 非数字 / 非正 / 超上限的跨度不可靠，整表回退而非按 1 猜。
        if (rowSpan == null || columnSpan == null) {
          return const NoticeTable.unsupported();
        }
        // 单元格内再嵌表格：原生无法忠实还原，明确不支持。
        if (cell.querySelector('table') != null) {
          return const NoticeTable.unsupported();
        }
        // 浏览器会把超出剩余行数的 rowspan 收敛到最后一行，这里同样 clamp，
        // 既贴合真实排版，也避免渲染器访问越界的行偏移。
        final effectiveRowSpan = rowSpan > trs.length - r
            ? trs.length - r
            : rowSpan;
        if (c + columnSpan > _tableMaxColumns) {
          return const NoticeTable.unsupported();
        }
        // 冲突检测：跨度覆盖的所有槽位必须空闲。
        for (var rr = r; rr < r + effectiveRowSpan; rr++) {
          for (var cc = c; cc < c + columnSpan; cc++) {
            if (!isFree(rr, cc)) return const NoticeTable.unsupported();
          }
        }
        if (cells.length >= _tableMaxCells) {
          return const NoticeTable.unsupported();
        }

        final index = cells.length;
        cells.add(
          NoticeTableCell(
            row: r,
            column: c,
            rowSpan: effectiveRowSpan,
            columnSpan: columnSpan,
            spans: _cellSpans(cell, base),
            header: tag == 'th',
          ),
        );
        for (var rr = r; rr < r + effectiveRowSpan; rr++) {
          for (var cc = c; cc < c + columnSpan; cc++) {
            occupy(rr, cc, index);
          }
        }
        c += columnSpan;
      }
    }

    if (cells.isEmpty || cells.every((cell) => cell.plainText.trim().isEmpty)) {
      return null;
    }
    var columnCount = 0;
    for (final cell in cells) {
      final end = cell.column + cell.columnSpan;
      if (end > columnCount) columnCount = end;
    }
    return NoticeTable(
      rowCount: trs.length,
      columnCount: columnCount,
      cells: List.unmodifiable(cells),
    );
  }
}

/// 解析 rowspan/colspan：缺省或空串按 1；非数字 / 非正 / 超上限返回 null，
/// 由调用方把整表判为不可靠并回退原网页（不静默按 1 处理以免错位）。
int? _spanOf(Element cell, String name) {
  final raw = cell.attributes[name]?.trim();
  if (raw == null || raw.isEmpty) return 1;
  final value = int.tryParse(raw);
  if (value == null || value < 1 || value > _tableMaxSpan) return null;
  return value;
}

/// 单元格富文本：复用正文的行内样式收集器，段落 / `<br>` 之间以 `\n` 连接。
List<NoticeSpan> _cellSpans(Element cell, Uri base) {
  final blocks = <NoticeBlock>[];
  _BlockCollector(base, blocks).collectChildren(cell);
  final spans = <NoticeSpan>[];
  for (final block in blocks) {
    if (block is! NoticeParagraph) continue;
    if (spans.isNotEmpty) spans.add(const NoticeSpan('\n'));
    spans.addAll(block.spans);
  }
  return spans;
}

Element? _closestTable(Element element) {
  Element? current = element.parent;
  while (current != null && current.localName != 'table') {
    current = current.parent;
  }
  return current;
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
