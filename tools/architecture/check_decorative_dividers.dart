// 装饰性分割线守卫（docs/design-guidelines.md §1.2、docs/decorative-divider-audit.md）。
//
// 与 tools/architecture/check_design_ratchet.dart 的区别：棘轮按**文件计数**
// 只许减少；本守卫按**站点**判定——默认任何命中的手工分割线都报错，只有显式
// 写进 decorativeDividerAllowlist 的已知站点（带数量上限 + 理由）才放行，且
// 每条豁免必须**当前仍命中至少 1 处**（否则视为过期豁免直接失败）。因此它不会
// 长成一张「整仓数量基线」，也不能静默放宽。
//
// 两类模式：
//   nativeDivider     —— 直接用 `Divider(` / `VerticalDivider(` 构造器。
//   handDrawnThinBox  —— 手工细线（默认拦截，覆盖**已证明的 API widget 形态**）：
//                        A) 宿主构造器 `Container(` / `AnimatedContainer(` /
//                           `ColoredBox(` / `DecoratedBox(` 的**完整平衡实参区间**里
//                           同时出现细尺寸（`width`/`height` 取 0.5|1|1.0）与可见绘制
//                           （`color:` / `decoration:`）——不区分参数顺序，典型
//                           1×32 竖线或整宽 height:1 发丝线。
//                        B) 带可见绘制的宿主，其直接 `child:` 是**细盒子**
//                           （`Container`/`AnimatedContainer`/`ColoredBox`/
//                           `DecoratedBox`/`SizedBox` 且自身细尺寸、自身无绘制）。
//
// 覆盖是**有界**的，不宣称能识别「任何一条线」：只默认拦截上面枚举的 API widget
// 形态 + `Divider` / `VerticalDivider`。语义线（焦点 / 输入 / 轮廓 / 图表 / 表格 /
// 时间轴）与下面的盲区都不在拦截范围。
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
//   - 宿主与细尺寸之间被非盒子包装层隔开（如 `child: Padding(child: SizedBox(width: 1))`）
//   - 字符串插值 `"${...}"` 内部代码被整体遮蔽（只保证字面量不误报，不做完整 Dart 解析）
//   - 同一片段里嵌套多个宿主时可能各自命中，需人工确认归属
//   - 计数上限是（文件 + 模式）级别：**同数量换站点**（删一条旧的、在同一文件新增一条）
//     无法被计数拦截；若要站点级指纹需另加，当前不做
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

/// 允许存在的已知站点。`allowed` 是该文件该类模式的**上限**：新增第 N+1 处即失败；
/// 且该站点必须**当前至少命中 1 处**，否则豁免过期失败。只覆盖这里列出的文件，
/// 其它文件一律上限 0。
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

/// 窄豁免清单：每条必须带理由 + 数量上限，且当前仍命中至少 1 处。
/// 畅行嘉大的专项线条已由 PR73 移除，此处保持为空。
const decorativeDividerAllowlist = <DecorativeDividerAllowance>[];

/// 宿主构造器：只有这些才会画出可见的 1px 线（默认拦截）。
final RegExp _hostConstructors = RegExp(
  r'(?<![A-Za-z0-9_])(AnimatedContainer|Container|ColoredBox|DecoratedBox)\s*\(',
);

/// 可能作为「细线子节点」的盒子构造器名（rule B 用；只匹配名字，
/// 括号位置另在遮蔽后的源码里定位——投影里括号已被换成空格）。
final RegExp _boxNames = RegExp(
  r'(?<![A-Za-z0-9_])(AnimatedContainer|Container|ColoredBox|DecoratedBox|SizedBox)',
);

/// 细尺寸：`width` / `height` 取 0.5 | 1 | 1.0，后跟 `,` 或 `)`（或实参区间末尾）。
final RegExp _thinDimension = RegExp(
  r'(?<![A-Za-z0-9_])(?:width|height)\s*:\s*(?:0\.5|1(?:\.0)?)\s*(?=,|\))',
);

