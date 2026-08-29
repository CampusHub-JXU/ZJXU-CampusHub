import 'package:flutter/material.dart';

import '../../app/app_theme_controller.dart';
import '../../core/theme/app_design_tokens.dart';

enum AppIconBadgeSize { small, medium, large }

/// 统一图标徽标。
///
/// 收敛散落的 badge 尺寸（36/38/40 + 圆角 9/10/12/13 + 图标 20/21/22）为
/// small / medium / large 三档，取自 [AppBadgeSize] token。
/// 图标颜色经 [AppThemeController.resolveIconColor] 解析：莫奈模式跟随主题色，
/// 其余模式透传 [accentColor]，使 feature_entry_catalog 的入口色板生效。
class AppIconBadge extends StatelessWidget {
  const AppIconBadge({
    super.key,
    required this.icon,
    required this.accentColor,
    this.size = AppIconBadgeSize.medium,
    this.backgroundAlpha = 0.12,
  });

  final IconData icon;
  final Color accentColor;
  final AppIconBadgeSize size;
  final double backgroundAlpha;

  @override
  Widget build(BuildContext context) {
    var iconColor = AppThemeController.instance.resolveIconColor(
      context,
      accentColor,
    );
    // 深色模式把饱和 accent 提亮一档：暗底上原色（如酒红）会沉成泥色，
    // 徽标几乎读不出图形。
    if (Theme.of(context).brightness == Brightness.dark) {
      iconColor = Color.lerp(iconColor, Colors.white, 0.15)!;
    }
    final spec = _specFor(size);
    return Container(
      width: spec.box,
      height: spec.box,
      decoration: BoxDecoration(
        color: iconColor.withValues(alpha: backgroundAlpha),
        borderRadius: BorderRadius.circular(spec.radius),
      ),
      child: Icon(icon, color: iconColor, size: spec.icon),
    );
  }

  _BadgeSpec _specFor(AppIconBadgeSize s) {
    return switch (s) {
      AppIconBadgeSize.small => const _BadgeSpec(
        AppBadgeSize.smallBox,
        AppBadgeSize.smallIcon,
        AppBadgeSize.smallRadius,
      ),
      AppIconBadgeSize.medium => const _BadgeSpec(
        AppBadgeSize.mediumBox,
        AppBadgeSize.mediumIcon,
        AppBadgeSize.mediumRadius,
      ),
      AppIconBadgeSize.large => const _BadgeSpec(
        AppBadgeSize.largeBox,
        AppBadgeSize.largeIcon,
        AppBadgeSize.largeRadius,
      ),
    };
  }
}

class _BadgeSpec {
  const _BadgeSpec(this.box, this.icon, this.radius);

  final double box;
  final double icon;
  final double radius;
}
