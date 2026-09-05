import 'package:flutter/material.dart';

import '../../../core/config/feature_entry_catalog.dart';
import '../../../shared/widgets/app_tile_surface.dart';

/// 首页「快捷入口」行：课表 / 成绩 / 考试 / 付款码 四枚紧凑磁贴。
///
/// 填充资产行与校园公告之间的首屏空间，减少「下半屏空置」的松散感；
/// 入口定义取自 [AppFeaturesConfig]（路由/图标/着色不重复维护），
/// 标签用更短的口语化文案（与功能区的全称瓦片区分开）。视觉权重刻意
/// 低于功能区：小尺寸、单行标签、仅作直达捷径。
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

    return Row(
      children: [
        for (final (index, entry) in entries.indexed) ...[
          Expanded(
            child: AppTileSurface(
              onTap: () => onTapRoute(entry.routeName),
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(entry.icon, size: 22, color: entry.accentColor),
                  const SizedBox(height: 6),
                  Text(
                    _shortLabelById[entry.id]!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: cs.onSurface,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (index != _quickIds.length - 1) const SizedBox(width: 10),
        ],
      ],
    );
  }
}