/// 可见绘制实参：`color:` 或 `decoration:`（仅看宿主自身深度 0 的实参）。
final RegExp _paint = RegExp(r'(?<![A-Za-z0-9_])(?:color|decoration)\s*:');

/// 子节点实参名。
final RegExp _childArg = RegExp(r'(?<![A-Za-z0-9_])child\s*:');

/// `Divider(` / `VerticalDivider(` 构造器。
final RegExp _nativeDivider = RegExp(
  r'(?<![A-Za-z0-9_])(?:Vertical)?Divider\s*\(',
);

const _lparen = 0x28, _rparen = 0x29, _lbracket = 0x5B, _rbracket = 0x5D;
const _lbrace = 0x7B, _rbrace = 0x7D, _space = 0x20, _lf = 0x0A, _cr = 0x0D;

bool _isIdentChar(int c) =>
    (c >= 0x30 && c <= 0x39) ||
    (c >= 0x41 && c <= 0x5A) ||
    (c >= 0x61 && c <= 0x7A) ||
    c == 0x5F;

/// 词法遮蔽：把注释与字符串字面量换成等长空格（保留换行与全部偏移），
/// 使括号平衡扫描、行号与片段定位都基于真实位置。
///
/// 字符串覆盖 `'` / `"` / 三引号 / `r'...'` raw / 反斜杠转义 / `$` 插值；
/// 插值内部代码也会被整体遮蔽（有界覆盖，见文件头盲区）。
String maskDartSource(String source) {
  final out = StringBuffer();
  final n = source.length;
  int at(int k) => (k >= 0 && k < n) ? source.codeUnitAt(k) : -1;

  void blank(int c) => out.writeCharCode(c == _lf || c == _cr ? c : _space);

  var i = 0;
  while (i < n) {
    final c = at(i);
    final d = at(i + 1);
    if (c == 0x2F && d == 0x2F) {
      while (i < n && at(i) != _lf) {
        blank(at(i));
        i++;
      }
      continue;
    }
    if (c == 0x2F && d == 0x2A) {
      blank(c);
      blank(d);
      i += 2;
      while (i < n && !(at(i) == 0x2A && at(i + 1) == 0x2F)) {
        blank(at(i));
        i++;
      }
      if (i < n) {
        blank(0x2A);
        blank(0x2F);
        i += 2;
      }
      continue;
    }
    final rawStart =
        c == 0x72 && (d == 0x27 || d == 0x22) && !_isIdentChar(at(i - 1));
    if (c == 0x27 || c == 0x22 || rawStart) {
      i = _maskString(source, i, out, rawStart);
      continue;
    }
    out.writeCharCode(c);
    i++;
  }
  return out.toString();
}

int _maskString(String src, int start, StringBuffer out, bool isRaw) {
  final n = src.length;
  int at(int k) => (k >= 0 && k < n) ? src.codeUnitAt(k) : -1;
  void blank(int c) => out.writeCharCode(c == _lf || c == _cr ? c : _space);

  var i = start;
  if (isRaw) {
    blank(0x72);
    i++;
  }
  final quote = at(i);
  final triple = at(i + 1) == quote && at(i + 2) == quote;
  final quotes = triple ? 3 : 1;
  for (var k = 0; k < quotes; k++) {
    blank(quote);
    i++;
  }
  if (triple) {
    while (i < n) {
      if (at(i) == quote && at(i + 1) == quote && at(i + 2) == quote) {
        blank(quote);
        blank(quote);
        blank(quote);
        return i + 3;
      }
      blank(at(i));
      i++;
    }
    return i;
  }
  while (i < n) {
    final c = at(i);
    if (!isRaw && c == 0x5C) {
      blank(c);
      i++;
      if (i < n) {
        blank(at(i));
        i++;
      }
      continue;
    }
    if (!isRaw && c == 0x24) {
      blank(c);
      i++;
      if (at(i) == _lbrace) {
        blank(_lbrace);
        i++;
        i = _maskInterpolation(src, i, out);
      } else {
        while (i < n && _isIdentChar(at(i))) {
          blank(at(i));
          i++;
        }
      }
      continue;
    }
    if (c == quote) {
      blank(quote);
      return i + 1;
    }
    if (c == _lf || c == _cr) return i; // 未闭合的单行字符串，止于换行
    blank(c);
    i++;
  }
  return i;
}

