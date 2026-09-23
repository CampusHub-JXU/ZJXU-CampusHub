import 'package:flutter/material.dart';

import '../../core/auth/unified_auth.dart';
import '../../core/theme/app_design_tokens.dart';
import 'app_surface_style.dart';
import 'login_widget.dart';
import 'unified_auth_login_widget.dart';

// 输入框与登录按钮与全局内容面同档圆角（16，AppRadius.input）。
final BorderRadius _kInputRadius = AppRadius.inputBorder;
const double _kHorizontalMargin = AppSpacing.pageMargin;

// 表单卡走「悬浮面」档圆角（28，AppRadius.floating），与弹层同档。
const double _kFormCardRadius = AppRadius.floating;

class LoginShell extends StatelessWidget {
  const LoginShell({
    super.key,
    required this.title,
    required this.description,
    required this.child,
    this.badgeText,
    this.onClose,
    this.topSafeArea = true,
  });

  final String title;
  final String description;
  final Widget child;
  final String? badgeText;
  final VoidCallback? onClose;
  final bool topSafeArea;

  /// 徽标左侧的小图标：按认证域区分（教务 / 统一认证），强化两套凭据的
  /// 视觉分离；未识别的文案回退为通用锁形。
  IconData? get _badgeIcon {
    final text = badgeText;
    if (text == null) return null;
    if (text.contains('教务')) return Icons.school_outlined;
    if (text.contains('统一认证')) return Icons.shield_outlined;
    return Icons.lock_outline;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    final keyboardVisible = keyboardInset > 0;
    final isDark = theme.brightness == Brightness.dark;
    final pageBackground = theme.scaffoldBackgroundColor;
    // 表单卡面与 AppCard / AppTileSurface 共用平色配方：
    // 深色 surfaceContainerLow + 单层落底柔影，浅色 surfaceContainerLowest
    // 零投影（不做描边，分层交给色调对比与柔影）。
    final formSurface = appSurfaceColor(
      cs: colorScheme,
      isDark: isDark,
      glassEnabled: false,
      tintAlpha: 1,
    );
    final formShadow = appSurfaceShadows(isDark: isDark);
    final inputFill = colorScheme.surfaceContainerHighest;
    final inputBorder = BorderSide(color: colorScheme.outlineVariant);
    final focusBorder = colorScheme.primary;

    return Material(
      color: pageBackground,
      child: SafeArea(
        top: topSafeArea,
        bottom: false,
        child: Theme(
          data: theme.copyWith(
            inputDecorationTheme: InputDecorationTheme(
              filled: true,
              fillColor: inputFill,
              border: OutlineInputBorder(
                borderRadius: _kInputRadius,
                borderSide: inputBorder,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: _kInputRadius,
                borderSide: inputBorder,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: _kInputRadius,
                borderSide: BorderSide(color: focusBorder, width: 1.6),
              ),
              errorBorder: OutlineInputBorder(
                borderRadius: _kInputRadius,
                borderSide: BorderSide(color: colorScheme.error),
              ),
              focusedErrorBorder: OutlineInputBorder(
                borderRadius: _kInputRadius,
                borderSide: BorderSide(color: colorScheme.error, width: 1.6),
              ),
              prefixIconColor: colorScheme.onSurfaceVariant,
              prefixIconConstraints: const BoxConstraints(
                minWidth: 54,
                minHeight: 54,
              ),
              hintStyle: TextStyle(
                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.72),
                fontSize: 16,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 18,
                vertical: 17,
              ),
            ),
            filledButtonTheme: FilledButtonThemeData(
              style: FilledButton.styleFrom(
                backgroundColor: colorScheme.primary,
                foregroundColor: colorScheme.onPrimary,
                minimumSize: const Size(double.infinity, 54),
                padding: const EdgeInsets.symmetric(vertical: 15),
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: AppRadius.cardBorder,
                ),
                textStyle: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0,
                ),
              ),
            ),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final topPadding = keyboardVisible ? 16.0 : 24.0;
              final bottomPadding = 28.0 + keyboardInset + 12;
              final minHeight =
                  constraints.maxHeight - topPadding - bottomPadding;

              return SingleChildScrollView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: EdgeInsets.fromLTRB(
                  _kHorizontalMargin,
                  topPadding,
                  _kHorizontalMargin,
                  bottomPadding,
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: minHeight > 0 ? minHeight : 0,
                  ),
                  child: Align(
                    alignment: keyboardVisible
                        ? Alignment.topCenter
                        : Alignment.center,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: Container(
                        decoration: ShapeDecoration(
                          color: formSurface,
                          shape: const RoundedSuperellipseBorder(
                            borderRadius: BorderRadius.all(
                              Radius.circular(_kFormCardRadius),
                            ),
                          ),
                          shadows: formShadow,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(24, 22, 24, 20),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (badgeText != null || onClose != null)
                                Row(
                                  children: [
                                    if (badgeText != null)
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 7,
                                        ),
                                        decoration: BoxDecoration(
                                          color: colorScheme.primary.withValues(
                                            alpha: isDark ? 0.18 : 0.08,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            999,
                                          ),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              _badgeIcon,
                                              size: 14,
                                              color: colorScheme.primary,
                                            ),
                                            const SizedBox(width: 5),
                                            Text(
                                              badgeText!,
                                              style: theme.textTheme.labelLarge
                                                  ?.copyWith(
                                                    color: colorScheme.primary,
                                                    fontWeight: FontWeight.w700,
                                                  ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    const Spacer(),
                                    if (onClose != null)
                                      IconButton(
                                        onPressed: onClose,
                                        tooltip: '关闭',
                                        style: IconButton.styleFrom(
                                          backgroundColor:
                                              colorScheme.surfaceContainerHigh,
                                          foregroundColor:
                                              colorScheme.onSurfaceVariant,
                                        ),
                                        icon: const Icon(Icons.close, size: 20),
                                      ),
                                  ],
                                ),
                              if (badgeText != null || onClose != null)
                                const SizedBox(height: 20),
                              Text(
                                title,
                                style: theme.textTheme.headlineSmall?.copyWith(
                                  color: colorScheme.onSurface,
                                  fontWeight: FontWeight.w800,
                                  height: 1.12,
                                  letterSpacing: -0.3,
                                ),
                              ),
                              const SizedBox(height: AppSpacing.sm),
                              Text(
                                description,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                  height: 1.5,
                                ),
                              ),
                              const SizedBox(height: 24),
                              child,
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

Future<bool> showUnifiedAuthLoginModal(
  BuildContext context, {
  String title = '登录一卡通',
  String description = '登录后可进入一卡通、服务大厅等服务',
  String serviceUrl = UnifiedAuthService.defaultServiceUrl,
  LoginSessionPreflight? sessionPreflight,
  bool barrierDismissible = true,
}) async {
  final result = await showGeneralDialog<bool>(
    context: context,
    useRootNavigator: true,
    barrierDismissible: barrierDismissible,
    barrierLabel: '关闭统一认证登录',
    barrierColor: Theme.of(context).colorScheme.scrim.withValues(alpha: 0.4),
    transitionDuration: const Duration(milliseconds: 240),
    pageBuilder: (dialogContext, animation0, secondaryAnimation0) {
      return LoginShell(
        title: title,
        description: description,
        badgeText: '统一认证',
        onClose: barrierDismissible
            ? () => Navigator.of(dialogContext, rootNavigator: true).pop(false)
            : null,
        child: UnifiedAuthLoginWidget(
          serviceUrl: serviceUrl,
          title: title,
          description: description,
          sessionPreflight: sessionPreflight,
          showHeader: false,
          padding: EdgeInsets.zero,
          onLoginSuccess: () =>
              Navigator.of(dialogContext, rootNavigator: true).pop(true),
        ),
      );
    },
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween(
            begin: const Offset(0, 0.04),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    },
  );
  return result == true;
}

Future<bool> showAcademicSystemLoginModal(
  BuildContext context, {
  bool barrierDismissible = true,
}) async {
  final result = await showGeneralDialog<bool>(
    context: context,
    useRootNavigator: true,
    barrierDismissible: barrierDismissible,
    barrierLabel: '关闭教务系统登录',
    barrierColor: Theme.of(context).colorScheme.scrim.withValues(alpha: 0.4),
    transitionDuration: const Duration(milliseconds: 240),
    pageBuilder: (dialogContext, animation0, secondaryAnimation0) {
      return LoginShell(
        title: '登录教务系统',
        description: '登录后可查看课表、成绩与教务服务',
        badgeText: '教务系统',
        onClose: barrierDismissible
            ? () => Navigator.of(dialogContext, rootNavigator: true).pop(false)
            : null,
        child: LoginWidget(
          showHeader: false,
          padding: EdgeInsets.zero,
          onLoginSuccess: () =>
              Navigator.of(dialogContext, rootNavigator: true).pop(true),
        ),
      );
    },
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween(
            begin: const Offset(0, 0.04),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    },
  );
  return result == true;
}
