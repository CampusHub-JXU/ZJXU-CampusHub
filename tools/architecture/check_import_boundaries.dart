// 架构边界守卫（PRD 0.7.0 §4）。
//
// 分层方向（core/shared 不得依赖 app/features、feature 之间不得横向依赖）
// 由 test/structure/import_layering_test.dart 覆盖；本守卫只补充 feature 侧
// 平台启动禁令，避免两套 allowlist 变成两个真相：
//   1. feature 不得直接创建 MethodChannel
//   2. feature 不得直接 launchUrl
//   3. feature 不得直接调用 WechatLauncher（系统入口必须经 CampusAction）
//
// 用法：
//   dart run tools/architecture/check_import_boundaries.dart
// 退出码 0 = 通过，1 = 存在违例。
import 'dart:io';

/// 历史直连 allowlist（棘轮只减不增）。Phase A5 已全部迁移，保持为空。
const allowedWechatLauncherFeatureFiles = <String>{};

class BoundaryViolation {
  const BoundaryViolation(this.file, this.rule);

  final String file;
  final String rule;

  @override
  String toString() => '$file: $rule';
}

final _methodChannelPattern = RegExp(r'\bMethodChannel\s*\(');
final _launchUrlPattern = RegExp(r'(?<![A-Za-z0-9_])launchUrl\s*\(');
final _wechatLauncherPattern = RegExp(r'\bWechatLauncher\b');

/// 扫描 [root] 下的 feature 源码，返回平台启动边界违例。
List<BoundaryViolation> collectBoundaryViolations({String root = 'lib'}) {
  final violations = <BoundaryViolation>[];
  final dir = Directory(root);
  if (!dir.existsSync()) return violations;

  for (final entity in dir.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final posix = entity.path.replaceAll('\\', '/');
    if (!posix.split('/').contains('features')) continue;

    final text = entity.readAsStringSync();
    if (_methodChannelPattern.hasMatch(text)) {
      violations.add(BoundaryViolation(posix, 'feature 不得直接创建 MethodChannel'));
    }
    if (_launchUrlPattern.hasMatch(text)) {
      violations.add(BoundaryViolation(posix, 'feature 不得直接 launchUrl'));
    }
    if (_wechatLauncherPattern.hasMatch(text) &&
        !allowedWechatLauncherFeatureFiles.contains(posix)) {
      violations.add(
        BoundaryViolation(
          posix,
          'feature 不得直接调用 WechatLauncher（必须经 CampusAction）',
        ),
      );
    }
  }

  violations.sort((a, b) => a.toString().compareTo(b.toString()));
  return violations;
}

void main() {
  final violations = collectBoundaryViolations();
  if (violations.isEmpty) {
    stdout.writeln('架构边界守卫通过：未发现 feature 侧平台启动违例。');
    return;
  }
  stderr.writeln('架构边界守卫失败，发现 ${violations.length} 条违例：');
  for (final violation in violations) {
    stderr.writeln('  - $violation');
  }
  exitCode = 1;
}
