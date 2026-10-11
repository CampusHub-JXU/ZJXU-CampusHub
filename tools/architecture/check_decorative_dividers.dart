// 装饰性分割线守卫（docs/design-guidelines.md §1.2、docs/decorative-divider-audit.md）。
//
// 与 tools/architecture/check_design_ratchet.dart 的区别：棘轮按**文件计数**
// 只许减少；本守卫按**站点**判定——默认任何新出现的手工分割线都报错，只有
// 显式写进 decorativeDividerAllowlist 的已知站点（带数量上限 + 理由）才放行。
// 因此它不会长成一张「整仓数量基线」，也不能静默放宽。
//
// 两类模式：
//   nativeDivider     —— 直接用 `Divider(` / `VerticalDivider(` 构造器
//   handDrawnThinBox  —— 手工细线：`Container(` / `DecoratedBox(` / `ColoredBox(`
//                        里出现细尺寸（width 或 height 取 0.5|1|1.0）且带可见
//                        绘制（`color:` 或 `decoration:`），典型形式 1×32 竖线
//                        或整宽 height:1 发丝线。
//
// 明确**不在**本守卫范围（各有独立语义，见 docs/decorative-divider-audit.md）：
//   - `DividerThemeData` / `dividerTheme`：主题配置，不是画面上的线
//   - `TextStyle(height: 1)` 等文本行高（`copyWith(height: 1)`）
//   - `BorderSide` / `Border(...)` / `Border.all` / `shape: Border(...)`：
//     容器轮廓、输入框 / 焦点描边、表格网格、课程时间轴
//   - `CustomPainter.drawLine`：图表坐标 / 节点连线（学业进度 Graph 等）
//   - HTML 原文 `<hr>`（公告网页自身渲染，非原生 Flutter 绘制）
//
// 已知盲区（静态检查理解不了全部语义，如实记录，靠人工审查兜底）：
//   - 用 `BoxDecoration(border: Border(left: BorderSide(width: 1)))` 冒充的细线
//   - 用 `SizedBox(width: 1)` 做的**不可见**间隔（不画线，不算违规）
//   - 细分隔线的尺寸不是字面量（如 `width: kHairline`）时无法识别
//   - 字符串字面量里出现 `Divider(` 的极少数误报
//   - 同一片段里嵌套多个容器时可能误判归属，需人工确认
import 'dart:io';

/// 一条命中的装饰性分割线站点。
class DecorativeDividerHit {
  const DecorativeDividerHit({
    required this.file,
    required this.pattern,
    required this.line,
    required this.snippet,
  });

  /// lib 相对路径（使用 `/` 分隔）。
  final String file;

  /// `nativeDivider` 或 `handDrawnThinBox`。
  final String pattern;

  /// 1 基行号。
  final int line;

  /// 命中行的裁剪文本，便于人工定位。
  final String snippet;

  @override
  String toString() => '$file:$line [$pattern] $snippet';
}

/// 允许存在的已知站点。`allowed` 是该文件该类模式的**上限**：新增第 N+1 处即失败，
/// 且只覆盖这里列出的文件，其它文件一律上限 0。
class DecorativeDividerAllowance {
  const DecorativeDividerAllowance({
    required this.file,
    required this.pattern,
    required this.allowed,
    required this.reason,
  });

  final String file;
  final String pattern;
  final int allowed;
  final String reason;
}

/// 窄豁免清单：每条都必须带理由，且随对应专项 PR 合并而删除。
/// 目前只有畅行嘉大（#57/#58 → PR73）在 master 上仍带装饰线。
const decorativeDividerAllowlist = <DecorativeDividerAllowance>[
  DecorativeDividerAllowance(
    file: 'features/changxing_jiada/changxing_jiada_page.dart',
    pattern: 'nativeDivider',
    allowed: 3,
    reason:
        '畅行嘉大仪表盘横向 Divider（#57/#58，PR73 专项移除，未合并）。'
        'PR73 落地后必须删除本条，不得顺延。',
  ),
  DecorativeDividerAllowance(
    file: 'features/changxing_jiada/changxing_jiada_page.dart',
    pattern: 'handDrawnThinBox',
    allowed: 1,
    reason:
        '_MetricDivider 手工 1×32 竖线（#57/#58，PR73 专项移除，未合并）。'
        'PR73 落地后必须删除本条，不得顺延。',
  ),
];

