import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'app_design_tokens.dart';
import 'app_typography.dart';

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
    return PopupMenuThemeData(
      color: colorScheme.surfaceContainerHigh,
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

  static ThemeData light(
    Color seedColor, {
    bool filledButtonSoftStyle = false,
  }) {
    var colorScheme = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: Brightness.light,
    ).copyWith(primary: seedColor);

    // 中性种子：浅色模式走中性冷灰表面阶梯，阻断种子色粉调渗入
    // （背景 #FEF8F7、描边 #E2DDDC 之类的粉白观感），卡面纯白、
    // 描边中性灰，与深色模式的表面策略对偶。
    if (_isNeutralSeed(seedColor)) {
      colorScheme = colorScheme.copyWith(
        surface: const Color(0xFFF4F5F7),
        surfaceContainerLowest: Colors.white,
        surfaceContainerLow: const Color(0xFFF8F9FA),
        surfaceContainer: const Color(0xFFF2F3F6),
        surfaceContainerHigh: const Color(0xFFEAECF0),
        surfaceContainerHighest: const Color(0xFFE3E6EA),
        outlineVariant: const Color(0xFFE1E4E9),
      );
    }

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      fontFamily: 'Inter',
      textTheme: _appleTextTheme,
      extensions: [AppTypography.fromScheme(colorScheme)],
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
          backgroundColor: filledButtonSoftStyle
              ? colorScheme.primaryContainer
              : colorScheme.primary,
          foregroundColor: filledButtonSoftStyle
              ? colorScheme.onPrimaryContainer
              : colorScheme.onPrimary,
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: colorScheme.primary,
          side: BorderSide(color: colorScheme.primary),
          shape: const StadiumBorder(),
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

  static ThemeData dark(
    Color seedColor, {
    bool pureBlack = false,
    bool filledButtonSoftStyle = false,
  }) {
    final isNeutralDark = _isNeutralSeed(seedColor);
    final baseScheme = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: Brightness.dark,
    );
    final seedBase = _darkSeedTone(seedColor, 0.12);
    final seedRaised = _darkSeedTone(seedColor, 0.18);
    final seedHigh = _darkSeedTone(seedColor, 0.24);

    final darkBase = pureBlack
        ? const Color(0xFF000000)
        : isNeutralDark
        ? const Color(0xFF101418)
        : baseScheme.surface;
    final darkSurf = pureBlack
        ? const Color(0xFF0A0A0A)
        : isNeutralDark
        ? const Color(0xFF171C20)
        : baseScheme.surfaceContainerLow;
    final darkSurfHigh = pureBlack
        ? const Color(0xFF111111)
        : isNeutralDark
        ? const Color(0xFF242B30)
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
          ? const Color(0xFF12171B)
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
      extensions: [AppTypography.fromScheme(colorScheme)],
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
          backgroundColor: filledButtonSoftStyle
              ? colorScheme.primaryContainer
              : colorScheme.primary,
          foregroundColor: filledButtonSoftStyle
              ? colorScheme.onPrimaryContainer
              : colorScheme.onPrimary,
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: colorScheme.primary,
          side: BorderSide(color: colorScheme.primary),
          shape: const StadiumBorder(),
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

/// 应用统一的页面转场：新页从右侧滑入 12% 并淡入，旧页向左视差退出
/// （淡出至 0.55、微缩到 0.98）。
///
/// Flutter 3.29 起 Android 的默认转场改为 PredictiveBackPageTransitionsBuilder，
/// 非手势导航（点击按钮 push）时退化成 FadeForwardsPageTransitionsBuilder
/// （predictive_back_page_transitions_builder.dart:95）——新页仅位移 30px、
/// 旧页纯淡出且不位移，在深色背景下几乎等同于瞬切。这里显式覆盖，换回
/// 明确的方向感，与 app_shell_page 底部 tab 切换的语言保持一致。
///
/// 位移量刻意比系统默认更足：深色主题下各页底色几乎无差，交叉淡入本身
/// 读不出「过渡」，只有新旧两页反向位移形成的相对运动才是可感知的信号。
///
/// 各平台必须列全：builders 未命中的平台会退回 ZoomPageTransitionsBuilder，
/// 只写 Android 会让 iOS/macOS 丢掉 Cupertino 侧滑。
const PageTransitionsTheme _appPageTransitionsTheme = PageTransitionsTheme(
  builders: <TargetPlatform, PageTransitionsBuilder>{
    TargetPlatform.android: _SlideFadePageTransitionsBuilder(),
    TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
    TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
    TargetPlatform.windows: ZoomPageTransitionsBuilder(),
    TargetPlatform.linux: ZoomPageTransitionsBuilder(),
  },
);

class _SlideFadePageTransitionsBuilder extends PageTransitionsBuilder {
  const _SlideFadePageTransitionsBuilder();

  static const Duration _duration = Duration(milliseconds: 220);

  @override
  Duration get transitionDuration => _duration;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // 系统「移除动画」：直接换页，不做位移 / 淡入 / 缩放。
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return child;
    return _SlideFadePageTransition(
      animation: animation,
      secondaryAnimation: secondaryAnimation,
      child: child,
    );
  }
}

