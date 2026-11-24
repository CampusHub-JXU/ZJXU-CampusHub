import 'package:cupertino_ui/cupertino_ui.dart'
    show CupertinoPageTransitionsBuilder;
import 'package:material_ui/material_ui.dart';

import 'app_design_tokens.dart';
import 'app_surface_tokens.dart';
import 'app_typography.dart';
import 'page_transition_activity.dart';

/// Material 3 theme builder.
///
/// Builds light/dark [ThemeData] from a seed color, optionally
/// overriding dark surfaces for pure-black (AMOLED) mode.
///
/// 形状语言采用连续曲率圆角（squircle，[RoundedSuperellipseBorder]），
/// 与玻璃材质组件（GlassContainer）共用 [AppRadius] 阶梯。
class AppThemeBuilder {
  AppThemeBuilder._();

  static const Color _graphiteSeed = Color(0xFF455A64);
  static const Color _brandRedSeed = Color(0xFF8B1A2D);

  /// Apple 风格字阶（Inter 与 SF Pro 同骨架）：
  ///
  /// * Inter 以拉丁 + 数字子集随包分发（`assets/fonts/inter/`，400–700 四档），
  ///   中文不在子集内，由系统字体回退；
  ///
  /// * 展示档（headline/titleLarge）用重字重 + 收紧字距，贴近 SF Pro
  ///   Display 的排版密度；正文/标签档只调行高与字重，保持中文可读性；
  /// * 颜色不在此指定，由 ThemeData 统一套 colorScheme 的 onSurface /
  ///   onSurfaceVariant。
  static const TextTheme _appleTextTheme = TextTheme(
    headlineLarge: TextStyle(
      fontSize: 32,
      fontWeight: FontWeight.w700,
      height: 1.2,
      letterSpacing: -0.5,
    ),
    headlineMedium: TextStyle(
      fontSize: 28,
      fontWeight: FontWeight.w700,
      height: 1.2,
      letterSpacing: -0.4,
    ),
    headlineSmall: TextStyle(
      fontSize: 22,
      fontWeight: FontWeight.w700,
      height: 1.25,
      letterSpacing: -0.3,
    ),
    titleLarge: TextStyle(
      fontSize: 20,
      fontWeight: FontWeight.w600,
      height: 1.3,
      letterSpacing: -0.3,
    ),
    titleMedium: TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w600,
      height: 1.3,
      letterSpacing: -0.2,
    ),
    titleSmall: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      height: 1.3,
    ),
    bodyLarge: TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w400,
      height: 1.45,
    ),
    bodyMedium: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w400,
      height: 1.4,
    ),
    bodySmall: TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w400,
      height: 1.35,
    ),
    labelLarge: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      height: 1.2,
    ),
    labelMedium: TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w500,
      height: 1.2,
    ),
    labelSmall: TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w500,
      height: 1.2,
    ),
  );

  /// 中性种子（石墨/品牌红）：深浅两种模式下 surface 阶梯都不掺种子色，
  /// 品牌色只保留在 primary/强调场景，避免深色"血色"或浅色粉调背景。
  static bool _isNeutralSeed(Color seedColor) =>
      seedColor == _graphiteSeed || seedColor == _brandRedSeed;

  // ── Light ──────────────────────────────────────────────────────────────

  /// 弹出菜单（`PopupMenuButton`）与 [AppDropdown] 的弹层同一材质：
  /// surfaceContainerHigh + 输入框圆角 + 0.3 描边，避免出现原生 Material 菜单。
  static PopupMenuThemeData _popupMenuTheme(ColorScheme colorScheme) {
    final light = colorScheme.brightness == Brightness.light;
    return PopupMenuThemeData(
      // 浅色菜单走纯白卡面（比页面底色更亮），靠投影分层；深色沿用最高面阶。
      color: light
          ? colorScheme.surfaceContainerLowest
          : colorScheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      elevation: 6,
      shadowColor: colorScheme.shadow,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadius.inputBorder,
        side: BorderSide(
          color: colorScheme.outlineVariant.withValues(alpha: 0.3),
        ),
      ),
      textStyle: TextStyle(
        fontSize: 13.5,
        fontWeight: FontWeight.w500,
        color: colorScheme.onSurface,
      ),
    );
  }

  /// 分段控件（`SegmentedButton`）统一外观：扁平、紧凑、低对比的圆角分段，
  /// 取代 MD3 默认的「显眼外框 + 胶囊 + 段间分隔线」，供全 App 调用点共用。
  ///
  /// `side = BorderSide.none` 一次去掉外框与段间分隔线（渲染盒用 `side` 画分隔
  /// 线）；`shape` 改为 [AppRadius.segment] 圆角矩形；轨道 + 亮滑块（见下方取色）
  /// / 未选中 `surfaceContainer`，字色 `onSurface` / `onSurfaceVariant`；视觉高度
  /// 40、移动端命中区由框架补到 48；键盘焦点用主色淡化。完整契约与实测见
  /// `docs/segmented-control-style.md`。
  static SegmentedButtonThemeData _segmentedButtonTheme(
    ColorScheme colorScheme,
  ) {
    final TextStyle labelBase = _appleTextTheme.labelLarge!.copyWith(
      fontFamily: 'Inter',
    );
    // 浅色轨道略加前景色，保留和 surfaceContainerLowest 滑块的对比。
    // 深色滑块在最高面阶上叠 16% 前景色提亮。
    final dark = colorScheme.brightness == Brightness.dark;
    final Color track = dark
        ? colorScheme.surfaceContainerHigh
        : Color.alphaBlend(
            colorScheme.onSurface.withValues(alpha: 0.04),
            colorScheme.surfaceContainerHigh,
          );
    final Color selectedThumb = dark
        ? Color.alphaBlend(
            colorScheme.onSurface.withValues(alpha: 0.16),
            colorScheme.surfaceContainerHighest,
          )
        : colorScheme.surfaceContainerLowest;
    return SegmentedButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll<OutlinedBorder>(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.segment),
          ),
        ),
        side: const WidgetStatePropertyAll<BorderSide>(BorderSide.none),
        minimumSize: const WidgetStatePropertyAll<Size?>(Size.fromHeight(40)),
        padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
          EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        ),
        elevation: const WidgetStatePropertyAll<double>(0),
        surfaceTintColor: const WidgetStatePropertyAll<Color>(
          Colors.transparent,
        ),
        iconSize: const WidgetStatePropertyAll<double?>(18),
        textStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return labelBase.copyWith(
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          );
        }),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return selectedThumb;
          return track;
        }),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return colorScheme.onSurface.withValues(alpha: 0.38);
          }
          if (states.contains(WidgetState.selected)) {
            return colorScheme.onSurface;
          }
          return colorScheme.onSurfaceVariant;
        }),
        overlayColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return Colors.transparent;
          }
          if (states.contains(WidgetState.pressed)) {
            return colorScheme.onSurface.withValues(alpha: 0.12);
          }
          if (states.contains(WidgetState.focused)) {
            return colorScheme.primary.withValues(alpha: 0.16);
          }
          if (states.contains(WidgetState.hovered)) {
            return colorScheme.onSurface.withValues(alpha: 0.06);
          }
          return null;
        }),
      ),
    );
  }

  static ThemeData light(Color seedColor) {
    var colorScheme = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: Brightness.light,
    ).copyWith(primary: seedColor);

    // 中性种子：浅色模式走清透中性冷灰表面阶梯，阻断种子色粉调渗入
    // （背景 #FEF8F7、描边 #E2DDDC 之类的粉白观感），理顺 M3 递增阶梯，
    // 显式覆盖中性灰文字/描边色，消除品牌红带来的暖粉灰混杂感。
    if (_isNeutralSeed(seedColor)) {
      colorScheme = colorScheme.copyWith(
        surface: const Color(0xFFF7F8FA),
        surfaceContainerLowest: const Color(0xFFFFFFFF),
        surfaceContainerLow: const Color(0xFFFAFBFC),
        surfaceContainer: const Color(0xFFF2F4F7),
        surfaceContainerHigh: const Color(0xFFECEFF3),
        surfaceContainerHighest: const Color(0xFFE6E9EE),
        onSurfaceVariant: const Color(0xFF5A6068),
        outline: const Color(0xFF8C939D),
        outlineVariant: const Color(0xFFE3E6EC),
      );
    } else {
      // 非中性种子：保留淡淡主题色调的同时适度向清透白灰靠拢，
      // 避免默认 M3 浅色表面偏灰偏浊。
      colorScheme = colorScheme.copyWith(
        surface: _mix(colorScheme.surface, const Color(0xFFF7F8FA), 0.45),
        surfaceContainerLowest: const Color(0xFFFFFFFF),
        surfaceContainerLow: _mix(
          colorScheme.surfaceContainerLow,
          const Color(0xFFFAFBFC),
          0.40,
        ),
        surfaceContainer: _mix(
          colorScheme.surfaceContainer,
          const Color(0xFFF2F4F7),
          0.35,
        ),
        surfaceContainerHigh: _mix(
          colorScheme.surfaceContainerHigh,
          const Color(0xFFECEFF3),
          0.35,
        ),
        surfaceContainerHighest: _mix(
          colorScheme.surfaceContainerHighest,
          const Color(0xFFE6E9EE),
          0.35,
        ),
      );
    }

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      fontFamily: 'Inter',
      textTheme: _appleTextTheme,
      splashFactory: NoSplash.splashFactory,
      splashColor: Colors.transparent,
      highlightColor: colorScheme.onSurface.withValues(alpha: 0.05),
      extensions: [
        AppTypography.fromScheme(colorScheme),
        AppSurfaces.resolve(colorScheme),
      ],
      scaffoldBackgroundColor: colorScheme.surface,
      pageTransitionsTheme: _appPageTransitionsTheme,
      appBarTheme: AppBarTheme(
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 2,
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.onSurface,
        surfaceTintColor: colorScheme.primary,
        titleTextStyle: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: colorScheme.onSurface,
        ),
      ),
      cardTheme: CardThemeData(
        color: colorScheme.surfaceContainerLowest,
        elevation: 0,
        shape: RoundedSuperellipseBorder(borderRadius: AppRadius.cardAltBorder),
        margin: EdgeInsets.zero,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: colorScheme.surfaceContainerLow,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(AppRadius.sheet),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: colorScheme.primary,
          foregroundColor: colorScheme.onPrimary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.control),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: colorScheme.primary,
          side: BorderSide(color: colorScheme.primary),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.control),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: colorScheme.primary,
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colorScheme.surfaceContainerHighest,
        border: OutlineInputBorder(
          borderRadius: AppRadius.inputBorder,
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: AppRadius.inputBorder,
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: AppRadius.inputBorder,
          borderSide: BorderSide(color: colorScheme.primary, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
      ),
      popupMenuTheme: _popupMenuTheme(colorScheme),
      segmentedButtonTheme: _segmentedButtonTheme(colorScheme),
      bottomSheetTheme: BottomSheetThemeData(
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadius.sheet),
          ),
        ),
        backgroundColor: colorScheme.surfaceContainerLowest,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: colorScheme.surfaceContainerLowest,
        indicatorColor: colorScheme.primary.withValues(alpha: 0.12),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: colorScheme.primary,
            );
          }
          return TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant);
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return IconThemeData(color: colorScheme.primary);
          }
          return IconThemeData(color: colorScheme.onSurfaceVariant);
        }),
      ),
      dividerTheme: DividerThemeData(
        color: colorScheme.outlineVariant,
        thickness: 0.5,
        space: 1,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: colorScheme.surfaceContainerHighest,
        selectedColor: colorScheme.primary.withValues(alpha: 0.12),
        labelStyle: TextStyle(fontSize: 13, color: colorScheme.onSurface),
        shape: RoundedRectangleBorder(borderRadius: AppRadius.chipBorder),
        side: BorderSide.none,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: colorScheme.primary,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: colorScheme.inverseSurface,
        contentTextStyle: TextStyle(color: colorScheme.onInverseSurface),
        shape: RoundedSuperellipseBorder(borderRadius: AppRadius.cardBorder),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ── Dark ───────────────────────────────────────────────────────────────

  static Color _mix(Color a, Color b, double t) => Color.lerp(a, b, t)!;

  static Color _foregroundFor(Color background) =>
      background.computeLuminance() > 0.45 ? Colors.black : Colors.white;

  static Color _darkSeedTone(Color seedColor, double lightness) {
    final hsl = HSLColor.fromColor(seedColor);
    return hsl
        .withSaturation((hsl.saturation * 0.72).clamp(0.28, 0.78))
        .withLightness(lightness)
        .toColor();
  }

  static ThemeData dark(Color seedColor, {bool pureBlack = false}) {
    final isNeutralDark = _isNeutralSeed(seedColor);
    final baseScheme = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: Brightness.dark,
    );
    final seedBase = _darkSeedTone(seedColor, 0.12);
    final seedRaised = _darkSeedTone(seedColor, 0.18);
    final seedHigh = _darkSeedTone(seedColor, 0.24);

    // 深色三档取自 design system v2（`--bg / --surface-lowest /
    // --surface-low / --surface-mid`），纯黑模式关掉一切提亮。
    final darkBase = pureBlack
        ? const Color(0xFF000000)
        : isNeutralDark
        ? const Color(0xFF111315)
        : baseScheme.surface;
    final darkSurf = pureBlack
        ? const Color(0xFF0D0F12)
        : isNeutralDark
        ? const Color(0xFF1A1D21)
        : baseScheme.surfaceContainerLow;
    final darkSurfHigh = pureBlack
        ? const Color(0xFF16191E)
        : isNeutralDark
        ? const Color(0xFF22262B)
        : baseScheme.surfaceContainerHigh;

    final background = isNeutralDark
        ? darkBase
        : _mix(darkBase, seedBase, pureBlack ? 0.0 : 0.42);
    final surface = isNeutralDark
        ? darkSurf
        : _mix(darkSurf, seedRaised, pureBlack ? 0.0 : 0.52);
    final surfaceHigh = isNeutralDark
        ? darkSurfHigh
        : _mix(darkSurfHigh, seedHigh, pureBlack ? 0.0 : 0.58);
    var colorScheme = baseScheme.copyWith(
      surface: surface,
      surfaceContainerHighest: surfaceHigh,
      surfaceContainerHigh: isNeutralDark
          ? surfaceHigh
          : _mix(
              pureBlack
                  ? const Color(0xFF0E0E0E)
                  : baseScheme.surfaceContainerHigh,
              seedHigh,
              pureBlack ? 0.0 : 0.28,
            ),
      surfaceContainer: surface,
      surfaceContainerLow: isNeutralDark
          ? surface
          : _mix(
              pureBlack
                  ? const Color(0xFF060606)
                  : baseScheme.surfaceContainerLow,
              seedRaised,
              pureBlack ? 0.0 : 0.22,
            ),
      surfaceContainerLowest: background,
    );
    if (isNeutralDark) {
      colorScheme = colorScheme.copyWith(
        primary: seedColor,
        onPrimary: _foregroundFor(seedColor),
      );
    }

    final darkDivider = Colors.white.withValues(alpha: 0.08);
    final cardBorderColor = isNeutralDark
        ? Colors.white.withValues(alpha: 0.08)
        : _mix(seedColor, Colors.white, 0.35).withValues(alpha: 0.13);

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      fontFamily: 'Inter',
      textTheme: _appleTextTheme,
      splashFactory: NoSplash.splashFactory,
      splashColor: Colors.transparent,
      highlightColor: colorScheme.onSurface.withValues(alpha: 0.07),
      extensions: [
        AppTypography.fromScheme(colorScheme),
        AppSurfaces.resolve(colorScheme, amoled: pureBlack),
      ],
      scaffoldBackgroundColor: background,
      pageTransitionsTheme: _appPageTransitionsTheme,
      appBarTheme: AppBarTheme(
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: surface.withValues(alpha: 0.86),
        foregroundColor: colorScheme.onSurface,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: colorScheme.onSurface,
        ),
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        shape: RoundedSuperellipseBorder(
          borderRadius: AppRadius.cardAltBorder,
          side: BorderSide(color: cardBorderColor, width: 0.5),
        ),
        margin: EdgeInsets.zero,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(AppRadius.sheet),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: colorScheme.primary,
          foregroundColor: colorScheme.onPrimary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.control),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: colorScheme.primary,
          side: BorderSide(color: colorScheme.primary),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.control),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: colorScheme.primary,
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colorScheme.surfaceContainerHigh,
        border: OutlineInputBorder(
          borderRadius: AppRadius.inputBorder,
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: AppRadius.inputBorder,
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: AppRadius.inputBorder,
          borderSide: BorderSide(color: colorScheme.primary, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
      ),
      popupMenuTheme: _popupMenuTheme(colorScheme),
      segmentedButtonTheme: _segmentedButtonTheme(colorScheme),
      bottomSheetTheme: BottomSheetThemeData(
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadius.sheet),
          ),
        ),
        backgroundColor: surface,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface.withValues(alpha: 0.88),
        indicatorColor: colorScheme.primary.withValues(alpha: 0.28),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: colorScheme.primary,
            );
          }
          return TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant);
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return IconThemeData(color: colorScheme.primary);
          }
          return IconThemeData(color: colorScheme.onSurfaceVariant);
        }),
      ),
      dividerTheme: DividerThemeData(
        color: darkDivider,
        thickness: 0.5,
        space: 1,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: colorScheme.surfaceContainerHigh,
        selectedColor: colorScheme.primary.withValues(alpha: 0.2),
        labelStyle: TextStyle(fontSize: 13, color: colorScheme.onSurface),
        shape: RoundedRectangleBorder(borderRadius: AppRadius.chipBorder),
        side: BorderSide.none,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: colorScheme.primary,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: colorScheme.inverseSurface,
        contentTextStyle: TextStyle(color: colorScheme.onInverseSurface),
        shape: RoundedSuperellipseBorder(borderRadius: AppRadius.cardBorder),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

/// Android 页面从屏幕边缘横向滑入，参与次级动画的下层页面反向移动 15%。
/// 页面保持实时绘制，由位移表达层级，返回时使用镜像曲线减速归位。
///
/// 各平台必须列全：builders 未命中的平台会退回 ZoomPageTransitionsBuilder，
/// 只写 Android 会让 iOS/macOS 丢掉 Cupertino 侧滑。
const PageTransitionsTheme _appPageTransitionsTheme = PageTransitionsTheme(
  builders: <TargetPlatform, PageTransitionsBuilder>{
    TargetPlatform.android: _HorizontalPageTransitionsBuilder(),
    TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
    TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
    TargetPlatform.windows: ZoomPageTransitionsBuilder(),
    TargetPlatform.linux: ZoomPageTransitionsBuilder(),
  },
);

class _HorizontalPageTransitionsBuilder extends PageTransitionsBuilder {
  const _HorizontalPageTransitionsBuilder();

  @override
  Duration get transitionDuration => AppMotion.page;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // 系统「移除动画」：直接换页。
    if (AppMotion.reduced(context)) return child;
    return _HorizontalPageTransition(
      animation: animation,
      secondaryAnimation: secondaryAnimation,
      child: child,
    );
  }
}

