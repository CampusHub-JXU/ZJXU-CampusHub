/// 与浏览器 JavaScript 字符串 / 数字语义对齐的小工具。
///
/// PWA 的去重 hash、答案规范化都依赖 JS 的 `trim()` / `\s` / `localeCompare`
/// / 数字转字符串；为让「同一道题在 PWA 与原生算出相同 hash」，这里把差异
/// 收口到一处，domain 其余代码只调用这些函数。
library;

/// ECMAScript `WhiteSpace` + `LineTerminator`（即 `String.prototype.trim` 去除的
/// 字符集，也是正则 `\s` 的字符集）。
///
/// Dart 的 `String.trim()` 额外会去掉 U+0085（NEL），JS 不会，所以不能直接用。
bool isJsWhitespace(int c) {
  if (c >= 0x09 && c <= 0x0D) return true; // TAB LF VT FF CR
  switch (c) {
    case 0x20:
    case 0xA0:
    case 0x1680:
    case 0x2028:
    case 0x2029:
    case 0x202F:
    case 0x205F:
    case 0x3000:
    case 0xFEFF:
      return true;
  }
  return c >= 0x2000 && c <= 0x200A;
}

/// JS `String.prototype.trim`。
String jsTrim(String s) {
  var start = 0;
  var end = s.length;
  while (start < end && isJsWhitespace(s.codeUnitAt(start))) {
    start++;
  }
  while (end > start && isJsWhitespace(s.codeUnitAt(end - 1))) {
    end--;
  }
  return start == 0 && end == s.length ? s : s.substring(start, end);
}

/// JS `Number → String`（只覆盖导入会遇到的取值：整数、普通小数）。
///
/// 整数值的 double（如 xlsx 单元格里的 `3.0`）输出 `3` 而不是 Dart 的 `3.0`。
String jsNumberToString(num n) {
  if (n is int) return n.toString();
  final d = n.toDouble();
  if (d.isNaN) return 'NaN';
  if (d.isInfinite) return d.isNegative ? '-Infinity' : 'Infinity';
  if (d == d.truncateToDouble() && d.abs() < 1e21) {
    return d.toInt().toString();
  }
  return d.toString();
}

/// 对 JS `a.localeCompare(b)`（浏览器 ICU 根排序）的近似。
///
/// 仅用于选项 key 排序（`A`..`Z` / `true` / `false` 等 ASCII）：先按「忽略大小写
/// 的主权重」比较（标点 < 数字 < 拉丁字母 < 其它），主权重相同时小写排在大写之前。
/// 对 ASCII 字母 / 数字 key 与 ICU 一致；含罕见标点的 key 顺序可能与浏览器不同
/// （见 docs/shuati-native-parity.md「未能 1:1 复刻」）。
int jsLocaleCompare(String a, String b) {
  final ar = a.runes.toList(growable: false);
  final br = b.runes.toList(growable: false);
  final n = ar.length < br.length ? ar.length : br.length;
  for (var i = 0; i < n; i++) {
    final pa = _primary(ar[i]);
    final pb = _primary(br[i]);
    if (pa != pb) return pa < pb ? -1 : 1;
  }
  if (ar.length != br.length) return ar.length < br.length ? -1 : 1;
  for (var i = 0; i < n; i++) {
    if (ar[i] == br[i]) continue;
    final aLower = _isLowerLatin(ar[i]);
    final bLower = _isLowerLatin(br[i]);
    if (aLower != bLower) return aLower ? -1 : 1;
    return ar[i] < br[i] ? -1 : 1;
  }
  return 0;
}

bool _isLowerLatin(int c) => c >= 0x61 && c <= 0x7A;

int _primary(int c) {
  var code = c;
  if (code >= 0x41 && code <= 0x5A) code += 0x20; // 折叠大写
  if (code >= 0x61 && code <= 0x7A) return 0x20000 + code; // 拉丁字母
  if (code >= 0x30 && code <= 0x39) return 0x10000 + code; // 数字
  if (code < 0x80) return code; // ASCII 标点 / 空白
  return 0x30000 + code; // 其它按码点
}

/// 稳定排序（JS `Array.prototype.sort` 自 ES2019 起保证稳定；Dart `List.sort` 不保证）。
List<T> stableSorted<T>(Iterable<T> items, int Function(T a, T b) compare) {
  final indexed = <(int, T)>[for (final (i, item) in items.indexed) (i, item)];
  indexed.sort((a, b) {
    final c = compare(a.$2, b.$2);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  return [for (final entry in indexed) entry.$2];
}
