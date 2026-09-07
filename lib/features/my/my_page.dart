import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/theme/app_theme_controller.dart';
import '../../core/auth/unified_auth.dart';
import '../../core/auth/zhengfang_auth.dart';
import '../../core/theme/app_design_tokens.dart';
import '../../shared/widgets/app_card.dart';
import '../../shared/widgets/app_icon_badge.dart';
import '../../shared/widgets/login_shell.dart';
import '../schedule/schedule_service.dart';

/// 行级视觉 token（自首页功能瓦片 / 「今天」列表行提取，全 App 行规格同档）：
/// 徽标与文字列之间的固定间距，发丝分隔线缩进公式也复用它。
const double _rowIconTextGap = 10;

/// 组行标题规格：15/w600/h1.2（Apple semibold 行标题档），
/// 与 _GroupRowTile 及年级行的手写样式收敛为单一来源。
TextStyle _rowTitleStyle(ColorScheme cs) => TextStyle(
  fontSize: 15,
  fontWeight: FontWeight.w600,
  height: 1.2,
  color: cs.onSurface,
);

class MyPage extends StatefulWidget {
  const MyPage({super.key});

  @override
  State<MyPage> createState() => _MyPageState();
}

class _MyPageState extends State<MyPage> {
  bool _campusLoggedIn = false;
  bool _academicLoggedIn = false;

  /// 测活请求本身失败（网络异常）：无法下结论，不能沿用「已登录」。
  /// 之前这里回退到缓存的登录态，导致显示已登录但实际会话已失效。
  bool _campusStatusUnknown = false;
  bool _academicStatusUnknown = false;
  bool _campusStatusChecking = false;
  bool _academicStatusChecking = false;
  bool _hasScheduleCache = false;
  DateTime? _scheduleUpdatedAt;
  int _statusRefreshVersion = 0;

  /// 底部签名行版本号，仅取一次。
  late final Future<PackageInfo> _packageInfoFuture =
      PackageInfo.fromPlatform();

  @override
  void initState() {
    super.initState();
    UnifiedAuthService.instance.addListener(_onAuthChanged);
    ZhengfangAuth.instance.addListener(_onAuthChanged);
    _refreshStatus();
  }

  @override
  void dispose() {
    UnifiedAuthService.instance.removeListener(_onAuthChanged);
    ZhengfangAuth.instance.removeListener(_onAuthChanged);
    super.dispose();
  }

  void _onAuthChanged() {
    if (!mounted) return;
    unawaited(_refreshStatus());
  }

  Future<void> _refreshStatus() async {
    final term = ScheduleService.instance.getCurrentTermContext();
    final snapshot = ScheduleService.instance.preferredSnapshot(
      termContext: term,
    );
    final refreshVersion = ++_statusRefreshVersion;
    final campusLoggedIn = UnifiedAuthService.instance.isLoggedIn;
    final academicLoggedIn = ZhengfangAuth.instance.isLoggedIn;

    setState(() {
      _campusLoggedIn = campusLoggedIn;
      _academicLoggedIn = academicLoggedIn;
      _campusStatusChecking = campusLoggedIn;
      _academicStatusChecking = academicLoggedIn;
      _campusStatusUnknown = false;
      _academicStatusUnknown = false;
      _hasScheduleCache = snapshot?.hasData ?? false;
      _scheduleUpdatedAt = snapshot?.lastUpdatedAt;
    });

    final campusValidationFuture = _validateSafely(
      campusLoggedIn
          ? UnifiedAuthService.instance.validateSession()
          : Future<bool?>.value(false),
    );
    final academicValidationFuture = _validateSafely(
      academicLoggedIn
          ? ZhengfangAuth.instance.validateSession()
          : Future<bool?>.value(false),
    );

    final campusValidation = await campusValidationFuture;
    final academicValidation = await academicValidationFuture;

    if (!mounted || refreshVersion != _statusRefreshVersion) return;

    setState(() {
      // null = 测活请求网络异常，登录态未知；不再回退到缓存的「已登录」。
      _campusStatusUnknown = campusValidation == null;
      _academicStatusUnknown = academicValidation == null;
      _campusLoggedIn =
          campusValidation ?? UnifiedAuthService.instance.isLoggedIn;
      _academicLoggedIn =
          academicValidation ?? ZhengfangAuth.instance.isLoggedIn;
      _campusStatusChecking = false;
      _academicStatusChecking = false;
      _hasScheduleCache = snapshot?.hasData ?? false;
      _scheduleUpdatedAt = snapshot?.lastUpdatedAt;
    });
  }