int _maskInterpolation(String src, int start, StringBuffer out) {
  final n = src.length;
  int at(int k) => (k >= 0 && k < n) ? src.codeUnitAt(k) : -1;
  void blank(int c) => out.writeCharCode(c == _lf || c == _cr ? c : _space);

  var depth = 1;
  var i = start;
  while (i < n) {
    final c = at(i);
    if (c == _lbrace) {
      depth++;
      blank(c);
      i++;
      continue;
    }
    if (c == _rbrace) {
      depth--;
      blank(c);
      i++;
      if (depth == 0) return i;
      continue;
    }
    final rawStart =
        c == 0x72 &&
        (at(i + 1) == 0x27 || at(i + 1) == 0x22) &&
        !_isIdentChar(at(i - 1));
    if (c == 0x27 || c == 0x22 || rawStart) {
      i = _maskString(src, i, out, rawStart);
      continue;
    }
    blank(c);
    i++;
  }
  return i;
}

int _lineOf(String source, int offset) {
  var line = 1;
  final limit = offset < source.length ? offset : source.length;
  for (var i = 0; i < limit; i++) {
    if (source.codeUnitAt(i) == _lf) line++;
  }
  return line;
}

/// 从 [openIdx]（指向 `(`）找到配对的 `)`，超出 [maxScan] 视为不完整。
int _balancedEnd(String masked, int openIdx, {int maxScan = 8000}) {
  var depth = 0;
  final limit = openIdx + maxScan < masked.length
      ? openIdx + maxScan
      : masked.length;
  for (var k = openIdx; k < limit; k++) {
    final c = masked.codeUnitAt(k);
    if (c == _lparen || c == _lbracket || c == _lbrace) {
      depth++;
    } else if (c == _rparen || c == _rbracket || c == _rbrace) {
      depth--;
      if (depth == 0) return k;
    }
  }
  return -1;
}

/// 把实参区间里**非深度 0** 的字符换成空格（保留长度），得到只含宿主自身实参的投影。
String _depth0Projection(String span) {
  final out = StringBuffer();
  var depth = 0;
  for (var k = 0; k < span.length; k++) {
    final c = span.codeUnitAt(k);
    if (c == _lparen || c == _lbracket || c == _lbrace) {
      depth++;
      out.writeCharCode(_space);
    } else if (c == _rparen || c == _rbracket || c == _rbrace) {
      depth--;
      out.writeCharCode(_space);
    } else if (depth != 0) {
      out.writeCharCode(_space);
    } else {
      out.writeCharCode(c);
    }
  }
  return out.toString();
}

/// 收集所有手工细线的命中偏移（在 [masked] 上）。
List<int> _handDrawnOffsets(String masked) {
  final offsets = <int>[];
  for (final host in _hostConstructors.allMatches(masked)) {
    _analyzeHost(masked, host, offsets);
  }
  offsets.sort();
  final unique = <int>[];
  for (final offset in offsets) {
    if (unique.isEmpty || unique.last != offset) unique.add(offset);
  }
  return unique;
}

void _analyzeHost(String masked, RegExpMatch host, List<int> out) {
  final openIdx = host.end - 1;
  if (openIdx < 0 || masked.codeUnitAt(openIdx) != _lparen) return;
  final closeIdx = _balancedEnd(masked, openIdx);
  if (closeIdx < 0) return;
  final span = masked.substring(openIdx + 1, closeIdx);
  // 末尾补 `)` 哨兵，让「最后一个实参无尾逗号」也能被 _thinDimension 识别。
  final projection = '${_depth0Projection(span)})';
  final thin = _thinDimension.firstMatch(projection);
  final hasPaint = _paint.hasMatch(projection);

  if (thin != null && hasPaint) {
    out.add(openIdx + 1 + thin.start);
    return;
  }
  if (hasPaint) {
    _analyzeThinChild(masked, openIdx, closeIdx, projection, out);
  }
}

