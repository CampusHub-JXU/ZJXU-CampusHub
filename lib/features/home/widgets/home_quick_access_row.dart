import 'package:flutter/material.dart';

import '../../../core/config/feature_entry_catalog.dart';

/// 首页「快捷入口」行：课表 / 成绩 / 考试 / 付款码 一行内联捷径。
///
/// 填充资产行与校园公告之间的首屏空间；中性灰小图标 + 单行文字、
/// 无框无彩色，视觉权重低于资产行，更低于功能区。入口定义取自
/// [AppFeaturesConfig]（路由/图标不重复维护），标签用更短的口语化
/// 文案（与功能区的全称瓦片区分开）。
class HomeQuickAccessRow extends StatelessWidget {
  const HomeQuickAccessRow({super.key, required this.onTapRoute});

  /// 统一跳转回调：传入目录 routeName，沿用首页「返回后刷新」逻辑。
  final ValueChanged<String> onTapRoute;

  static const _quickIds = [
    'schedule',
    'grades',
    'exam',
    'campus-card-payment',
  ];

  static const _shortLabelById = {
    'schedule': '课表',
    'grades': '成绩',
    'exam': '考试',
    'campus-card-payment': '付款码',
  };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final entries = _quickIds.map(
      (id) => AppFeaturesConfig.entries.firstWhere((entry) => entry.id == id),
    );

    // 内联「图标 + 文字」单行工具条：中性灰图标、无框、无彩色——刻意
    // 避开 dock 的「图标叠标签」造型与彩色徽标，读作一行轻量捷径而非
    // 第二个底栏。
    //
    // 左对齐 + 固定间距（与上方资产行的左对齐节奏一致，首项「课表」
    // 与「校园卡」共享同一条左基线）；spaceEvenly 会让四项漂浮居中，
    // 与资产行错位。
    return Row(
      children: [
        for (final (index, entry) in entries.indexed) ...[
          if (index > 0) const SizedBox(width: 28),
          InkWell(
            onTap: () => onTapRoute(entry.routeName),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(entry.icon, size: 17, color: cs.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Text(
                    _shortLabelById[entry.id]!,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: cs.onSurface,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}