  /// 测活兜底：validateSession 理论上内部吞网络异常返回 null，但部分路径
  /// （如 DioClient 未初始化）仍可能抛出；这里统一归入 null = 状态未知，
  /// 避免 _refreshStatus 中断导致 UI 永久停留在「正在校验」。
  Future<bool?> _validateSafely(Future<bool?> validation) async {
    try {
      return await validation;
    } catch (_) {
      return null;
    }
  }

  Future<void> _openCampusCardAction() async {
    if (_campusLoggedIn) {
      await context.pushNamed('campus-card');
      if (!mounted) return;
      await _refreshStatus();
      return;
    }
    await showUnifiedAuthLoginModal(context);
    if (!mounted) return;
    await _refreshStatus();
  }

  Future<void> _loginAcademic() async {
    await showAcademicSystemLoginModal(context);
    if (!mounted) return;
    await _refreshStatus();
  }

  Future<void> _openAcademicH5() async {
    final h5Url = ZhengfangAuth.instance.buildPortalUrl(
      '/xtgl/index_initMenu.html',
      queryParameters: {
        'jsdm': 'xs',
        '_t': DateTime.now().millisecondsSinceEpoch,
      },
    );

    if (_academicLoggedIn) {
      await ZhengfangAuth.instance.syncCookiesToWebView();
    }
    if (!mounted) return;

    await context.pushNamed(
      'external-webview',
      extra: {'title': '教务系统', 'url': h5Url, 'enableLoginQuickFill': true},
    );
    if (!mounted) return;
    await _refreshStatus();
  }

  Future<void> _reloginCampus() async {
    await showUnifiedAuthLoginModal(context);
    if (!mounted) return;
    await _refreshStatus();
  }

  String _formatTime(DateTime? value) {
    if (value == null) return '未缓存';
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');
    final hour = value.hour.toString().padLeft(2, '0');
    final minute = value.minute.toString().padLeft(2, '0');
    return '$month-$day $hour:$minute';
  }

  String _academicSubtitle() {
    if (_academicStatusChecking) {
      if (_hasScheduleCache) {
        return '正在校验教务状态 · 课表缓存 ${_formatTime(_scheduleUpdatedAt)}';
      }
      return '正在校验教务状态 · 课表未缓存';
    }
    if (_academicStatusUnknown) {
      return '登录状态未知 · 点按重新校验';
    }
    if (_academicLoggedIn) {
      if (_hasScheduleCache) {
        return '已登录 · 课表更新 ${_formatTime(_scheduleUpdatedAt)}';
      }
      return '已登录 · 课表未缓存';
    }
    if (_hasScheduleCache) {
      return '未登录 · 课表缓存 ${_formatTime(_scheduleUpdatedAt)}';
    }
    return '未登录 · 课表未缓存';
  }

