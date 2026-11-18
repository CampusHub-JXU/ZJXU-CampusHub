import 'package:material_ui/material_ui.dart';

import '../../core/theme/app_theme_controller.dart';
import '../../core/theme/app_design_tokens.dart';

enum AppIconBadgeSize { small, medium, large }

/// 统一图标徽标。
///
/// 收敛散落的 badge 尺寸（36/38/40 + 圆角 9/10/12/13 + 图标 20/21/22）为
/// small / medium / large 三档，取自 [AppBadgeSize] token。
/// 普通装饰图标走主题色；状态语义色需显式 [semantic]。
class AppIconBadge extends StatelessWidget {
  const AppIconBadge({
    super.key,
    required this.icon,
    required this.accentColor,
    this.size = AppIconBadgeSize.medium,
    this.backgroundAlpha = 0.12,
    this.semantic = false,
  });

  final IconData icon;
  final Color accentColor;
  final AppIconBadgeSize size;
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
