import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/auth/zhengfang_auth.dart';
import '../../core/cache/json_cache_store.dart';
import '../../core/calendar/calendar_sync_channel.dart';
import '../../core/calendar/calendar_sync_control.dart';
import '../../core/calendar/calendar_sync_models.dart';
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

  /// 宽屏（平板 / 折叠屏展开）下内容列限宽居中；手机宽度不受影响。
  static const double _contentMaxWidth = 640;

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

  /// 复制本次启动以来的认证诊断轨迹（内存、已脱敏），供 release 真机反馈。
  Future<void> _copyAuthTrail(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    var copied = false;
    try {
      await Clipboard.setData(
        ClipboardData(text: AppLogger.instance.formatAuthTrail()),
      );
      copied = true;
    } on PlatformException {
      copied = false;
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(copied ? '登录诊断日志已复制' : '复制失败')));
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
      builder: (dialogContext) {
        final cs = Theme.of(dialogContext).colorScheme;
        return AlertDialog(
          title: const Text('清除离线缓存'),
          content: const Text('将清除目录等临时缓存，不影响登录状态、课表缓存与个性化设置。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            // 确认按钮是不可撤销动作，用错误色与「取消」拉开层级。
            TextButton(
              style: TextButton.styleFrom(foregroundColor: cs.error),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('清除'),
            ),
          ],
        );
      },
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
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _contentMaxWidth),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              const _SectionHeader('外观'),
              const SizedBox(height: 8),
              _GroupCard(
                children: [
                  _SettingsRow(
                    icon: Icons.palette_outlined,
                    title: '主题与色彩',
                    subtitle: '深浅模式、强调色与字体大小',
                    trailing: _chevron(context),
                    onTap: () => context.pushNamed('appearance'),
                  ),
                  const _Hairline(),
                  _SettingsRow(
                    icon: Icons.auto_awesome_outlined,
                    title: '个性化',
                    subtitle: '背景、动态效果与材质显示',
                    trailing: _chevron(context),
                    onTap: () => context.pushNamed('personalization'),
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
                        subtitle:
                            '${_formatDate(semesterStartDate)}（用于周次与下一节课计算）',
                        trailing: _chevron(context),
                        onTap: () async {
                          await _pickSemesterStartDate(
                            context,
                            semesterStartDate,
                          );
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
              const SizedBox(height: 8),
              const _SectionCaption('学期设置会立即生效。'),
              if (Theme.of(context).platform == TargetPlatform.android) ...[
                const SizedBox(height: 24),
                const _SectionHeader('课表日历'),
                const SizedBox(height: 8),
                const _CalendarSyncCard(),
                const SizedBox(height: 8),
                const _SectionCaption('课表仅在应用前台写入系统日历；课前 10 分钟由系统日历提醒（非精确闹钟）。'),
              ],
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
                    icon: Icons.cleaning_services_outlined,
                    title: '清除离线缓存',
                    subtitle: '清除目录等临时缓存，不影响登录和课表',
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
                      : '正在读取版本信息…';
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
                                emphasizeSubtitle: release != null,
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
                              const _Hairline(),
                              _SettingsRow(
                                icon: Icons.receipt_long_outlined,
                                title: '复制登录诊断日志',
                                subtitle: '登录异常时复现后复制，已脱敏，不含密码与验证码',
                                trailing: _chevron(context),
                                onTap: () => _copyAuthTrail(context),
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
                      : null;
                  return Center(
                    child: _SectionCaption(
                      version == null ? '嘉兴大学' : '嘉兴大学 $version',
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
                                  logConfig.copyWith(
                                    webviewConsoleEnabled: value,
                                  ),
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
                                  logConfig.copyWith(
                                    networkVerboseEnabled: value,
                                  ),
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
        ),
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
/// 以 header 语义暴露，读屏按小节跳转时可识别。
class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      header: true,
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: cs.onSurfaceVariant,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

/// 小节脚注：12px/1.4 弱化色，紧贴卡片说明边界条件与副作用。
class _SectionCaption extends StatelessWidget {
  const _SectionCaption(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        height: 1.4,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
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
///
/// 整行合并为单一语义节点（标题/副标题/尾部控件一并朗读）；可点击行以
/// 按钮语义暴露点击动作。[emphasizeSubtitle] 把「发现新版本」这类需要
/// 用户注意的副标题提到主题色。
class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.emphasizeSubtitle = false,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool emphasizeSubtitle;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tappable = onTap != null;
    return Semantics(
      button: tappable ? true : null,
      enabled: tappable ? true : null,
      child: MergeSemantics(
        child: Material(
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
                              fontWeight: emphasizeSubtitle
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: emphasizeSubtitle
                                  ? cs.primary
                                  : cs.onSurfaceVariant,
                              height: 1.3,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (trailing != null) ...[
                    const SizedBox(width: 12),
                    trailing!,
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 开关行：延续 SwitchListTile 的「点行即切换」语义，样式并入平色行。
/// [enabled] 为 false 时整行与开关一起置灰不可用（如原生调用在途）。
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.icon,
    required this.title,
    required this.value,
    required this.onToggle,
    this.subtitle,
    this.enabled = true,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onToggle;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return _SettingsRow(
      icon: icon,
      title: title,
      subtitle: subtitle,
      trailing: Switch.adaptive(
        value: value,
        onChanged: enabled ? onToggle : null,
      ),
      onTap: enabled ? () => onToggle(!value) : null,
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
    final term = _resolved ?? ScheduleTermContext.current();
    final subtitle = _loading
        ? '正在从教务系统识别…'
        : _resolved != null
        ? '已从教务系统自动识别'
        : '按日期推算（未登录或教务不可达）';

    // 只读信息行：无点击语义，识别中在行尾给一个轻量进度指示。
    return _SettingsRow(
      icon: Icons.school_outlined,
      title: '当前学年学期',
      subtitle: '${_termLabel(term)} · $subtitle',
      trailing: _loading
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : null,
    );
  }
}

/// 「课表日历」分组的开关卡片（仅 Android，由调用方按平台隐藏）。
///
/// 机械复用小节样式：开关行 + 关闭确认 AlertDialog + SnackBar 反馈。
/// 状态机、权限、日历解析与清理全部由 core 的 [CalendarSyncControl] /
/// [CalendarSyncChannel] 承担；本组件不读取课表、不生成事件、不展示学号。
class _CalendarSyncCard extends StatefulWidget {
  const _CalendarSyncCard();

  @override
  State<_CalendarSyncCard> createState() => _CalendarSyncCardState();
}

/// 首次开启时用户选择的目标日历类型。
enum _CalendarSyncTarget {
  /// 本应用专属本地日历（[CalendarSyncControl.enable] 不传 calendarId）。
  local,

  /// 用户从系统可写日历中显式选择。
  existing,
}

class _CalendarSyncCardState extends State<_CalendarSyncCard> {
  CalendarSyncControl get _control => CalendarSyncControl.instance;

  /// 有开启/清理请求在途：期间忽略重复点击，避免重复原生调用。
  bool _busy = false;

  int? _residualCount;
  bool _residualLoading = false;
  bool _residualFailed = false;
  Set<CalendarSyncCleanupResidualReason> _residualReasons =
      const <CalendarSyncCleanupResidualReason>{};

  @override
  void initState() {
    super.initState();
    _control.addListener(_handleControlChanged);
    unawaited(
      _control.load().then((_) {
        if (!mounted) return;
        setState(() {});
        if (_control.state == CalendarSyncControlState.cleanupPending) {
          unawaited(_refreshResidualCount());
        }
      }),
    );
  }

  @override
  void dispose() {
    _control.removeListener(_handleControlChanged);
    super.dispose();
  }

  void _handleControlChanged() {
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _refreshResidualCount() async {
    setState(() {
      _residualLoading = true;
      _residualFailed = false;
    });
    try {
      final count = await _control.residualCount();
      if (!mounted) return;
      setState(() {
        _residualCount = count;
        _residualLoading = false;
      });
    } on CalendarSyncException {
      if (!mounted) return;
      setState(() {
        _residualLoading = false;
        _residualFailed = true;
      });
    }
  }

  String get _subtitle => switch (_control.state) {
    CalendarSyncControlState.off => '将课表写入系统日历；仅前台同步，课前 10 分钟提醒',
    CalendarSyncControlState.enabled => '已开启；前台校验课表后同步',
    CalendarSyncControlState.paused => '已暂停：当前账号与绑定账号不一致，重新开启将绑定当前账号',
    CalendarSyncControlState.cleanupPending => '清理未完成，完成清理后才能重新开启',
  };

  String _residualSubtitle() {
    final String countLabel;
    if (_residualFailed) {
      countLabel = '残留数量统计失败';
    } else if (_residualCount == null) {
      countLabel = _residualLoading ? '正在统计残留…' : '残留数量未知';
    } else {
      countLabel = '仍有 $_residualCount 条事件残留';
    }
    final reasons = _describeResidualReasons(_residualReasons);
    return reasons.isEmpty ? '$countLabel，可重试删除' : '$countLabel（$reasons）';
  }

  @override
  Widget build(BuildContext context) {
    final state = _control.state;
    return _GroupCard(
      children: [
        _SwitchRow(
          icon: Icons.event_available_outlined,
          title: '课表日历同步',
          subtitle: _subtitle,
          value: state == CalendarSyncControlState.enabled,
          // 开启/清理请求在途：整行置灰，避免重复触发原生调用。
          enabled: !_busy,
          onToggle: (value) {
            if (_busy) return;
            unawaited(value ? _requestEnable() : _requestDisable());
          },
        ),
        if (state == CalendarSyncControlState.cleanupPending) ...[
          const _Hairline(),
          _SettingsRow(
            icon: Icons.delete_sweep_outlined,
            title: '清理未完成',
            subtitle: _residualSubtitle(),
            trailing: TextButton(
              onPressed: _busy ? null : () => unawaited(_runCleanup()),
              child: const Text('重试清理'),
            ),
            onTap: _busy ? null : () => unawaited(_runCleanup()),
          ),
        ],
      ],
    );
  }

  /// 开关打开：先用**当前**已验证身份校验，再让用户选择目标日历。
  Future<void> _requestEnable() async {
    final auth = ZhengfangAuth.instance;
    final studentId = auth.currentStudentId?.trim() ?? '';
    if (!auth.isLoggedIn || studentId.isEmpty) {
      _showSnack('请先登录教务系统，再开启课表日历同步');
      return;
    }
    if (_control.state == CalendarSyncControlState.cleanupPending) {
      _showSnack('存在未完成的清理，请先点击「重试清理」');
      return;
    }

    setState(() => _busy = true);
    try {
      final target = await _askCalendarTarget();
      if (!mounted || target == null) return;
      if (target == _CalendarSyncTarget.existing) {
        await _enableWithExistingCalendar(studentId);
        return;
      }
      await _enable(studentId: studentId, calendarId: null);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 开关关闭：先确认，再尝试删除全部历史账号/学期由本应用创建的事件。
  Future<void> _requestDisable() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('关闭课表日历同步'),
        content: const Text(
          '将尝试删除本应用在全部历史账号与学期写入系统日历的事件，不会影响其他应用或系统日历中的其他事件。\n\n'
          '部分事件可能已被移动或删除失败，届时会显示残留数量与原因，可稍后重试。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('关闭并清理'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _runCleanup();
  }

  /// 关闭 / 重试清理共用：调用 core 的 [CalendarSyncControl.disableAndCleanup]，
  /// 无登录也能执行；有残留时如实显示数量与原因，绝不假称已关闭。
  Future<void> _runCleanup() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await _control.disableAndCleanup();
      if (!mounted) return;
      setState(() {
        _residualCount = result.residualCount;
        _residualReasons = result.residualReasons;
        _residualFailed = false;
      });
      _showSnack(_cleanupMessage(result));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<_CalendarSyncTarget?> _askCalendarTarget() {
    return showDialog<_CalendarSyncTarget>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('开启课表日历同步'),
        content: const Text(
          '将把课表写入系统日历，仅在应用前台同步；课前 10 分钟由系统日历提醒（非精确闹钟）。\n\n'
          '推荐使用本应用的专属本地日历；部分系统日历应用可能不显示它，也可以改选其他可写日历。\n\n'
          '手动编辑已写入的事件后，下一次课表同步会覆盖这些修改。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(_CalendarSyncTarget.existing),
            child: const Text('选择其他日历'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(_CalendarSyncTarget.local),
            child: const Text('使用专属本地日历'),
          ),
        ],
      ),
    );
  }

  /// 用户明确点击「选择其他日历」后才申请权限并列出可写日历；
  /// 权限拒绝、读取失败、列表为空、用户取消都安全返回，不开启同步。
  Future<void> _enableWithExistingCalendar(String studentId) async {
    final channel = defaultCalendarSyncChannel;
    final granted =
        await channel.checkPermissions() || await channel.requestPermissions();
    if (!mounted) return;
    if (!granted) {
      _showSnack('未获得日历读写权限，已取消');
      return;
    }

    final List<CalendarSyncWritableCalendar> calendars;
    try {
      calendars = await channel.listWritableCalendars();
    } on CalendarSyncException {
      if (!mounted) return;
      _showSnack('读取系统日历失败，请稍后重试');
      return;
    }
    if (!mounted) return;
    if (calendars.isEmpty) {
      _showSnack('没有可写入的系统日历');
      return;
    }

    final picked = await _askCalendar(calendars);
    if (!mounted || picked == null) return;
    await _enable(studentId: studentId, calendarId: picked.id);
  }

  Future<CalendarSyncWritableCalendar?> _askCalendar(
    List<CalendarSyncWritableCalendar> calendars,
  ) {
    return showDialog<CalendarSyncWritableCalendar>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('选择目标日历'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final calendar in calendars)
                ListTile(
                  title: Text(calendar.displayName),
                  subtitle: calendar.accountName == null
                      ? null
                      : Text(calendar.accountName!),
                  onTap: () => Navigator.of(dialogContext).pop(calendar),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  Future<void> _enable({
    required String studentId,
    required int? calendarId,
  }) async {
    final result = await _control.enable(
      ownerKey: studentId,
      calendarId: calendarId,
      revision: ZhengfangAuth.instance.sessionRevision,
    );
    if (!mounted) return;
    if (result.enabled) {
      _showSnack('课表日历同步已开启，前台校验课表后同步');
      return;
    }
    if (result.blockedByCleanup) {
      _showSnack('存在未完成的清理，请先点击「重试清理」');
      return;
    }
    _showSnack(
      result.failure?.kind == CalendarSyncFailureKind.permissionDenied
          ? '未获得日历读写权限，同步未开启'
          : '开启失败，请稍后重试',
    );
  }

  String _cleanupMessage(CalendarSyncCleanupResult result) {
    if (result.isComplete) return '已关闭课表日历同步并清理全部事件';
    final reasons = _describeResidualReasons(result.residualReasons);
    if (result.residualCount > 0) {
      return reasons.isEmpty
          ? '仍有 ${result.residualCount} 条事件未清理，可重试'
          : '仍有 ${result.residualCount} 条事件未清理（$reasons），可重试';
    }
    return reasons.isEmpty ? '清理未完成，请重试' : '清理未完成（$reasons），请重试';
  }

  static String _describeResidualReasons(
    Set<CalendarSyncCleanupResidualReason> reasons,
  ) {
    if (reasons.isEmpty) return '';
    return reasons
        .map(
          (reason) => switch (reason) {
            CalendarSyncCleanupResidualReason.notDeleted => '部分事件未删除或已被移动',
            CalendarSyncCleanupResidualReason.permissionDenied => '日历权限被拒绝',
            CalendarSyncCleanupResidualReason.calendarUnavailable => '目标日历不可用',
            CalendarSyncCleanupResidualReason.platformFailure => '系统日历调用失败',
            CalendarSyncCleanupResidualReason.pendingUnreconciled =>
              '部分写入结果未确认',
          },
        )
        .join('、');
  }

  void _showSnack(String message) {
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(message)));
  }
}
