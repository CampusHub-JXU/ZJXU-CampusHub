import 'dart:convert';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

import 'physical_test_model.dart';

/// 菜单页（`/weixin/main.jsp`）hidden 字段给出的身份。
///
/// [stuNo] 是服务端下发的 base64 学号原文，[schoolid] 是学校号；两者都只
/// 从页面读取，绝不硬编码。
typedef PhysicalTestIdentity = ({String stuNo, String schoolid});

/// 历年列表条目（学年 + 汇总分 + 尚未校验的明细链接）。
class PhysicalTestYearEntry {
  const PhysicalTestYearEntry({
    required this.academicYear,
    this.totalScore = '',
    this.grade = '',
    this.detailHref = '',
  });

  final String academicYear;
  final String totalScore;
  final String grade;

  /// 列表页原始 href；链接白名单校验与 URL 重建在 service 层完成。
  final String detailHref;
}

/// 解析菜单页身份字段。
///
/// 空值 / 字面 `null` / base64 编码的 `null`（`bnVsbA==`）都视为不可用
/// 身份并抛 [StateError]。
PhysicalTestIdentity parsePhysicalTestIdentity(String html) {
  final doc = html_parser.parse(html);
  final stuNo = _inputValue(doc, 'stuNo');
  final schoolid = _inputValue(doc, 'schoolid');
  if (!_isUsableIdentityValue(stuNo) || !_isUsableIdentityValue(schoolid)) {
    throw StateError('体测身份信息缺失，请重新登录后重试');
  }
  return (stuNo: stuNo, schoolid: schoolid);
}

/// 解析成绩页（`healthscore` 当前成绩与 `scoreDetails` 历年明细共用版式）。
///
/// 页面版式缺失（改版页、错误页）一律抛 [StateError]，绝不把解析失败当作
/// 「无成绩」返回。总分/等级取「成绩总分」行。
PhysicalTestRecord parsePhysicalTestScorePage(String html) {
  final doc = html_parser.parse(html);
  final table = _findTableContaining(doc, '体测项目');
  if (table == null) {
    throw StateError('体测成绩页面结构无法识别');
  }

  final items = <PhysicalTestItem>[];
  var totalScore = '';
  var grade = '';

  for (final row in _tableRows(table)) {
    final cells = _directCells(row);
    if (cells.isEmpty) continue;

    final firstText = cells.first.text.trim();
    if (firstText.contains('体测项目')) continue;
    if (firstText.contains('成绩总分')) {
      if (cells.length >= 6) {
        totalScore = cells[3].text.trim();
        grade = cells.last.text.trim();
      }
      continue;
    }
    // 项目行：图标列 + 名称 + 成绩值 + 单位（+ 得分 + 条形图 + 等级）。
    if (cells.length < 5) continue;
    final name = cells[1].text.trim();
    if (name.isEmpty) continue;

    final value = cells[2].text.trim();
    final unit = cells[3].text.trim();
    items.add(
      PhysicalTestItem(
        name: name,
        result: [value, unit].where((part) => part.isNotEmpty).join(' '),
        score: cells.length >= 7 ? cells[4].text.trim() : '',
        level: cells.length >= 7 ? cells[6].text.trim() : '',
      ),
    );
  }

  if (items.isEmpty && totalScore.isEmpty) {
    throw StateError('体测成绩页面无有效成绩结构');
  }

  return PhysicalTestRecord(
    academicYear: _extractAcademicYear(doc),
    totalScore: totalScore,
    grade: grade,
    items: items,
  );
}

/// 明确的「学校侧未开放」页面文案。
///
/// 真机抓包中 `healthscore` 在学校侧季节性关闭时返回「暂未开放查询」；只有
/// 命中这个明确文案才视为中性空态，未知 HTML 仍按结构错误处理。
const _unavailableScoreMarkers = <String>['暂未开放查询'];

