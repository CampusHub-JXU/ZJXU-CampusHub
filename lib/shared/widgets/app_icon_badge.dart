import 'package:material_ui/material_ui.dart';

import '../../core/theme/app_theme_controller.dart';

enum AppIconBadgeSize { small, medium, large }

/// 统一裸图标容器。
///
/// 不再绘制圆角方块底色，仅承担统一取色（普通图标走主题主色、状态语义色需显式
/// [semantic]、深色模式向白提亮 15%）与三档列表/行首对齐盒尺寸：
/// - [AppIconBadgeSize.small]：24dp 占位盒 + 22dp 图标
/// - [AppIconBadgeSize.medium]：28dp 占位盒 + 24dp 图标
/// - [AppIconBadgeSize.large]：32dp 占位盒 + 28dp 图标
class AppIconBadge extends StatelessWidget {
  const AppIconBadge({
    super.key,
    required this.icon,
    required this.accentColor,
    this.size = AppIconBadgeSize.medium,
    @Deprecated('不再绘制底座背景，仅保留参数兼容') this.backgroundAlpha = 0.12,
    this.semantic = false,
  });

  final IconData icon;
  final Color accentColor;
  final AppIconBadgeSize size;

  /// 已废弃：不再绘制圆角色块底座，仅保留构造参数兼容。
  final double backgroundAlpha;
  final bool semantic;

  @override
  Widget build(BuildContext context) {
    var iconColor = AppThemeController.instance.resolveIconColor(
      context,
      accentColor,
      semantic: semantic,
    );
    // 深色模式把饱和 accent 提亮一档：暗底上原色（如酒红）会沉成泥色，
    // 裸图标几乎读不出图形。
    if (Theme.of(context).brightness == Brightness.dark) {
      iconColor = Color.lerp(iconColor, Colors.white, 0.15)!;
    }
    final spec = _specFor(size);
    return SizedBox(
      width: spec.box,
      height: spec.box,
      child: Center(
        child: Icon(icon, color: iconColor, size: spec.icon),
      ),
    );
  }

  _BadgeSpec _specFor(AppIconBadgeSize s) {
    return switch (s) {
      AppIconBadgeSize.small => const _BadgeSpec(24, 22),
      AppIconBadgeSize.medium => const _BadgeSpec(28, 24),
      AppIconBadgeSize.large => const _BadgeSpec(32, 28),
    };
  }
}

class _BadgeSpec {
  const _BadgeSpec(this.box, this.icon);

  final double box;
  final double icon;
}