  String _campusSubtitle() {
    if (_campusStatusChecking) {
      return '正在校验统一认证状态';
    }
    if (_campusStatusUnknown) {
      return '登录状态未知 · 点按重新校验';
    }
    return _campusLoggedIn ? '已登录' : '未登录';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final primaryIconColor = AppThemeController.instance.resolveIconColor(
      context,
      cs.primary,
    );
    return Scaffold(
      // 不再挂空顶栏：标题语义由正文 large title「我的」承担，
      // 状态栏留白交给 [SafeArea] 处理。
      body: SafeArea(
        bottom: false,
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            // 内容不满一屏时撑到视口高度，让 [Spacer] 把底部签名锚到
            // 页面底缘（大字号/内容超屏时自然回退为普通滚动）。
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: IntrinsicHeight(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.pageMargin,
                        AppSpacing.xl,
                        AppSpacing.pageMargin,
                        0,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Apple large-title 头部：无卡容器，纯文字块与卡片
                          // 左缘对齐；直接复用全局 Apple 字阶展示档
                          // headlineMedium（28/w700 + 收紧字距 -0.4），与
                          // 首页 Hero 大字同一展示语言，建立一致的排版重心。
                          Text(
                            '我的',
                            style: Theme.of(context).textTheme.headlineMedium!
                                .copyWith(color: cs.onSurface),
                          ),
                          // 头部到卡片群的呼吸空间，与首页环境行 → Hero
                          // 的大留白同一意图（按本页体量收窄为 24）。
                          const SizedBox(height: AppSpacing.xl),
                          AppCard(
                            padding: EdgeInsets.zero,
                            child: Column(
                              children: [
                                _GroupRowTile(
                                  borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(AppRadius.card),
                                  ),
                                  icon: Icons.account_balance_wallet_outlined,
                                  iconColor: primaryIconColor,
                                  title: '统一认证（含一卡通）',
                                  subtitle: _campusSubtitle(),
                                  subtitleKey: const Key('my_campus_status'),
                                  onTap: () {
                                    if (_campusStatusUnknown) {
                                      // 状态未知时点按 = 重新测活，而不是直接弹登录框。
                                      unawaited(_refreshStatus());
                                    } else if (_campusLoggedIn) {
                                      unawaited(_reloginCampus());
                                    } else {
                                      unawaited(_openCampusCardAction());
                                    }
                                  },
                                ),
                                _buildHairlineDivider(context),
                                _GroupRowTile(
                                  borderRadius: BorderRadius.vertical(
                                    bottom: Radius.circular(AppRadius.card),
                                  ),
                                  icon: Icons.school_outlined,
                                  iconColor: primaryIconColor,
                                  title: '教务系统',
                                  subtitle: _academicSubtitle(),
                                  subtitleKey: const Key('my_academic_status'),
                                  trailing: _academicLoggedIn
                                      ? _buildAcademicEnterButton(context)
                                      : null,
                                  onTap: () => unawaited(
                                    _academicStatusUnknown
                                        ? _refreshStatus()
                                        : _loginAcademic(),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: AppSpacing.lg),
                          AppCard(
                            padding: EdgeInsets.zero,
                            child: _GroupRowTile(
                              borderRadius: BorderRadius.circular(
                                AppRadius.card,
                              ),
                              icon: Icons.settings_outlined,
                              iconColor: primaryIconColor,
                              title: '设置',
                              subtitle: '主题、学期、网络与调试选项',
                              onTap: () async {
                                await context.pushNamed('settings');
                                if (!mounted) return;
                                await _refreshStatus();
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Spacer(),
                    _buildFooter(context),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 底部签名行：锚在视口底缘（dock 上方），让首屏留白成为刻意构图；
  /// 版本号规格与设置页「关于」一致。
  Widget _buildFooter(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.pageMargin,
        AppSpacing.xl,
        AppSpacing.pageMargin,
        // SafeArea(bottom: false) 之下自行叠加底部安全区 + dock 高度。
        MediaQuery.paddingOf(context).bottom + 110,
      ),
      child: Center(
        child: FutureBuilder<PackageInfo>(
          future: _packageInfoFuture,
          builder: (context, snapshot) {
            final version = snapshot.hasData
                ? 'v${snapshot.data!.version}+${snapshot.data!.buildNumber}'
                : '';
            return Text(
              '嘉兴大学 $version',
              style: textTheme.bodySmall!.copyWith(color: cs.onSurfaceVariant),
            );
          },
        ),
      ),
    );
  }

  /// 组内行间发丝分隔线：左缩进对齐文本起始列（行 padding 16 + 徽标 + 间距 10）。
  Widget _buildHairlineDivider(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: 1,
      margin: const EdgeInsets.only(
        left: AppSpacing.lg + AppBadgeSize.smallBox + _rowIconTextGap,
      ),
      color: cs.outlineVariant.withValues(alpha: 0.35),
    );
  }

  /// 「进入」紧凑文字按钮：直达教务系统 H5 门户（不丢可达性）。
  Widget _buildAcademicEnterButton(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return TextButton(
      onPressed: () => unawaited(_openAcademicH5()),
      style: TextButton.styleFrom(
        foregroundColor: cs.primary,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      child: const Text('进入'),
    );
  }
}

/// 分组卡内的 iOS Settings 式横排行：徽标 + 文字列 + 行尾状态与箭头。
///
/// 文字规格与首页功能瓦片一致（标题 15/w600、副标题 13），内容垂直居中；
/// 涟漪经 [RoundedSuperellipseBorder] 裁剪，组内首末行只圆外侧角，
/// 让按压高光贴住卡面轮廓。
class _GroupRowTile extends StatelessWidget {
  const _GroupRowTile({
    required this.borderRadius,
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.subtitleKey,
    this.trailing,
  });

  /// 涟漪裁剪形状：组内首行只圆上角、末行只圆下角，单行组取整卡圆角。
  final BorderRadius borderRadius;
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Key? subtitleKey;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        customBorder: RoundedSuperellipseBorder(borderRadius: borderRadius),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.lg,
          ),
          child: Row(
            children: [
              AppIconBadge(
                icon: icon,
                accentColor: iconColor,
                size: AppIconBadgeSize.small,
              ),
              const SizedBox(width: _rowIconTextGap),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _rowTitleStyle(cs),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      key: subtitleKey,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.25,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 4), trailing!],
              const SizedBox(width: 2),
              Icon(Icons.chevron_right, size: 20, color: cs.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
