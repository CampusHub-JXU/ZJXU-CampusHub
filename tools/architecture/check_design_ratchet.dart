// 设计棘轮守卫（docs/ui-unification-plan.md §6）。
//
// 统计 lib/features/** 与 lib/shared/widgets/** 里绕开设计系统的写法，
// 每个文件每类写法的数量只许减少、不许增加：
//   fontSize             写死字号（改用 context.appText / 主题 textTheme）
//   hexColor             写死颜色值（状态色只取 ColorScheme，design-guidelines §4.6）
//   showSnackBar         直接弹 SnackBar（改用 AppFeedback.toast）
//   showDialog           直接弹对话框（改用 AppFeedback.confirm / showGlassDialog）
//   showModalBottomSheet 直接弹底部弹层（改用 AppFeedback.sheet）
//   rawCard              裸 Material Card（改用 AppCard / AppTileSurface / PlainListGroup）
//
// 基线在 test/helpers/design_ratchet_baseline.dart，由
// test/structure/design_ratchet_test.dart 比对。迁移页面把数量降下来之后，
// 用下面的命令重新生成基线（diff 里只应出现数字变小或条目消失）：
//   dart run tools/architecture/check_design_ratchet.dart --write
// 不带参数运行只打印当前统计。
import 'dart:io';

/// 写法 → 匹配规则。
final Map<String, RegExp> designPatterns = {
  'fontSize': RegExp(r'fontSize:\s*[\d.]'),
  'hexColor': RegExp(r'Color\(0x'),
  'showSnackBar': RegExp(r'\.showSnackBar\('),
  'showDialog': RegExp(r'\bshowDialog\s*[<(]'),
  'showModalBottomSheet': RegExp(r'\bshowModalBottomSheet\s*[<(]'),
  'rawCard': RegExp(r'(?<![A-Za-z0-9_])Card\('),
};

/// 合法实现处，永久豁免（统一入口本身必然包含被禁止的底层调用）。
const designRatchetExempt = <String>{
  'shared/widgets/app_feedback.dart',
  'shared/widgets/glass_dialog_route.dart',
};

const _scanRoots = ['features', 'shared/widgets'];

const baselinePath = 'test/helpers/design_ratchet_baseline.dart';

final _lineComment = RegExp(r'//.*$', multiLine: true);

/// 扫描 [root]（默认 `lib`）返回 `{lib 相对路径: {写法: 次数}}`，只含次数 > 0 的项。
Map<String, Map<String, int>> collectDesignCounts({String root = 'lib'}) {
  final result = <String, Map<String, int>>{};
  for (final sub in _scanRoots) {
    final dir = Directory('$root/$sub');
    if (!dir.existsSync()) continue;
    for (final entity in dir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final posix = entity.path.replaceAll('\\', '/');
      final posixRoot = root.replaceAll('\\', '/');
      final rel = posix.substring(
        posix.indexOf('$posixRoot/') + posixRoot.length + 1,
      );
      if (designRatchetExempt.contains(rel)) continue;
      // 去掉行注释，文档注释里提到的 API 名不计数。
      final text = entity.readAsStringSync().replaceAll(_lineComment, '');
      final counts = <String, int>{};
      designPatterns.forEach((name, pattern) {
        final n = pattern.allMatches(text).length;
        if (n > 0) counts[name] = n;
      });
      if (counts.isNotEmpty) result[rel] = counts;
    }
  }
  return result;
}

/// 生成基线文件内容（按路径排序，便于评审 diff）。
String renderBaseline(Map<String, Map<String, int>> counts) {
  final buffer = StringBuffer()
    ..writeln('// 由 tools/architecture/check_design_ratchet.dart --write 生成，')
    ..writeln('// 不要手写。数量只许减少：迁移页面后重新生成，diff 里只应出现')
    ..writeln('// 数字变小或条目消失。')
    ..writeln()
    ..writeln('const designRatchetBaseline = <String, Map<String, int>>{');
  final paths = counts.keys.toList()..sort();
  for (final path in paths) {
    final entries = counts[path]!.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final body = entries.map((e) => "'${e.key}': ${e.value}").join(', ');
    buffer.writeln("  '$path': {$body},");
  }
  buffer.writeln('};');
  return buffer.toString();
}

void main(List<String> args) {
  final counts = collectDesignCounts();
  if (args.contains('--write')) {
    File(baselinePath).writeAsStringSync(renderBaseline(counts));
    // CI 跑 `dart format --set-exit-if-changed`，生成后顺手格式化。
    final format = Process.runSync(Platform.resolvedExecutable, [
      'format',
      baselinePath,
    ]);
    if (format.exitCode != 0) {
      stderr.writeln('dart format 失败：${format.stderr}');
      exitCode = 1;
      return;
    }
    stdout.writeln('已写入 $baselinePath（${counts.length} 个文件）。');
    return;
  }
  final totals = <String, int>{};
  for (final fileCounts in counts.values) {
    fileCounts.forEach((k, v) => totals[k] = (totals[k] ?? 0) + v);
  }
  stdout.writeln('设计棘轮统计（${counts.length} 个文件）：');
  for (final name in designPatterns.keys) {
    stdout.writeln('  $name: ${totals[name] ?? 0}');
  }
}
