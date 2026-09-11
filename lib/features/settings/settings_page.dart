import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/cache/json_cache_store.dart';
import '../../core/logging/app_logger.dart';
import '../../core/notification/app_notification_service.dart';
import '../../core/profile/user_profile_controller.dart';
import '../../core/semester/current_term_resolver.dart';
import '../../core/semester/semester_calendar.dart';
import '../../core/semester/schedule_term_context.dart';
import '../../core/theme/app_design_tokens.dart';
import '../../core/update/update_checker.dart';
import '../../core/update/update_model.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_card.dart';
import '../../shared/widgets/app_dropdown.dart';
import '../../shared/widgets/app_icon_badge.dart';
import '../../shared/widgets/update_dialog.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  String _formatLogLevel(LogLevel level) {
    return switch (level) {
      LogLevel.debug => 'Debug',
      LogLevel.info => 'Info',
      LogLevel.warn => 'Warn',
      LogLevel.error => 'Error',
    };
  }

  String _formatDate(DateTime date) {
    final y = date.year.toString();
    final m = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  Future<void> _pickSemesterStartDate(
    BuildContext context,
    DateTime currentDate,
  ) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: currentDate,
      firstDate: DateTime(2020, 1, 1),
      lastDate: DateTime(2100, 12, 31),
      helpText: '选择开学日',
      cancelText: '取消',
      confirmText: '确定',
    );
    if (picked == null) return;
    await SemesterCalendar.instance.setSemesterStartDate(picked);
  }

  Future<void> _checkForUpdate(BuildContext context) async {
    final result = await UpdateChecker.instance.check();
    if (!context.mounted) return;

    switch (result.status) {
      case UpdateCheckStatus.disabled:
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('当前为内部开发版本，请通过统一发布渠道获取新版本')),
        );
        break;
      case UpdateCheckStatus.updateAvailable:
        final release = result.release;
        if (release != null) {
          await showUpdateDialog(context, release);
        }
        break;
      case UpdateCheckStatus.upToDate:
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(const SnackBar(content: Text('当前已是最新版本')));
        break;
      case UpdateCheckStatus.error:
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(const SnackBar(content: Text('检查更新失败，请稍后重试')));
        break;
      case UpdateCheckStatus.checking:
        break;
    }
  }

  Future<void> _clearOfflineCache(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清除离线缓存'),
        content: const Text('将清空课表、目录等离线缓存，不影响登录状态与个性化设置。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await JsonCacheStore.instance.clearAll();
    messenger?.showSnackBar(const SnackBar(content: Text('离线缓存已清除')));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppAppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          const _SectionHeader('外观'),
          const SizedBox(height: 8),
          _GroupCard(
            children: [
              _SettingsRow(
                icon: Icons.palette_outlined,
                title: '外观与个性化',
                subtitle: '主题、颜色、背景、材质与显示',
                trailing: _chevron(context),
                onTap: () => context.pushNamed('appearance'),
              ),
            ],
          ),
          const SizedBox(height: 24),
          const _SectionHeader('校园'),
          const SizedBox(height: 8),
          ValueListenableBuilder<DateTime>(
            valueListenable: SemesterCalendar.instance.semesterStartDate,
            child: const _CurrentTermTile(),
            builder: (context, semesterStartDate, child) {
              return _GroupCard(
                children: [
                  ?child,
                  const _Hairline(),
                  const _EnrollmentYearRow(),
                  const _Hairline(),
                  _SettingsRow(
                    icon: Icons.edit_calendar_outlined,
                    title: '当前学期开学日',
                    subtitle: '${_formatDate(semesterStartDate)}（用于周次与下一节课计算）',
                    trailing: _chevron(context),
                    onTap: () async {
                      await _pickSemesterStartDate(context, semesterStartDate);
                    },
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(0, 0, 12, 10),
                      child: TextButton(
                        onPressed: () async {
                          await SemesterCalendar.instance
                              .resetSemesterStartDate();
                        },
                        child: Text(
                          '恢复默认（${_formatDate(SemesterCalendar.defaultSemesterStartFor(DateTime.now()))}）',
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 16),
          Text(
            '设置会立即生效。',
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 24),
          const _SectionHeader('桌面与后台'),
          const SizedBox(height: 8),
          _GroupCard(
            children: [
              _SettingsRow(
                icon: Icons.widgets_outlined,
                title: '桌面与后台',
                subtitle: '桌面组件、快捷方式、通知权限与后台运行说明',
                trailing: _chevron(context),
                onTap: () => context.pushNamed('desktop-background'),
              ),
            ],
          ),
          const SizedBox(height: 24),
          const _SectionHeader('账户与数据'),
          const SizedBox(height: 8),
          _GroupCard(
            children: [
              _SettingsRow(
                icon: Icons.school_outlined,
                title: '教务系统',
                subtitle: '登录状态与课表、成绩数据来源',
                trailing: _chevron(context),
                onTap: () => context.pushNamed('academic-service'),
              ),
              const _Hairline(),
              _SettingsRow(
                icon: Icons.verified_user_outlined,
                title: '统一认证',
                subtitle: '统一认证（含一卡通）登录状态',
                trailing: _chevron(context),
                onTap: () => context.pushNamed('unified-auth-login'),
              ),
              const _Hairline(),
              _SettingsRow(
                icon: Icons.cleaning_services_outlined,
                title: '清除离线缓存',
                subtitle: '清空目录与资源缓存，不影响登录状态',
                trailing: _chevron(context),
                onTap: () => _clearOfflineCache(context),
              ),
            ],
          ),
          const SizedBox(height: 24),
          const _SectionHeader('应用'),
          const SizedBox(height: 8),
          FutureBuilder<PackageInfo>(
            future: PackageInfo.fromPlatform(),
            builder: (context, snapshot) {
              final version = snapshot.hasData
                  ? '当前版本 v${snapshot.data!.version}+${snapshot.data!.buildNumber}'
                  : '查看当前版本信息';
              return ValueListenableBuilder<AppRelease?>(
                valueListenable: UpdateChecker.instance.availableRelease,
                builder: (context, release, child) {
                  return ValueListenableBuilder<bool>(
                    valueListenable: UpdateChecker.instance.isChecking,
                    builder: (context, isChecking, child) {
                      final subtitle = release != null
                          ? '发现新版本 v${release.version}'
                          : UpdateChecker.instance.isUpdateEnabled
                          ? version
                          : '当前版本暂未开放在线更新';
                      return _GroupCard(
                        children: [
                          _SettingsRow(
                            icon: Icons.system_update_outlined,
                            title: '检查更新',
                            subtitle: subtitle,
                            trailing: isChecking
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Icon(
                                    release != null
                                        ? Icons.new_releases_outlined
                                        : Icons.chevron_right,
                                    size: 20,
                                    color: release != null
                                        ? cs.primary
                                        : cs.onSurfaceVariant,
                                  ),
                            onTap: isChecking
                                ? null
                                : () {
                                    _checkForUpdate(context);
                                  },
                          ),
                          const _Hairline(),
                          _SettingsRow(
                            icon: Icons.info_outline,
                            title: '关于',
                            subtitle: '开发者与发布页',
                            trailing: _chevron(context),
                            onTap: () => context.pushNamed('about'),
                          ),
                        ],
                      );
                    },
                  );
                },
              );
            },
          ),
          const SizedBox(height: 24),
          FutureBuilder<PackageInfo>(
            future: PackageInfo.fromPlatform(),
            builder: (context, snapshot) {
              final version = snapshot.hasData
                  ? 'v${snapshot.data!.version}+${snapshot.data!.buildNumber}'
                  : '';
              return Center(
                child: Text(
                  '嘉兴大学 $version',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              );
            },
          ),
          if (kDebugMode) ...[
            const SizedBox(height: 16),
            const _SectionHeader('调试'),
            const SizedBox(height: 8),
            ValueListenableBuilder<bool>(
              valueListenable: AppLogger.instance.loggingEnabled,
              builder: (context, loggingEnabled, child) {
                return ValueListenableBuilder<LogConfig>(
                  valueListenable: AppLogger.instance.config,
                  builder: (context, logConfig, _) {
                    return _GroupCard(
                      children: [
                        _SwitchRow(
                          icon: Icons.bug_report_outlined,
                          title: '调试日志',
                          subtitle: '开启后记录调试期日志和异常',
                          value: loggingEnabled,
                          onToggle: (value) {
                            AppLogger.instance.setEnabled(value);
                          },
                        ),
                        const _Hairline(),
                        _SettingsRow(
                          icon: Icons.format_list_bulleted_outlined,
                          title: '最低日志级别',
                          subtitle: _formatLogLevel(logConfig.minimumLevel),
                          trailing: AppDropdown<LogLevel>(
                            value: logConfig.minimumLevel,
                            onChanged: (value) {
                              if (value == null) return;
                              AppLogger.instance.updateConfig(
                                logConfig.copyWith(minimumLevel: value),
                              );
                            },
                            items: LogLevel.values
                                .map(
                                  (level) => AppDropdownItem(
                                    value: level,
                                    label: _formatLogLevel(level),
                                  ),
                                )
                                .toList(),
                          ),
                        ),
                        const _Hairline(),
                        _SwitchRow(
                          icon: Icons.public_outlined,
                          title: 'WebView 生命周期日志',
                          subtitle: '页面加载、跳转和白屏探测细节',
                          value: logConfig.webviewLifecycleEnabled,
                          onToggle: (value) {
                            AppLogger.instance.updateConfig(
                              logConfig.copyWith(
                                webviewLifecycleEnabled: value,
                              ),
                            );
                          },
                        ),
                        const _Hairline(),
                        _SwitchRow(
                          icon: Icons.code_outlined,
                          title: 'WebView 控制台日志',
                          subtitle: '记录页面 console warning/error',
                          value: logConfig.webviewConsoleEnabled,
                          onToggle: (value) {
                            AppLogger.instance.updateConfig(
                              logConfig.copyWith(webviewConsoleEnabled: value),
                            );
                          },
                        ),
                        const _Hairline(),
                        _SwitchRow(
                          icon: Icons.wifi_outlined,
                          title: '网络详细日志',
                          subtitle: '记录请求和响应细节，噪音较大',
                          value: logConfig.networkVerboseEnabled,
                          onToggle: (value) {
                            AppLogger.instance.updateConfig(
                              logConfig.copyWith(networkVerboseEnabled: value),
                            );
                          },
                        ),
                        const _Hairline(),
                        _SettingsRow(
                          icon: Icons.notifications_outlined,
                          title: '通知测试',
                          subtitle: '发送一条本地测试通知',
                          trailing: Icon(
                            Icons.send_outlined,
                            size: 20,
                            color: cs.onSurfaceVariant,
                          ),
                          onTap: () {
                            AppNotificationService.instance.showNotification(
                              id: 999,
                              title: '测试通知',
                              body:
                                  '这是一条来自开发模式的测试通知，${DateTime.now().hour.toString().padLeft(2, '0')}:${DateTime.now().minute.toString().padLeft(2, '0')}',
                              payload: 'test',
                            );
                          },
                        ),
                        const _Hairline(),
                        _SettingsRow(
                          icon: Icons.notifications_active_outlined,
                          title: '推送令牌',
                          subtitle: '查看 FCM 推送注册状态',
                          trailing: _chevron(context),
                          onTap: () => context.pushNamed('push-debug'),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
          ],
        ],
      ),
    );
  }

  static Widget _chevron(BuildContext context) {
    return Icon(
      Icons.chevron_right,
      size: 20,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
  }
}

/// 分组小节标题：13/w600/onSurfaceVariant（Apple Settings 式小节标签）。
class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Text(
      title,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: cs.onSurfaceVariant,
        letterSpacing: 0.2,
      ),
    );
  }
}

/// 分组卡：AppCard 平色卡面 + 零内边距，内部行由 hairline 分隔。
class _GroupCard extends StatelessWidget {
  const _GroupCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: EdgeInsets.zero,
      child: ClipRRect(
        borderRadius: AppRadius.cardBorder,
        child: Column(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }
}

/// 组内 hairline 分隔线：outlineVariant @ 0.35，左缩进与行文字对齐。
class _Hairline extends StatelessWidget {
  const _Hairline();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Divider(
      height: 1,
      thickness: 1,
      // 行内边距 16 + 徽标 36 + 间距 12 = 文字起始位。
      indent: 64,
      color: cs.outlineVariant.withValues(alpha: 0.35),
    );
  }
}

/// 设置行：图标徽标 + 标题/副标题 + 右侧控件（chevron / Switch / Dropdown）。
class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          child: Row(
            children: [
              AppIconBadge(
                icon: icon,
                accentColor: cs.primary,
                size: AppIconBadgeSize.small,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurface,
                        height: 1.2,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        style: TextStyle(
                          fontSize: 13,
                          color: cs.onSurfaceVariant,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 12), trailing!],
            ],
          ),
        ),
      ),
    );
  }
}

/// 开关行：延续 SwitchListTile 的「点行即切换」语义，样式并入平色行。
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.icon,
    required this.title,
    required this.value,
    required this.onToggle,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    return _SettingsRow(
      icon: icon,
      title: title,
      subtitle: subtitle,
      trailing: Switch.adaptive(value: value, onChanged: onToggle),
      onTap: () => onToggle(!value),
    );
  }
}

/// 「我的年级」行：跟随学号自动识别（取学号开头 20XX），可手动覆盖；
/// 仅用于过滤教务处公告，不参与登录/身份逻辑。行尾紧凑下拉的哨兵值与
/// 选项构造沿用原「我的」页实现。
class _EnrollmentYearRow extends StatefulWidget {
  const _EnrollmentYearRow();

  @override
  State<_EnrollmentYearRow> createState() => _EnrollmentYearRowState();
}

class _EnrollmentYearRowState extends State<_EnrollmentYearRow> {
  /// 「自动（跟随学号）」选项的哨兵值：null 的手动设置与「恢复自动」
  /// 语义相同，但菜单里需要一个可点选的选项值。
  static const _autoSentinel = -1;

  /// 「自动」置顶并标注当前识别结果，其后可选年份从明年倒排到 2016 级。
  List<AppDropdownItem<int>> _items() {
    final auto = UserProfileController.instance.autoEnrollmentYear.value;
    final thisYear = DateTime.now().year;
    return [
      AppDropdownItem(
        value: _autoSentinel,
        label: auto == null ? '自动' : '自动（$auto级）',
      ),
      for (var year = thisYear + 1; year >= 2016; year--)
        AppDropdownItem(value: year, label: '$year级'),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return _SettingsRow(
      icon: Icons.badge_outlined,
      title: '我的年级',
      subtitle: '默认跟随学号自动识别，仅用于过滤教务处公告，可能误判',
      trailing: AppDropdown<int>(
        value:
            UserProfileController.instance.manualEnrollmentYear.value ??
            _autoSentinel,
        items: _items(),
        onChanged: (value) {
          if (value == null) return;
          unawaited(
            UserProfileController.instance
                .setManualEnrollmentYear(value == _autoSentinel ? null : value)
                .then((_) {
                  if (mounted) setState(() {});
                }),
          );
        },
      ),
    );
  }
}

/// 设置页展示自动识别出的当前学年学期。
///
/// 复用 [CurrentTermResolver] 的 TTL 缓存：未过期时零请求，
/// 过期且已登录教务时才发起一次识别请求。
class _CurrentTermTile extends StatefulWidget {
  const _CurrentTermTile();

  @override
  State<_CurrentTermTile> createState() => _CurrentTermTileState();
}

class _CurrentTermTileState extends State<_CurrentTermTile> {
  ScheduleTermContext? _resolved;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_resolveTerm());
  }

  Future<void> _resolveTerm() async {
    final resolved = await CurrentTermResolver.instance.resolve();
    if (!mounted) return;
    setState(() {
      _resolved = resolved;
      _loading = false;
    });
  }

  String _termLabel(ScheduleTermContext term) {
    return '${term.academicYear}-${term.academicYear + 1}学年 ${term.termLabel}';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final term = _resolved ?? ScheduleTermContext.current();
    final subtitle = _loading
        ? '正在从教务系统识别…'
        : _resolved != null
        ? '已从教务系统自动识别'
        : '按日期推算（未登录或教务不可达）';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: Row(
        children: [
          AppIconBadge(
            icon: Icons.school_outlined,
            accentColor: cs.primary,
            size: AppIconBadgeSize.small,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '当前学年学期',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${_termLabel(term)} · $subtitle',
                  style: TextStyle(
                    fontSize: 13,
                    color: cs.onSurfaceVariant,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
          if (_loading) ...[
            const SizedBox(width: 12),
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ],
        ],
      ),
    );
  }
}
