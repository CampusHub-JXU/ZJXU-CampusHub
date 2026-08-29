import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_theme_controller.dart';
import '../../app/theme.dart';
import '../../core/auth/unified_auth.dart';
import '../../core/auth/zhengfang_auth.dart';
import '../../core/theme/app_design_tokens.dart';
import '../../shared/widgets/app_card.dart';
import '../../shared/widgets/app_icon_badge.dart';
import '../../shared/widgets/login_shell.dart';
import '../schedule/schedule_service.dart';
import '../../shared/widgets/app_app_bar.dart';

class MyPage extends StatefulWidget {
  const MyPage({super.key});

  @override
  State<MyPage> createState() => _MyPageState();
}

class _MyPageState extends State<MyPage> {
  bool _campusLoggedIn = false;
  bool _academicLoggedIn = false;
  bool _campusStatusChecking = false;
  bool _academicStatusChecking = false;
  bool _hasScheduleCache = false;
  DateTime? _scheduleUpdatedAt;
  int _statusRefreshVersion = 0;

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
      _hasScheduleCache = snapshot?.hasData ?? false;
      _scheduleUpdatedAt = snapshot?.lastUpdatedAt;
    });

    final campusValidationFuture = campusLoggedIn
        ? UnifiedAuthService.instance.validateSession()
        : Future<bool?>.value(false);
    final academicValidationFuture = academicLoggedIn
        ? ZhengfangAuth.instance.validateSession()
        : Future<bool?>.value(false);

    final campusValidation = await campusValidationFuture;
    final academicValidation = await academicValidationFuture;

    if (!mounted || refreshVersion != _statusRefreshVersion) return;

    setState(() {
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
    return _campusLoggedIn ? '已登录' : '未登录';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final accountIconColor = AppThemeController.instance.resolveIconColor(
      context,
      cs.primary,
    );
    final academicIconColor = AppThemeController.instance.resolveIconColor(
      context,
      cs.secondary,
    );
    return Scaffold(
      // 无标题细顶栏：标题语义由正文 large title「我的」承担，
      // 与主页/功能的单滚动观感保持一致。
      appBar: AppAppBar(toolbarHeight: 44),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
        children: [
          // Apple large-title 头部：无卡容器，纯文字块与卡片左缘对齐。
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '我的',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  height: 1.2,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '管理统一认证（含一卡通）、教务登录状态',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.25,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          AppCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _GroupRowTile(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(AppRadius.card),
                  ),
                  icon: Icons.account_balance_wallet_outlined,
                  iconColor: accountIconColor,
                  title: '统一认证（含一卡通）',
                  subtitle: _campusSubtitle(),
                  status: _buildStatusIndicator(
                    checking: _campusStatusChecking,
                    loggedIn: _campusLoggedIn,
                    label: _campusLoggedIn ? '已登录' : '未登录',
                    statusKey: const Key('my_campus_status'),
                  ),
                  onTap: () {
                    if (_campusLoggedIn) {
                      unawaited(_reloginCampus());
                    } else {
                      unawaited(_openCampusCardAction());
                    }
                  },
                ),
                _buildHairlineDivider(context),
                _GroupRowTile(
                  borderRadius: const BorderRadius.vertical(
                    bottom: Radius.circular(AppRadius.card),
                  ),
                  icon: Icons.school_outlined,
                  iconColor: academicIconColor,
                  title: '教务系统',
                  subtitle: _academicSubtitle(),
                  status: _buildStatusIndicator(
                    checking: _academicStatusChecking,
                    loggedIn: _academicLoggedIn,
                    label: _academicLoggedIn ? '已登录' : '未登录',
                    statusKey: const Key('my_academic_status'),
                  ),
                  trailing: _academicLoggedIn
                      ? _buildAcademicEnterButton(context)
                      : null,
                  onTap: () => unawaited(_loginAcademic()),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          AppCard(
            padding: EdgeInsets.zero,
            child: _GroupRowTile(
              borderRadius: BorderRadius.circular(AppRadius.card),
              icon: Icons.settings_outlined,
              iconColor: cs.primary,
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
    );
  }

  /// 组内行间发丝分隔线：左缩进对齐文本起始列（行 padding 16 + 徽标 + 间距 10）。
  Widget _buildHairlineDivider(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: 1,
      margin: const EdgeInsets.only(left: 16 + AppBadgeSize.smallBox + 10),
      color: cs.outlineVariant.withValues(alpha: 0.35),
    );
  }

  /// 行尾状态指示：校验中为小号加载圈，稳定后是「圆点 + 文字」。
  ///
  /// 已登录用品牌绿点，未登录退回中性灰，与首页状态语义一致。
  Widget _buildStatusIndicator({
    required bool checking,
    required bool loggedIn,
    required String label,
    required Key statusKey,
  }) {
    final cs = Theme.of(context).colorScheme;
    if (checking) {
      return const SizedBox.square(
        dimension: 14,
        child: CircularProgressIndicator(strokeWidth: 2.0),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: loggedIn ? AppColors.success : cs.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          key: statusKey,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: cs.onSurfaceVariant,
          ),
        ),
      ],
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
    this.status,
    this.trailing,
  });

  /// 涟漪裁剪形状：组内首行只圆上角、末行只圆下角，单行组取整卡圆角。
  final BorderRadius borderRadius;
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Widget? status;
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
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              AppIconBadge(
                icon: icon,
                accentColor: iconColor,
                size: AppIconBadgeSize.small,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        height: 1.2,
                        color: cs.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
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
              if (status != null) ...[const SizedBox(width: 8), status!],
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
