import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

import 'academic_progress_model.dart';

/// 首页隐藏 input 中需要回传给课程明细接口的参数（随学期变化，不能写死）。
const academicProgressQueryKeys = <String>[
  'cjlrxn',
  'cjlrxq',
  'bkcjlrxn',
  'bkcjlrxq',
  'xscjcxkz',
  'cjcxkzzt',
  'cjztkz',
  'cjzt',
];

/// 首页解析结果。
class AcademicProgressIndexPage {
  const AcademicProgressIndexPage({
    required this.summary,
    required this.roots,
    required this.queryParams,
  });

  final AcademicProgressSummary summary;
  final List<RequirementNode> roots;
  final Map<String, String> queryParams;
}

/// 解析 `xsxyqk_cxXsxyqkIndex.html`。结构无法识别（没有任何学分要求节点）时
/// 返回 `null`，由调用方 fail closed，不展示猜测的数据。
///
/// 只抽取数字与节点名；`#alertBox` 里的姓名、根容器 id 里的学号不进入结果。
AcademicProgressIndexPage? parseAcademicProgressIndex(String html) {
  final document = html_parser.parse(html);
  final roots = parseRequirementTree(html);
  if (roots.isEmpty) return null;
  return AcademicProgressIndexPage(
    summary: parseAcademicProgressSummary(document),
    roots: roots,
    queryParams: {
      for (final key in academicProgressQueryKeys)
        key: _inputValue(document, key),
    },
  );
}

String _inputValue(Document document, String key) {
  final input =
      document.querySelector('input#$key') ??
      document.querySelector('input[name="$key"]');
  return input?.attributes['value']?.trim() ?? '';
}

/// 解析 `#alertBox` 统计区。
AcademicProgressSummary parseAcademicProgressSummary(Document document) {
  final box = document.querySelector('#alertBox');
  if (box == null) return const AcademicProgressSummary();
  final text = box.text.replaceAll(' ', ' ').replaceAll(RegExp(r'\s+'), ' ');

  // GPA：与页面 JS 一致，取 a[name=showGpa] 的下一个元素文本；
  // 兜底从文本里找「（GPA）：x.xxx」。
  String? gpa;
  final gpaLink = box.querySelector('a[name="showGpa"]');
  final next = gpaLink?.nextElementSibling;
  final gpaText = next?.text.trim() ?? '';
  if (RegExp(r'^\d+(\.\d+)?$').hasMatch(gpaText)) {
    gpa = gpaText;
  } else {
    gpa = RegExp(r'GPA）：\s*(\d+(?:\.\d+)?)').firstMatch(text)?.group(1);
  }

  // 「计划外：」之后是第二组「通过 / 未通过」。
  final outsideIndex = text.indexOf('计划外');
  final planText = outsideIndex < 0 ? text : text.substring(0, outsideIndex);
  final outsideText = outsideIndex < 0 ? '' : text.substring(outsideIndex);

  int? count(String source, String pattern) {
    final m = RegExp(pattern).firstMatch(source);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  return AcademicProgressSummary(
    statTime: RegExp(r'统计时间\s*(.+?)\s*之前有效').firstMatch(text)?.group(1) ?? '',
    gpa: gpa,
    planTotal: count(planText, r'计划总课程\s*(\d+)\s*门'),
    // 「未通过」也含「通过」二字，需用负向后顾排除。
    planPassed: count(planText, r'(?<!未)通过\s*(\d+)\s*门'),
    planFailed: count(planText, r'未通过\s*(\d+)\s*门'),
    planNotTaken: count(planText, r'未修\s*(\d+)\s*门'),
    studying: count(planText, r'在读\s*(\d+)\s*门'),
    outsidePassed: count(outsideText, r'(?<!未)通过\s*(\d+)\s*门'),
    outsideFailed: count(outsideText, r'未通过\s*(\d+)\s*门'),
  );
}

/// 从首页 inline script 抽取学分要求树。
List<RequirementNode> parseRequirementTree(String html) {
  // TODO: 待脚本原文样本确认后实现。
  return const [];
}