class _HorizontalPageTransition extends StatefulWidget {
  const _HorizontalPageTransition({
    required this.animation,
    required this.secondaryAnimation,
    required this.child,
  });

  final Animation<double> animation;
  final Animation<double> secondaryAnimation;
  final Widget child;

  @override
  State<_HorizontalPageTransition> createState() =>
      _HorizontalPageTransitionState();
}

class _HorizontalPageTransitionState extends State<_HorizontalPageTransition> {
  /// 本页是否已向 [PageTransitionActivity] 登记了一次转场。
  bool _holdingActivity = false;

  void _updateActivity(AnimationStatus _) {
    final animating =
        widget.animation.isAnimating || widget.secondaryAnimation.isAnimating;
    // 向全局登记转场起止，供壁纸和延后的页面刷新使用。
    if (animating && !_holdingActivity) {
      _holdingActivity = true;
      PageTransitionActivity.instance.acquire();
    } else if (!animating && _holdingActivity) {
      _holdingActivity = false;
      PageTransitionActivity.instance.release();
    }
  }

  // CurvedAnimation 会在 parent 上登记状态监听，必须持有并 dispose；在 build
  // 里每次新建会一直累积。
  late CurvedAnimation _slideIn;
  late CurvedAnimation _slideOut;

  void _createCurves() {
    _slideIn = CurvedAnimation(
      parent: widget.animation,
      curve: AppMotion.emphasized,
      reverseCurve: AppMotion.emphasizedReverse,
    );
    _slideOut = CurvedAnimation(
      parent: widget.secondaryAnimation,
      curve: AppMotion.emphasized,
      reverseCurve: AppMotion.emphasizedReverse,
    );
  }

