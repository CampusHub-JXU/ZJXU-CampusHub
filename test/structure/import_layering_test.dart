import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 分层 import 规则守卫。
///
/// 锁定 lib/ 的依赖方向：app → features → core/shared，core 与 shared
/// 不得反向依赖 app / features，feature 之间不得横向依赖。
/// feature 横向依赖现存历史债务（home 聚合枢纽、notification_center 聚合页等，
/// 属 P2 松散化范围）登记在 [_allowedFeatureEdges] 棘轮清单中：新增违例会被
/// 本测试拦下；修复后须同步从清单删除对应条目（清单中出现已不存在的边也会失败）。
void main() {
  test('lib/ 分层 import 规则', () {
    final violations = <String>[];

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final srcRel = _toLibPosix(entity.path);
      final srcModule = _moduleOf(srcRel);
      if (srcModule == null) continue;

      final text = entity.readAsStringSync();
      for (final match in _importExp.allMatches(text)) {
        final uri = match.group(1)!.trim();
        final targetRel = _resolveToLibPosix(srcRel, uri);
        if (targetRel == null) continue;
        final targetModule = _moduleOf(targetRel);
        if (targetModule == null || targetModule == srcModule) continue;

        final rule = _violatedRule(srcModule, targetModule);
        if (rule != null) {
          violations.add('$srcRel -> $targetRel');
        }
      }
    }

    final unknown =
        violations.where((v) => !_allowedLegacyEdges.contains(v)).toList()
          ..sort();
    final stale = _allowedLegacyEdges.difference(violations.toSet()).toList()
      ..sort();

    expect(
      unknown,
      isEmpty,
      reason:
          'lib/ 存在新的分层违例（依赖方向必须为 app → features → '
          'core/shared，feature 之间禁止横向依赖）：\n${unknown.join('\n')}',
    );
    expect(
      stale,
      isEmpty,
      reason:
          '以下遗留分层债务已不存在，请从 _allowedLegacyEdges '
          '棘轮清单中删除：\n${stale.join('\n')}',
    );
  });
}

/// P2 遗留的分层债务（文件级白名单，棘轮只减不增）。
const _allowedLegacyEdges = <String>{
  // features → app：组合层工具（bootstrap 状态 / 路由观察者）待下沉或反转（P2 目标）
  'features/campus_card/campus_card_page.dart -> app/app_bootstrap_controller.dart',
  'features/campus_card/campus_card_payment_page.dart -> app/app_route_observer.dart',
  'features/home/home_page.dart -> app/app_bootstrap_controller.dart',
  // home 聚合页：home_page 只留纯模型类型；业务 service 拉取已集中到
  // features/home/campus_snapshot_coordinator.dart（PRD §10/§11 的聚合点）。
  'features/home/function_zone/function_zone_section.dart -> features/service_hub/service_hub_usage_store.dart',
  'features/home/home_page.dart -> features/exam/exam_model.dart',
  'features/home/home_page.dart -> features/schedule/schedule_cache_snapshot.dart',
  'features/home/campus_snapshot_coordinator.dart -> features/campus_card/campus_card_service.dart',
  'features/home/campus_snapshot_coordinator.dart -> features/dorm_electricity/dorm_electricity_service.dart',
  'features/home/campus_snapshot_coordinator.dart -> features/exam/exam_model.dart',
  'features/home/campus_snapshot_coordinator.dart -> features/exam/exam_service.dart',
  'features/home/campus_snapshot_coordinator.dart -> features/grades/grades_service.dart',
  'features/home/campus_snapshot_coordinator.dart -> features/schedule/schedule_cache_snapshot.dart',
  'features/home/campus_snapshot_coordinator.dart -> features/schedule/schedule_service.dart',
  'features/home/home_presentation_resolver.dart -> features/exam/exam_model.dart',
  'features/home/home_presentation_resolver.dart -> features/schedule/schedule_model.dart',
  'features/home/home_presentation_resolver.dart -> features/schedule/schedule_service.dart',
  'features/home/models/home_snapshot.dart -> features/exam/exam_model.dart',
  'features/home/models/home_snapshot.dart -> features/schedule/schedule_change_rule.dart',
  'features/home/models/home_snapshot.dart -> features/schedule/schedule_model.dart',
  // my 页快捷入口
  'features/my/my_page.dart -> features/schedule/schedule_service.dart',
  // 通知中心聚合页（notice 核心 2026-09 下沉 core/notice 后，原
  // notification_center -> features/notice 例外随 edge 消失一并移除）
  'features/notification_center/notification_center_page.dart -> features/sjjx_notice/sjjx_notice_model.dart',
  'features/notification_center/notification_center_page.dart -> features/sjjx_notice/sjjx_notice_service.dart',
};

final _importExp = RegExp(
  r"^\s*(?:import|export)\s+'([^']+)'",
  multiLine: true,
);

String _toLibPosix(String path) {
  final normalized = path.replaceAll('\\', '/');
  final index = normalized.indexOf('lib/');
  return normalized.substring(index + 4);
}

/// 解析 import URI 为 lib 相对 posix 路径；dart:/三方包返回 null，
/// 仅解析本包（相对路径或 package:jxu_campus_hub/）。
String? _resolveToLibPosix(String srcRel, String uri) {
  if (uri.startsWith('package:')) {
    const prefix = 'package:jxu_campus_hub/';
    if (!uri.startsWith(prefix)) return null;
    return uri.substring(prefix.length);
  }
  if (uri.startsWith('dart:')) return null;
  final parts = srcRel.split('/')..removeLast();
  for (final segment in uri.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (parts.isNotEmpty) parts.removeLast();
      continue;
    }
    parts.add(segment);
  }
  return parts.join('/');
}

String? _moduleOf(String libRelPath) {
  final parts = libRelPath.split('/');
  if (parts.length < 2) return null;
  switch (parts.first) {
    case 'app':
      return 'app';
    case 'shared':
      return 'shared';
    case 'core':
      return 'core';
    case 'features':
      return 'features/${parts[1]}';
    default:
      return null;
  }
}

/// 返回违例规则描述；合法依赖返回 null。
String? _violatedRule(String src, String target) {
  if (src == 'core' || src == 'shared') {
    if (target == 'app') return 'core/shared 不得依赖 app';
    if (target == 'features' || target.startsWith('features/')) {
      return 'core/shared 不得依赖 features';
    }
  }
  if (src.startsWith('features/')) {
    if (target == 'app') return 'features 不得依赖 app';
    if (target.startsWith('features/') && src != target) {
      return 'feature 之间禁止横向依赖';
    }
  }
  return null;
}
