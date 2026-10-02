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
///
/// 页面按节点依次生成一段固定结构的 jQuery 代码，每段以
/// `if($("#ul{父ID}").size()==0&&'{父ID}'!='')` 开头；同一段里各分支模板的
/// 属性串（`xfyqjd_id` / `jdkcsx` / `sfmjd` / `yxxf` / `xfyqzjdgx`）相同，
/// 取第一次出现即可。节点名取根节点分支里的 `data-content='{名}'`，要求学分 /
/// 门次取首个 `if('{学分}' != '' && '{门次}' == '')` 的字面量。结构对不上的段
/// 直接跳过，不猜。
List<RequirementNode> parseRequirementTree(String html) {
  final starts = _blockStart.allMatches(html).toList();
  if (starts.isEmpty) return const [];

  final flat = <RequirementNode>[];
  for (var i = 0; i < starts.length; i++) {
    final end = i + 1 < starts.length ? starts[i + 1].start : html.length;
    final node = _parseBlock(
      starts[i].group(1)!,
      html.substring(starts[i].start, end),
    );
    if (node != null) flat.add(node);
  }

  // 按父 ID 组装；父节点缺失的节点当作顶层，避免静默丢数据。
  final ids = {for (final n in flat) n.id};
  final childrenOf = <String, List<RequirementNode>>{};
  for (final n in flat) {
    final key = n.parentId.isNotEmpty && ids.contains(n.parentId)
        ? n.parentId
        : '';
    childrenOf.putIfAbsent(key, () => []).add(n);
  }
  final seen = <String>{};
  RequirementNode build(RequirementNode n) {
    if (!seen.add(n.id)) return n;
    final kids = childrenOf[n.id] ?? const <RequirementNode>[];
    return n.copyWith(children: [for (final k in kids) build(k)]);
  }

  return [
    for (final n in childrenOf[''] ?? const <RequirementNode>[]) build(n),
  ];
}

final _blockStart = RegExp(
  r"""if\(\$\("#ul([^"]*)"\)\.size\(\)==0&&'[^']*'!=''\)""",
);
final _idAttr = RegExp(r"\bxfyqjd_id='([^']+)'");
final _nameAttr = RegExp(r"data-content='([^']+)'");
final _requirementLiterals = RegExp(
  r"if\('([^']*)' != '' && '([^']*)' == ''\)",
);
final _metCount = RegExp(r'达到要求:(\d+)');
final _passedCount = RegExp(r"name='yxmc'>(\d+)<");

RequirementNode? _parseBlock(String parentId, String block) {
  final id = _idAttr.firstMatch(block)?.group(1);
  final name = _nameAttr.firstMatch(block)?.group(1);
  if (id == null || name == null) return null;

  String attr(String key) =>
      RegExp("\\b$key='([^']*)'").firstMatch(block)?.group(1)?.trim() ?? '';

  final literals = _requirementLiterals.firstMatch(block);
  // 「主修」这类容器节点的要求学分字面量是 0.0：视为无学分要求。
  final rawCredits = double.tryParse(literals?.group(1) ?? '');
  final requiredCredits = rawCredits != null && rawCredits > 0
      ? rawCredits
      : null;
  final requiredCount = double.tryParse(literals?.group(2) ?? '')?.round();
  final metCount = requiredCount == null
      ? null
      : int.tryParse(_metCount.firstMatch(block)?.group(1) ?? '');
  final passed = _passedCount.firstMatch(block)?.group(1);

  return RequirementNode(
    id: id,
    name: _decodeEntities(name),
    parentId: parentId,
    requiredCredits: requiredCredits,
    earnedCredits: requiredCredits == null
        ? null
        : double.tryParse(attr('yxxf')) ?? 0,
    requiredCount: requiredCount,
    metCount: metCount,
    relation: RequirementRelation.fromCode(attr('xfyqzjdgx')),
    courseAttribute: attr('jdkcsx'),
    isLeaf: attr('sfmjd') == '1',
    serverPassedCount: passed == null ? null : int.tryParse(passed),
  );
}

String _decodeEntities(String raw) => raw
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&amp;', '&')
    .trim();