class _SlideFadePageTransition extends StatefulWidget {
  const _SlideFadePageTransition({
    required this.animation,
    required this.secondaryAnimation,
    required this.child,
  });

  final Animation<double> animation;
  final Animation<double> secondaryAnimation;
  final Widget child;

  @override
  State<_SlideFadePageTransition> createState() =>
      _SlideFadePageTransitionState();
}

class _SlideFadePageTransitionState extends State<_SlideFadePageTransition> {
  /// 入场（push）曲线：起步快、收尾慢。
  static const Curve _curve = Curves.easeOutCubic;

  /// 出场（pop）曲线：返回时转场是「倒放」的，`CurvedAnimation` 在
  /// `reverseCurve` 为空时会直接复用正向曲线（SDK  animations.dart:377），
  /// 于是 easeOutCubic 被倒放成 easeInCubic——起步慢吞吞、末尾突然冲刺，
  /// 观感就是「先慢后快」。这里显式给反向指定镜像曲线，让返回同样是先快后慢。
  static const Curve _reverseCurve = Curves.easeInCubic;

  /// 新页的起点位移（相对自身宽度）。
  static const double _enterOffset = 0.12;

  /// 旧页退出的终点位移（反向视差，与新页位移共同构成相对运动）。
  static const double _exitSlideOffset = -0.04;

  /// 旧页退出的终点缩放。
  static const double _exitScale = 0.98;

  /// 旧页退出的终点不透明度。
  ///
  /// 刻意不淡到 0：新页滑入的过程中会短暂露出下方页面，旧页若完全消失
  /// 就会透出窗口背景（深色主题下尤其明显）。留 0.55 保证底层始终有内容。
  static const double _exitOpacity = 0.55;

  /// 转场期间把页面内容栅格化成快照后再做淡入/位移/缩放。
  ///
  /// 页面栈底普遍挂着玻璃背景层（BackdropFilter），逐帧变换会迫使模糊链
  /// 每帧重栅格化，模拟器与低端机上整个转场画不出几帧，观感等同于瞬切。快照化后整页内容只栅格化一次，与 SDK 默认
  /// ZoomPageTransitionsBuilder 的 SnapshotWidget 策略一致（代价是转场
  /// 期间页面内的小动画会短暂定格；含平台视图的页面在 permissive 模式下
  /// 自动跳过快照、正常渲染）。
  final SnapshotController _snapshotController = SnapshotController();

  void _updateSnapshotting(AnimationStatus _) {
    _snapshotController.allowSnapshotting =
        !kIsWeb &&
        (widget.animation.isAnimating || widget.secondaryAnimation.isAnimating);
  }

  @override
  void initState() {
    super.initState();
    widget.animation.addStatusListener(_updateSnapshotting);
    widget.secondaryAnimation.addStatusListener(_updateSnapshotting);
    _updateSnapshotting(widget.animation.status);
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_updateSnapshotting);
    widget.secondaryAnimation.removeStatusListener(_updateSnapshotting);
    _snapshotController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // RTL 语言下位移取反，保持「新页从行文方向前方进入」。
    final double direction = Directionality.of(context) == TextDirection.rtl
        ? -1
        : 1;
    final entering = CurvedAnimation(
      parent: widget.animation,
      curve: _curve,
      reverseCurve: _reverseCurve,
    );
    final leaving = CurvedAnimation(
      parent: widget.secondaryAnimation,
      curve: _curve,
      reverseCurve: _reverseCurve,
    );
    return FadeTransition(
      opacity: entering,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: Offset(_enterOffset * direction, 0),
          end: Offset.zero,
        ).animate(entering),
        child: FadeTransition(
          opacity: Tween<double>(begin: 1, end: _exitOpacity).animate(leaving),
          child: ScaleTransition(
            scale: Tween<double>(begin: 1, end: _exitScale).animate(leaving),
            child: SlideTransition(
              position: Tween<Offset>(
                begin: Offset.zero,
                end: Offset(_exitSlideOffset * direction, 0),
              ).animate(leaving),
              child: SnapshotWidget(
                controller: _snapshotController,
                mode: SnapshotMode.permissive,
                autoresize: true,
                child: widget.child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
