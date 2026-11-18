import 'package:material_ui/material_ui.dart';

/// 课表色块的「底色 + 文字色」二元组（设计系统 v2 §2.2）。
///
/// 8 个色相在浅 / 深 / 纯黑三套表面上各自调过，保证 WCAG AA
/// （正文对比度 ≥ 4.5:1）而不是靠透明度硬压。
@immutable
class AppCourseHue {
  const AppCourseHue({required this.background, required this.foreground});

  final Color background;
  final Color foreground;

  AppCourseHue withOpacity(double opacity) => AppCourseHue(
    background: background.withValues(alpha: opacity),
    foreground: foreground.withValues(alpha: opacity),
  );
}

/// 设计系统 v2 的表面 / 语义 / 玻璃 / 课表色令牌。
///
/// 挂在 [ThemeData.extensions] 上，随 Light / Dark / AMOLED（纯黑）
/// 自动切换；通过 `context.appSurfaces` 取用。
///
/// **为什么不是全部塞进 [ColorScheme]**：M3 的语义槽位只有 primary /
/// container / surface 那几组，装不下「玻璃填充 + 高光边 + 遮罩 + 课表 8 色
/// + 网格辅助线」这些 v2 独有的层；而这些层又必须跟表面明度一起切。
/// 所以：基础阶梯仍以 [ColorScheme] 为准（本类里的 [card] / [tile] /
/// [pressed] 直接取自它，避免两处打架），v2 独有的层才在这里定义。
@immutable
class AppSurfaces extends ThemeExtension<AppSurfaces> {
  const AppSurfaces({
    required this.amoled,
    required this.scaffold,
    required this.card,
    required this.tile,
    required this.pressed,
    required this.ink1,
    required this.ink2,
    required this.ink3,
    required this.brand,
    required this.brandTint,
    required this.success,
    required this.successTint,
    required this.warning,
    required this.warningTint,
    required this.danger,
    required this.dangerTint,
    required this.neutral,
    required this.neutralTint,
    required this.glassFill,
    required this.glassRim,
    required this.scrim,
    required this.matrixLine,
    required this.hues,
    required this.dimmedHue,
  });

  /// 是否为纯黑（AMOLED）模式。阴影与雾面策略据此关闭 / 加重。
  final bool amoled;

  /// 页面底色（`--bg`）。
  final Color scaffold;

  /// 主内容卡（`--surface-lowest`）。
  final Color card;

  /// 卡内嵌块 / 次级分组（`--surface-low`）。
  final Color tile;

  /// 按下态 / 未选中轨道（`--surface-mid`）。
  final Color pressed;

  /// 主要文字与数字（`--ink-1`）。
  final Color ink1;

  /// 次要标签 / 行值 / 元信息（`--ink-2`）。
  final Color ink2;

  /// 占位 / 禁用 / chevron（`--ink-3`）。
  final Color ink3;

  /// 品牌强调（浅色 `#8B1A2D`，深色提亮到 `#E06C7E`）。
  final Color brand;

  /// 品牌淡底（选中胶囊、图标底）。
  final Color brandTint;

  final Color success;
  final Color successTint;
  final Color warning;
  final Color warningTint;
  final Color danger;
  final Color dangerTint;
  final Color neutral;
  final Color neutralTint;

  /// 浮动 Dock / 滚动顶栏的填充（唯一允许真实模糊的地方）。
  final Color glassFill;

  /// 玻璃高光边（`0.5dp` 内描边）。
  final Color glassRim;

  /// 弹层遮罩。
  final Color scrim;

  /// 课表二维网格的坐标辅助线——**只**用于时间 × 星期矩阵，
  /// 内容列表禁止出现任何分割线。
  final Color matrixLine;

  /// 8 色课表色板（顺序固定，索引即色相编号）。
  final List<AppCourseHue> hues;

  /// 非本周课程：降饱和到底色 + 弱化文字，但不至于看不见。
  final AppCourseHue dimmedHue;