  void _disposeCurves() {
    _slideIn.dispose();
    _slideOut.dispose();
  }

  @override
  void initState() {
    super.initState();
    _createCurves();
    widget.animation.addStatusListener(_updateActivity);
    widget.secondaryAnimation.addStatusListener(_updateActivity);
    _updateActivity(widget.animation.status);
  }

  @override
  void didUpdateWidget(covariant _HorizontalPageTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation == widget.animation &&
        oldWidget.secondaryAnimation == widget.secondaryAnimation) {
      return;
    }
    oldWidget.animation.removeStatusListener(_updateActivity);
    oldWidget.secondaryAnimation.removeStatusListener(_updateActivity);
    _disposeCurves();
    _createCurves();
    widget.animation.addStatusListener(_updateActivity);
    widget.secondaryAnimation.addStatusListener(_updateActivity);
    _updateActivity(widget.animation.status);
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_updateActivity);
    widget.secondaryAnimation.removeStatusListener(_updateActivity);
    if (_holdingActivity) {
      // 转场中途被销毁（pop 打断 push 等）也必须归还登记。
      _holdingActivity = false;
      PageTransitionActivity.instance.release();
    }
    _disposeCurves();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // RTL 语言下位移取反，保持「新页从行文方向前方进入」。
    final double direction = Directionality.of(context) == TextDirection.rtl
        ? -1
        : 1;
    return SlideTransition(
      position: Tween<Offset>(
        begin: Offset(direction, 0),
        end: Offset.zero,
      ).animate(_slideIn),
      child: SlideTransition(
        position: Tween<Offset>(
          begin: Offset.zero,
          end: Offset(-0.15 * direction, 0),
        ).animate(_slideOut),
        child: widget.child,
      ),
    );
  }
}