final RegExp _nativeDivider = RegExp(
  r'(?<![A-Za-z0-9_])(?:Vertical)?Divider\s*\(',
);
final RegExp _thinDimension = RegExp(
  r'(?:width|height)\s*:\s*(?:0\.5|1(?:\.0)?)\s*,',
);
final RegExp _paint = RegExp(r'(?:color|decoration)\s*:');

/// 视作「细线宿主」的构造器：只有这些才会画出可见的 1px 线。
const _containerTokens = ['Container(', 'DecoratedBox(', 'ColoredBox('];

/// 解构为「不是分割线」的构造器：最近的宿主是它们时一律不报。
const _suppressorTokens = [
  'Divider(',
  'VerticalDivider(',
  'DividerThemeData(',
  'BorderSide(',
  'Border(',
  'Border.all(',
  'TableBorder(',
  'TextStyle(',
  'copyWith(',
  'SizedBox(',
];

/// 用等长空格遮蔽 `//` 与 `/* */` 注释（保留换行），使偏移与行号不变。
String maskDartComments(String source) {
  final out = StringBuffer();
  var i = 0;
  while (i < source.length) {
    final c = source[i];
    final next = i + 1 < source.length ? source[i + 1] : '';
    if (c == '/' && next == '/') {
      while (i < source.length && source[i] != '\n') {
        out.write(' ');
        i++;
      }
    } else if (c == '/' && next == '*') {
      out.write('  ');
      i += 2;
      while (i < source.length &&
          !(source[i] == '*' &&
              i + 1 < source.length &&
              source[i + 1] == '/')) {
        out.write(source[i] == '\n' ? '\n' : ' ');
        i++;
      }
      if (i < source.length) {
        out.write('  ');
        i += 2;
      }
    } else {
      out.write(c);
      i++;
    }
  }
  return out.toString();
}

int _lineOf(String source, int offset) {
  var line = 1;
  for (var i = 0; i < offset && i < source.length; i++) {
    if (source[i] == '\n') line++;
  }
  return line;
}

int _nearestTokenIndex(String s, List<String> tokens) {
  var best = -1;
  for (final token in tokens) {
    final idx = s.lastIndexOf(token);
    if (idx > best) best = idx;
  }
  return best;
}

int _lastContainerIndex(String s) => _nearestTokenIndex(s, _containerTokens);

/// 判断 [match] 处的细尺寸是否属于一条手工绘制的可见细线。
///
/// 规则：往前 240 字符内最近的构造器必须是容器（`Container` / `DecoratedBox` /
/// `ColoredBox`），且到细尺寸之间没有语句结束符；`TextStyle` / `copyWith` /
/// `BorderSide` / `Border` / `SizedBox` / `Divider` 等作为最近宿主时一律排除；
/// 往后的同一实参列表内要有 `color:` 或 `decoration:`（否则是透明间距，不画线）。
bool _looksLikeHandDrawnLine(String masked, Match match) {
  final backStart = match.start - 240 < 0 ? 0 : match.start - 240;
  final back = masked.substring(backStart, match.start);

  final owner = _lastContainerIndex(back);
  if (owner < 0) return false;
  if (_nearestTokenIndex(back, _suppressorTokens) > owner) return false;
  if (back.substring(owner).contains(';')) return false;

  var end = match.end + 260;
  if (end > masked.length) end = masked.length;
  var forward = masked.substring(match.end, end);
  final semicolon = forward.indexOf(';');
  if (semicolon >= 0) forward = forward.substring(0, semicolon);

  return _paint.hasMatch(forward);
}