void _analyzeThinChild(
  String masked,
  int openIdx,
  int closeIdx,
  String projection,
  List<int> out,
) {
  final child = _childArg.firstMatch(projection);
  if (child == null) return;
  final after = projection.substring(child.end);
  final name = _boxNames.firstMatch(after);
  if (name == null) return;
  final nameEnd = openIdx + 1 + child.end + name.start + name.group(0)!.length;

  // 名字后紧跟（允许空白）的必须是 `(`，否则不是直接子盒子（如 `SizedBox.expand(`）。
  var childOpen = -1;
  for (var k = nameEnd; k < closeIdx; k++) {
    final c = masked.codeUnitAt(k);
    if (c == _space || c == _lf || c == _cr || c == 0x09) continue;
    if (c == _lparen) childOpen = k;
    break;
  }
  if (childOpen < 0) return;
  final childClose = _balancedEnd(masked, childOpen);
  if (childClose < 0 || childClose > closeIdx) return;
  final childProjection =
      '${_depth0Projection(masked.substring(childOpen + 1, childClose))})';
  final childThin = _thinDimension.firstMatch(childProjection);
  if (childThin == null) return;
  if (_paint.hasMatch(childProjection)) return; // 子节点自带绘制 → 由其自身规则处理
  out.add(childOpen + 1 + childThin.start);
}

/// 扫描单份源码（纯函数，便于单测），返回命中的装饰性分割线站点。
List<DecorativeDividerHit> scanDividersInSource(
  String source, {
  String file = '<memory>',
}) {
  final masked = maskDartSource(source);
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
  for (final offset in _handDrawnOffsets(masked)) {
    add('handDrawnThinBox', offset);
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

int? _allowedCount(String key) {
  for (final a in decorativeDividerAllowlist) {
    if ('${a.file}|${a.pattern}' == key) return a.allowed;
  }
  return null;
}

/// 比对豁免清单，返回违规描述列表（空列表即通过）。
///
/// [checkStaleExemptions] 默认 true：豁免条目当前命中 0 处即失败（强制随专项 PR
/// 删除过期豁免，避免用剩余上限静默放行未来新增）。单测做纯检测时可显式关闭。
List<String> decorativeDividerViolations({
  List<DecorativeDividerHit>? hits,
  String root = 'lib',
  bool checkStaleExemptions = true,
}) {
  final all = hits ?? scanDecorativeDividers(root: root);
  final counts = <String, int>{};
  for (final hit in all) {
    final key = '${hit.file}|${hit.pattern}';
    counts[key] = (counts[key] ?? 0) + 1;
  }

  final violations = <String>[];
  for (final entry in counts.entries) {
    final parts = entry.key.split('|');
    final limit = _allowedCount(entry.key);
    if (limit == null) {
      violations.add(
        '${parts[0]} [${parts[1]}] 出现 ${entry.value} 处，不在豁免清单（上限 0）',
      );
    } else if (entry.value > limit) {
      final sites = all
          .where((h) => h.file == parts[0] && h.pattern == parts[1])
          .map((h) => '${h.line}')
          .join(', ');
      violations.add(
        '${parts[0]} [${parts[1]}] 出现 ${entry.value} 处（上限 $limit），行号 $sites',
      );
    }
  }

  if (checkStaleExemptions) {
    for (final a in decorativeDividerAllowlist) {
      final key = '${a.file}|${a.pattern}';
      if ((counts[key] ?? 0) == 0) {
        violations.add(
          '${a.file} [${a.pattern}] 豁免已过期：当前 0 处（站点已不存在），'
          '必须删除该豁免条目，否则会用剩余上限静默放行未来新增',
        );
      }
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
    stdout.writeln('装饰性分割线守卫通过：共 ${hits.length} 处，全部在豁免清单内且非过期。');
    return;
  }
  stderr.writeln('发现未豁免 / 过期的装饰性分割线：');
  for (final v in violations) {
    stderr.writeln('  - $v');
  }
  exitCode = 1;
}