/// 解析当前成绩页；仅明确的「学校侧未开放」空态返回 null。
///
/// 先按 [parsePhysicalTestScorePage] 严格解析；只有解析失败且页面命中
/// [_unavailableScoreMarkers] 时才返回 null。结构损坏 / 未知 HTML 仍然抛
/// [StateError]，绝不默认为无成绩。历年明细继续使用严格解析。
PhysicalTestRecord? tryParsePhysicalTestScorePage(String html) {
  try {
    return parsePhysicalTestScorePage(html);
  } on StateError {
    final doc = html_parser.parse(html);
    final text = doc.body?.text ?? doc.text ?? '';
    if (_unavailableScoreMarkers.any(text.contains)) return null;
    rethrow;
  }
}

/// 解析历年列表页（`scoreTotal`）。
///
/// 表格结构（表头「学年」）缺失时抛 [StateError]；表格存在但暂无记录是
/// 合法空列表。
List<PhysicalTestYearEntry> parsePhysicalTestYearList(String html) {
  final doc = html_parser.parse(html);
  final table = _findYearListTable(doc);
  if (table == null) {
    throw StateError('历年体测页面结构无法识别');
  }

  final entries = <PhysicalTestYearEntry>[];
  for (final row in _tableRows(table)) {
    final cells = _directCells(row);
    if (cells.length < 5) continue;
    final academicYear = cells[0].text.trim();
    if (!RegExp(r'\d{4}-\d{4}').hasMatch(academicYear)) continue;

    entries.add(
      PhysicalTestYearEntry(
        academicYear: academicYear,
        totalScore: cells[3].text.trim(),
        grade: cells[4].text.trim(),
        detailHref: cells.length >= 6
            ? (cells[5].querySelector('a')?.attributes['href']?.trim() ?? '')
            : '',
      ),
    );
  }
  return entries;
}

String _inputValue(Document doc, String name) {
  for (final input in doc.querySelectorAll('input')) {
    if (input.attributes['name']?.trim() == name) {
      return input.attributes['value']?.trim() ?? '';
    }
  }
  return '';
}

bool _isUsableIdentityValue(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return false;
  if (value.toLowerCase() == 'null') return false;
  final decoded = _tryDecodeBase64(value);
  return decoded == null || decoded.trim().toLowerCase() != 'null';
}

String? _tryDecodeBase64(String value) {
  try {
    return utf8.decode(base64.decode(value), allowMalformed: true);
  } on FormatException {
    return null;
  }
}

Element? _findTableContaining(Document doc, String text) {
  for (final table in doc.querySelectorAll('table')) {
    if (table.text.contains(text)) return table;
  }
  return null;
}

Element? _findYearListTable(Document doc) {
  for (final table in doc.querySelectorAll('table')) {
    if ((table.querySelector('thead')?.text ?? '').contains('学年')) {
      return table;
    }
  }
  return null;
}

List<Element> _directCells(Element row) => row.children
    .where((element) => element.localName == 'td')
    .toList(growable: false);

/// 只取表格自身的行，不下钻嵌套表格（得分条形图 / 图例的 tr 不是项目行）。
Iterable<Element> _tableRows(Element table) sync* {
  for (final child in table.children) {
    if (child.localName == 'tr') {
      yield child;
    } else if (child.localName == 'tbody' ||
        child.localName == 'thead' ||
        child.localName == 'tfoot') {
      for (final row in child.children) {
        if (row.localName == 'tr') yield row;
      }
    }
  }
}

String _extractAcademicYear(Document doc) {
  final text = doc.body?.text ?? doc.text ?? '';
  final withTerm = RegExp(r'(\d{4}-\d{4})\s*学年\s*(\d+)\s*学期').firstMatch(text);
  if (withTerm != null) {
    return '${withTerm.group(1)}-${withTerm.group(2)}';
  }
  return RegExp(r'(\d{4}-\d{4})\s*学年').firstMatch(text)?.group(1) ?? '';
}