/// 扫描单份源码（纯函数，便于单测），返回命中的装饰性分割线站点。
List<DecorativeDividerHit> scanDividersInSource(
  String source, {
  String file = '<memory>',
}) {
  final masked = maskDartComments(source);
  final hits = <DecorativeDividerHit>[];

  void add(String pattern, int start) {
    final lineEnd = masked.indexOf('\n', start);
    final rawEnd = lineEnd < 0 ? source.length : lineEnd;
    final rawStart = masked.lastIndexOf('\n', start) + 1;
    hits.add(
      DecorativeDividerHit(
        file: file,
        pattern: pattern,
        line: _lineOf(masked, start),
        snippet: source.substring(rawStart, rawEnd).trim(),
      ),
    );
  }

  for (final m in _nativeDivider.allMatches(masked)) {
    add('nativeDivider', m.start);
  }
  for (final m in _thinDimension.allMatches(masked)) {
    if (_looksLikeHandDrawnLine(masked, m)) add('handDrawnThinBox', m.start);
  }

  hits.sort((a, b) => a.line.compareTo(b.line));
  return hits;
}

Iterable<File> _dartFiles(String root) {
  final dir = Directory(root);
  if (!dir.existsSync()) return const [];
  return dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'));
}

String _relativeLibPath(String root, String path) {
  final normalizedRoot = root.replaceAll('\\', '/');
  final normalized = path.replaceAll('\\', '/');
  final prefix = normalizedRoot.endsWith('/')
      ? normalizedRoot
      : '$normalizedRoot/';
  return normalized.startsWith(prefix)
      ? normalized.substring(prefix.length)
      : normalized;
}

/// 扫描 [root]（默认 `lib`）下所有 Dart 文件。
List<DecorativeDividerHit> scanDecorativeDividers({String root = 'lib'}) {
  final hits = <DecorativeDividerHit>[];
  for (final file in _dartFiles(root)) {
    final rel = _relativeLibPath(root, file.path);
    hits.addAll(scanDividersInSource(file.readAsStringSync(), file: rel));
  }
  hits.sort((a, b) {
    final byFile = a.file.compareTo(b.file);
    return byFile != 0 ? byFile : a.line.compareTo(b.line);
  });
  return hits;
}

/// 比对豁免清单，返回违规描述列表（空列表即通过）。
List<String> decorativeDividerViolations({
  List<DecorativeDividerHit>? hits,
  String root = 'lib',
}) {
  final all = hits ?? scanDecorativeDividers(root: root);
  final allowed = <String, int>{
    for (final a in decorativeDividerAllowlist)
      '${a.file}|${a.pattern}': a.allowed,
  };
  final counts = <String, int>{};
  for (final hit in all) {
    final key = '${hit.file}|${hit.pattern}';
    counts[key] = (counts[key] ?? 0) + 1;
  }

  final violations = <String>[];
  for (final entry in counts.entries) {
    final limit = allowed[entry.key] ?? 0;
    if (entry.value > limit) {
      final parts = entry.key.split('|');
      final sites = all
          .where((h) => h.file == parts[0] && h.pattern == parts[1])
          .map((h) => '${h.line}')
          .join(', ');
      violations.add(
        '${parts[0]} [${parts[1]}] 出现 ${entry.value} 处（上限 $limit），行号 $sites',
      );
    }
  }
  violations.sort();
  return violations;
}

void main(List<String> args) {
  final root = args.isNotEmpty ? args.first : 'lib';
  final hits = scanDecorativeDividers(root: root);
  for (final hit in hits) {
    stdout.writeln(hit);
  }
  final violations = decorativeDividerViolations(hits: hits, root: root);
  if (violations.isEmpty) {
    stdout.writeln('装饰性分割线守卫通过：共 ${hits.length} 处，全部在豁免清单内。');
    return;
  }
  stderr.writeln('发现未豁免的装饰性分割线：');
  for (final v in violations) {
    stderr.writeln('  - $v');
  }
  exitCode = 1;
}