  /// 稳定色相：同一门课在任意设备 / 任意次启动都是同一个颜色。
  ///
  /// 不用 `String.hashCode`——Dart 不保证跨版本稳定，换个大版本课表配色
  /// 就会整屏重排。这里用 FNV-1a 自己算。
  AppCourseHue hueFor(String key) {
    var hash = 0x811C9DC5;
    for (final unit in key.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hues[hash % hues.length];
  }

  /// 取课表 8 色板中的第 [index] 色（越界自动取模）。
  AppCourseHue hueAt(int index) => hues[index % hues.length];

  // ── 三套表面 ───────────────────────────────────────────────────────────

  static const _lightHues = <AppCourseHue>[
    AppCourseHue(background: Color(0xFFF9E6EA), foreground: Color(0xFF7A1829)),
    AppCourseHue(background: Color(0xFFE6EEFA), foreground: Color(0xFF1B4580)),
    AppCourseHue(background: Color(0xFFE2F3F0), foreground: Color(0xFF135D53)),
    AppCourseHue(background: Color(0xFFFDF0DC), foreground: Color(0xFF7C4800)),
    AppCourseHue(background: Color(0xFFEFE7F8), foreground: Color(0xFF4E267A)),
    AppCourseHue(background: Color(0xFFE6F4E8), foreground: Color(0xFF1E5E2A)),
    AppCourseHue(background: Color(0xFFFCE9E3), foreground: Color(0xFF802F19)),
    AppCourseHue(background: Color(0xFFE8EAFA), foreground: Color(0xFF2B3582)),
  ];

  static const _darkHues = <AppCourseHue>[
    AppCourseHue(background: Color(0xFF3B1A22), foreground: Color(0xFFF7B4C0)),
    AppCourseHue(background: Color(0xFF192942), foreground: Color(0xFFADC9F8)),
    AppCourseHue(background: Color(0xFF153330), foreground: Color(0xFF97DFD4)),
    AppCourseHue(background: Color(0xFF3A2812), foreground: Color(0xFFFAD08C)),
    AppCourseHue(background: Color(0xFF2B1D3D), foreground: Color(0xFFD5B8F8)),
    AppCourseHue(background: Color(0xFF193420), foreground: Color(0xFFA3E0AE)),
    AppCourseHue(background: Color(0xFF3B2019), foreground: Color(0xFFF7B9A6)),
    AppCourseHue(background: Color(0xFF1E2242), foreground: Color(0xFFBAC2FA)),
  ];

  static const _amoledHues = <AppCourseHue>[
    AppCourseHue(background: Color(0xFF33151C), foreground: Color(0xFFF9BDC8)),
    AppCourseHue(background: Color(0xFF142238), foreground: Color(0xFFB6D0FA)),
    AppCourseHue(background: Color(0xFF112B28), foreground: Color(0xFFA1E4DA)),
    AppCourseHue(background: Color(0xFF33220E), foreground: Color(0xFFFBD698)),
    AppCourseHue(background: Color(0xFF241734), foreground: Color(0xFFDCC2FA)),
    AppCourseHue(background: Color(0xFF142C1B), foreground: Color(0xFFADE5B7)),
    AppCourseHue(background: Color(0xFF331B15), foreground: Color(0xFFF9C2B1)),
    AppCourseHue(background: Color(0xFF181C38), foreground: Color(0xFFC4CBFC)),
  ];

  /// 浅色基线。
  static const AppSurfaces light = AppSurfaces(
    amoled: false,
    scaffold: Color(0xFFF3F4F6),
    card: Color(0xFFFFFFFF),
    tile: Color(0xFFECEEF2),
    pressed: Color(0xFFE2E5EB),
    ink1: Color(0xFF141619),
    ink2: Color(0xFF5A6068),
    ink3: Color(0xFF8C939D),
    brand: Color(0xFF8B1A2D),
    brandTint: Color(0xFFF6E7EA),
    success: Color(0xFF237A3B),
    successTint: Color(0xFFE5F3E8),
    warning: Color(0xFFB85C00),
    warningTint: Color(0xFFFDF0E1),
    danger: Color(0xFFC62828),
    dangerTint: Color(0xFFFDE8E8),
    neutral: Color(0xFF4E545C),
    neutralTint: Color(0xFFE8EBEF),
    glassFill: Color(0xD1FFFFFF),
    glassRim: Color(0xC2FFFFFF),
    scrim: Color(0x52151822),
    matrixLine: Color(0x0F141619),
    hues: _lightHues,
    dimmedHue: AppCourseHue(
      background: Color(0xFFECEEF2),
      foreground: Color(0xFF8C939D),
    ),
  );

  /// 深色基线（中性石板，零粉色偏色）。
  static const AppSurfaces dark = AppSurfaces(
    amoled: false,
    scaffold: Color(0xFF111315),
    card: Color(0xFF1A1D21),
    tile: Color(0xFF22262B),
    pressed: Color(0xFF2B3036),
    ink1: Color(0xFFF1F3F5),
    ink2: Color(0xFF9AA1AB),
    ink3: Color(0xFF68707A),
    brand: Color(0xFFE06C7E),
    brandTint: Color(0x29E06C7E),
    success: Color(0xFF66CE82),
    successTint: Color(0x2666CE82),
    warning: Color(0xFFFFB357),
    warningTint: Color(0x26FFB357),
    danger: Color(0xFFFF7676),
    dangerTint: Color(0x26FF7676),
    neutral: Color(0xFFB4BBC4),
    neutralTint: Color(0x1FB4BBC4),
    glassFill: Color(0xC71A1D21),
    glassRim: Color(0x1AFFFFFF),
    scrim: Color(0x8F000000),
    matrixLine: Color(0x0FFFFFFF),
    hues: _darkHues,
    dimmedHue: AppCourseHue(
      background: Color(0xFF22262B),
      foreground: Color(0xFF68707A),
    ),
  );

  /// 纯黑（AMOLED）：真黑脚手架 + 关闭投影。
  static const AppSurfaces amoledSurfaces = AppSurfaces(
    amoled: true,
    scaffold: Color(0xFF000000),
    card: Color(0xFF0D0F12),
    tile: Color(0xFF16191E),
    pressed: Color(0xFF20242B),
    ink1: Color(0xFFF5F7FA),
    ink2: Color(0xFFA0A7B1),
    ink3: Color(0xFF6E7681),
    brand: Color(0xFFE57889),
    brandTint: Color(0x2EE57889),
    success: Color(0xFF66CE82),
    successTint: Color(0x2966CE82),
    warning: Color(0xFFFFB357),
    warningTint: Color(0x29FFB357),
    danger: Color(0xFFFF7676),
    dangerTint: Color(0x29FF7676),
    neutral: Color(0xFFB8BFC8),
    neutralTint: Color(0x21B8BFC8),
    glassFill: Color(0xD6121418),
    glassRim: Color(0x1FFFFFFF),
    scrim: Color(0xAD000000),
    matrixLine: Color(0x12FFFFFF),
    hues: _amoledHues,
    dimmedHue: AppCourseHue(
      background: Color(0xFF16191E),
      foreground: Color(0xFF6E7681),
    ),
  );

  /// 把静态基线对齐到实际 [ColorScheme]。
  ///
  /// 个性化主题（嘉大蓝 / 湖青 …）会把表面染上种子色，这时若仍返回硬编码
  /// 的白 / 石板色，卡面就会和 scaffold 打架。所以基础阶梯取 [cs]，
  /// 只有 v2 独有的层（玻璃 / 网格线 / 课表色）按明度取基线。
  factory AppSurfaces.resolve(ColorScheme cs, {bool amoled = false}) {
    final isDark = cs.brightness == Brightness.dark;
    final base = amoled
        ? amoledSurfaces
        : isDark
        ? dark
        : light;
    return base.copyWith(
      // 深色主题把页面底色放在 surfaceContainerLowest（M3 阶梯在这里是反的），
      // 浅色主题的页面底色才是 surface 本身。
      scaffold: isDark ? cs.surfaceContainerLowest : cs.surface,
      card: isDark ? cs.surfaceContainerLow : cs.surfaceContainerLowest,
      tile: cs.surfaceContainerHighest,
      pressed: cs.surfaceContainerHigh,
      ink1: cs.onSurface,
      ink2: cs.onSurfaceVariant,
      brand: cs.primary,
      brandTint: cs.primary.withValues(alpha: isDark ? 0.16 : 0.10),
    );
  }

  @override
  AppSurfaces copyWith({
    bool? amoled,
    Color? scaffold,
    Color? card,
    Color? tile,
    Color? pressed,
    Color? ink1,
    Color? ink2,
    Color? ink3,
    Color? brand,
    Color? brandTint,
    Color? success,
    Color? successTint,
    Color? warning,
    Color? warningTint,
    Color? danger,
    Color? dangerTint,
    Color? neutral,
    Color? neutralTint,
    Color? glassFill,
    Color? glassRim,
    Color? scrim,
    Color? matrixLine,
    List<AppCourseHue>? hues,
    AppCourseHue? dimmedHue,
  }) {
    return AppSurfaces(
      amoled: amoled ?? this.amoled,
      scaffold: scaffold ?? this.scaffold,
      card: card ?? this.card,
      tile: tile ?? this.tile,
      pressed: pressed ?? this.pressed,
      ink1: ink1 ?? this.ink1,
      ink2: ink2 ?? this.ink2,
      ink3: ink3 ?? this.ink3,
      brand: brand ?? this.brand,
      brandTint: brandTint ?? this.brandTint,
      success: success ?? this.success,
      successTint: successTint ?? this.successTint,
      warning: warning ?? this.warning,
      warningTint: warningTint ?? this.warningTint,
      danger: danger ?? this.danger,
      dangerTint: dangerTint ?? this.dangerTint,
      neutral: neutral ?? this.neutral,
      neutralTint: neutralTint ?? this.neutralTint,
      glassFill: glassFill ?? this.glassFill,
      glassRim: glassRim ?? this.glassRim,
      scrim: scrim ?? this.scrim,
      matrixLine: matrixLine ?? this.matrixLine,
      hues: hues ?? this.hues,
      dimmedHue: dimmedHue ?? this.dimmedHue,
    );
  }

  @override
  AppSurfaces lerp(covariant AppSurfaces? other, double t) {
    if (other == null) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    AppCourseHue h(AppCourseHue a, AppCourseHue b) => AppCourseHue(
      background: c(a.background, b.background),
      foreground: c(a.foreground, b.foreground),
    );
    return AppSurfaces(
      amoled: t < 0.5 ? amoled : other.amoled,
      scaffold: c(scaffold, other.scaffold),
      card: c(card, other.card),
      tile: c(tile, other.tile),
      pressed: c(pressed, other.pressed),
      ink1: c(ink1, other.ink1),
      ink2: c(ink2, other.ink2),
      ink3: c(ink3, other.ink3),
      brand: c(brand, other.brand),
      brandTint: c(brandTint, other.brandTint),
      success: c(success, other.success),
      successTint: c(successTint, other.successTint),
      warning: c(warning, other.warning),
      warningTint: c(warningTint, other.warningTint),
      danger: c(danger, other.danger),
      dangerTint: c(dangerTint, other.dangerTint),
      neutral: c(neutral, other.neutral),
      neutralTint: c(neutralTint, other.neutralTint),
      glassFill: c(glassFill, other.glassFill),
      glassRim: c(glassRim, other.glassRim),
      scrim: c(scrim, other.scrim),
      matrixLine: c(matrixLine, other.matrixLine),
      hues: [
        for (var i = 0; i < hues.length; i++)
          h(hues[i], other.hues[i % other.hues.length]),
      ],
      dimmedHue: h(dimmedHue, other.dimmedHue),
    );
  }
}

extension AppSurfacesContext on BuildContext {
  /// 当前主题的 [AppSurfaces]；未注册时按当前 [ColorScheme] 现算。
  AppSurfaces get appSurfaces {
    final theme = Theme.of(this);
    return theme.extension<AppSurfaces>() ??
        AppSurfaces.resolve(
          theme.colorScheme,
          amoled: theme.scaffoldBackgroundColor == const Color(0xFF000000),
        );
  }
}
