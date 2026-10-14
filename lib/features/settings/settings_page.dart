import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/auth/zhengfang_auth.dart';
import '../../core/cache/json_cache_store.dart';
import '../../core/calendar/calendar_reminder_settings.dart';
import '../../core/calendar/calendar_sync_channel.dart';
import '../../core/calendar/calendar_sync_control.dart';
import '../../core/calendar/calendar_sync_models.dart';
import '../../core/logging/app_logger.dart';
import '../../core/notification/app_notification_service.dart';
import '../../core/profile/user_profile_controller.dart';
import '../../core/semester/current_term_resolver.dart';
import '../../core/semester/semester_calendar.dart';
import '../../core/semester/schedule_term_context.dart';
import '../../core/update/update_checker.dart';
import '../../core/update/update_model.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_dropdown.dart';
import '../../shared/widgets/app_feedback.dart';
import '../../shared/widgets/glass_dialog_route.dart';
import '../../shared/widgets/plain_list.dart';
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

  String _formatMonthDay(DateTime date) => '${date.month}月${date.day}日';

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
        AppFeedback.toast(context, '当前为内部开发版本，请通过统一发布渠道获取新版本');
        break;
      case UpdateCheckStatus.updateAvailable:
        final release = result.release;
        if (release != null) {
          await showUpdateDialog(context, release);
        }
        break;
      case UpdateCheckStatus.upToDate:
        AppFeedback.toast(context, '当前已是最新版本');
        break;
      case UpdateCheckStatus.error:
        AppFeedback.toast(context, '检查更新失败，请稍后重试');
        break;
      case UpdateCheckStatus.checking:
        break;
    }
  }

  Future<void> _clearOfflineCache(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final confirmed = await AppFeedback.confirm(
      context,
      title: '清除离线缓存',
      message: '将清除目录等临时缓存，不影响登录状态、课表缓存与个性化设置。',
      confirmLabel: '清除',
      destructive: true,
    );
    if (!confirmed) return;
    await JsonCacheStore.instance.clearAll();
    if (messenger != null) AppFeedback.toastOn(messenger, '离线缓存已清除');
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
            padding: const EdgeInsets.fromLTRB(
              kPlainListGutter,
              8,
              kPlainListGutter,
              32,
            ),
            children: [
              const PlainSectionHeader('外观'),
              PlainListGroup(
                children: [
                  PlainListRow(
                    title: '主题与色彩',
                    onTap: () => context.pushNamed('appearance'),
                  ),
                  PlainListRow(
                    title: '个性化',
                    onTap: () => context.pushNamed('personalization'),
                  ),
                ],
              ),
              const SizedBox(height: kPlainListGroupGap),
              const PlainSectionHeader('学期'),
              PlainListGroup(
                children: [
                  const _CurrentTermTile(),
                  const _EnrollmentYearRow(),
                  ValueListenableBuilder<DateTime>(
                    valueListenable:
                        SemesterCalendar.instance.semesterStartDate,
                    builder: (context, semesterStartDate, _) {
                      final defaultStart =
                          SemesterCalendar.defaultSemesterStartFor(
                            DateTime.now(),
                          );
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          PlainListRow(
                            title: '开学日',
                            value: _formatMonthDay(semesterStartDate),
                            showChevron: true,
                            onTap: () async {
                              await _pickSemesterStartDate(
                                context,
                                semesterStartDate,
                              );
                            },
                          ),
                          // 只在改过开学日时出现，避免常驻一个没用的按钮。
                          if (!DateUtils.isSameDay(
                            semesterStartDate,
                            defaultStart,
                          )) ...[
                            PlainListRow(
                              title: '恢复默认开学日',
                              value: _formatMonthDay(defaultStart),
                              onTap: () async {
                                await SemesterCalendar.instance
                                    .resetSemesterStartDate();
                              },
                            ),
                          ],
                        ],
                      );
                    },
                  ),
                ],
              ),
              const SizedBox(height: kPlainListGroupGap),
              const PlainSectionHeader('课表与后台'),
              PlainListGroup(
                children: [
                  if (Theme.of(context).platform == TargetPlatform.android)
                    const _CalendarSyncCard(),
                  PlainListRow(
                    title: '桌面组件与后台',
                    onTap: () => context.pushNamed('desktop-background'),
                  ),
                ],
              ),
              const SizedBox(height: kPlainListGroupGap),
              const PlainSectionHeader('其他'),
              PlainListGroup(
                children: [
                  ValueListenableBuilder<AppRelease?>(
                    valueListenable: UpdateChecker.instance.availableRelease,
                    builder: (context, release, _) {
                      return ValueListenableBuilder<bool>(
                        valueListenable: UpdateChecker.instance.isChecking,
                        builder: (context, isChecking, _) {
                          return FutureBuilder<PackageInfo>(
                            future: PackageInfo.fromPlatform(),
                            builder: (context, snapshot) {
                              final String? value;
                              if (release != null) {
                                value = '新版本 v${release.version}';
                              } else if (snapshot.hasData) {
                                value = 'v${snapshot.data!.version}';
                              } else {
                                value = null;
                              }
                              return PlainListRow(
                                title: '检查更新',
                                value: value,
                                emphasizeValue: release != null,
                                trailing: isChecking
                                    ? const SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : null,
                                showChevron: false,
                                onTap: isChecking
                                    ? null
                                    : () {
                                        _checkForUpdate(context);
                                      },
                              );
                            },
                          );
                        },
                      );
                    },
                  ),
                  PlainListRow(
                    title: '清除离线缓存',
                    onTap: () => _clearOfflineCache(context),
                  ),
                  PlainListRow(
                    title: '关于与诊断',
                    onTap: () => context.pushNamed('about'),
                  ),
                ],
              ),
              if (kDebugMode) ...[
                const SizedBox(height: kPlainListGroupGap),
                const PlainSectionHeader('调试'),
                ValueListenableBuilder<bool>(
                  valueListenable: AppLogger.instance.loggingEnabled,
                  builder: (context, loggingEnabled, child) {
                    return ValueListenableBuilder<LogConfig>(
                      valueListenable: AppLogger.instance.config,
                      builder: (context, logConfig, _) {
                        return PlainListGroup(
                          children: [
                            PlainSwitchRow(
                              title: '调试日志',
                              subtitle: '开启后记录调试期日志和异常',
                              value: loggingEnabled,
                              onChanged: (value) {
                                AppLogger.instance.setEnabled(value);
                              },
                            ),
                            PlainListRow(
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
                            PlainSwitchRow(
                              title: 'WebView 生命周期日志',
                              subtitle: '页面加载、跳转和白屏探测细节',
                              value: logConfig.webviewLifecycleEnabled,
                              onChanged: (value) {
                                AppLogger.instance.updateConfig(
                                  logConfig.copyWith(
                                    webviewLifecycleEnabled: value,
                                  ),
                                );
                              },
                            ),
                            PlainSwitchRow(
                              title: 'WebView 控制台日志',
                              subtitle: '记录页面 console warning/error',
                              value: logConfig.webviewConsoleEnabled,
                              onChanged: (value) {
                                AppLogger.instance.updateConfig(
                                  logConfig.copyWith(
                                    webviewConsoleEnabled: value,
                                  ),
                                );
                              },
                            ),
                            PlainSwitchRow(
                              title: '网络详细日志',
                              subtitle: '记录请求和响应细节，噪音较大',
                              value: logConfig.networkVerboseEnabled,
                              onChanged: (value) {
                                AppLogger.instance.updateConfig(
                                  logConfig.copyWith(
                                    networkVerboseEnabled: value,
                                  ),
                                );
                              },
                            ),
                            PlainListRow(
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
    return PlainListRow(
      title: '年级',
      trailing: AppDropdown<int>(
        key: const Key('enrollment_year_dropdown'),
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
    // 只在无法从教务识别时说明来源；识别成功是常态，不再注明。
    final subtitle = !_loading && _resolved == null ? '按日期推算' : null;

    // 只读信息行：无点击语义，识别中在行尾给一个轻量进度指示。
    return PlainListRow(
      title: '当前学期',
      value: _termLabel(term),
      subtitle: subtitle,
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
/// 机械复用小节样式：开关行 + 课前提醒行 + 关闭确认 AlertDialog + SnackBar 反馈。
/// 状态机、权限、日历解析与清理全部由 core 的 [CalendarSyncControl] /
/// [CalendarSyncChannel] 承担；提醒提前量由 [CalendarReminderSettings] 持久化。
/// 本组件不读取课表、不生成事件、不展示学号。
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

  CalendarReminderSettings get _reminder => CalendarReminderSettings.instance;

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
    _reminder.addListener(_handleControlChanged);
    // paused 的副标题取决于当前是否有已验证教务身份，登录 / 登出时需要重绘。
    ZhengfangAuth.instance.addListener(_handleControlChanged);
    unawaited(
      _control.load().then((_) {
        if (!mounted) return;
        setState(() {});
        if (_control.state == CalendarSyncControlState.cleanupPending) {
          unawaited(_refreshResidualCount());
        }
      }),
    );
    // 持久化提前量在启动时已 load；此处兜底确保设置页拿到磁盘值。
    unawaited(
      _reminder.load().then((_) {
        if (mounted) setState(() {});
      }),
    );
  }

  @override
  void dispose() {
    _control.removeListener(_handleControlChanged);
    _reminder.removeListener(_handleControlChanged);
    ZhengfangAuth.instance.removeListener(_handleControlChanged);
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

  String? get _subtitle => switch (_control.state) {
    CalendarSyncControlState.off => null,
    // 教务未登录 / 会话过期 / 冷启动尚未恢复：开关保持开启，绑定与事件都保留，
    // 同一账号重新登录后自动继续（不是换号，不暂停）。
    CalendarSyncControlState.enabled =>
      _control.isWaitingForIdentity ? '等待登录教务系统后继续同步，已保留原绑定账号' : null,
    // 当前确有另一个已验证教务账号时才是「账号不一致」；没有已验证身份时
    // （含旧版本因登出而落盘的 paused）同一账号登录后会自动恢复，不能提示不一致。
    CalendarSyncControlState.paused =>
      ZhengfangAuth.instance.verifiedStudentId == null
          ? '已暂停：登录教务系统后将自动恢复（同一账号）'
          : '已暂停：当前教务账号与绑定账号不一致，重新开启将绑定当前账号',
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

  /// 0 不是「不提醒」：原生 `CalendarProviderStore` 对每个归属事件固定插入
  /// 一条 `MINUTES = reminderMinutes` 的 `METHOD_ALERT` 提醒，0 表示**课程
  /// 开始时**提醒，因此如实标注，不谎称可关闭提醒。
  static String _reminderLabel(int minutes) =>
      minutes <= 0 ? '课程开始时提醒' : '提前 $minutes 分钟';

  @override
  Widget build(BuildContext context) {
    final state = _control.state;
    // 外层已在「课表与后台」分组卡片里，这里只排行，不再套卡片。
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        PlainSwitchRow(
          title: '同步到系统日历',
          subtitle: _subtitle,
          value: state == CalendarSyncControlState.enabled,
          // 开启/清理请求在途：整行置灰，避免重复触发原生调用。
          enabled: !_busy,
          onChanged: (value) {
            if (_busy) return;
            unawaited(value ? _requestEnable() : _requestDisable());
          },
        ),
        PlainListRow(
          title: '课前提醒',
          trailing: AppDropdown<int>(
            key: const Key('calendar_reminder_dropdown'),
            inline: true,
            // 历史遗留的非预设值不在列表里：按钮回落显示当前值。
            hint: _reminderLabel(_reminder.reminderMinutes),
            value:
                CalendarReminderSettings.presetMinutes.contains(
                  _reminder.reminderMinutes,
                )
                ? _reminder.reminderMinutes
                : null,
            items: <AppDropdownItem<int>>[
              for (final minutes in CalendarReminderSettings.presetMinutes)
                AppDropdownItem<int>(
                  value: minutes,
                  label: _reminderLabel(minutes),
                ),
            ],
            onChanged: (value) {
              if (value == null) return;
              unawaited(_reminder.setReminderMinutes(value));
            },
          ),
        ),
        if (state == CalendarSyncControlState.cleanupPending) ...[
          PlainListRow(
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
    final confirmed = await AppFeedback.confirm(
      context,
      title: '关闭课表日历同步',
      message:
          '将尝试删除本应用在全部历史账号与学期写入系统日历的事件，不会影响其他应用或系统日历中的其他事件。\n\n'
          '部分事件可能已被移动或删除失败，届时会显示残留数量与原因，可稍后重试。',
      confirmLabel: '关闭并清理',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
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
    final reminderLeadTime = _reminder.reminderMinutes <= 0
        ? '开始时'
        : '课前 ${_reminder.reminderMinutes} 分钟';
    return showGlassDialog<_CalendarSyncTarget>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        title: const Text('开启课表日历同步'),
        content: Text(
          '将把课表写入系统日历，仅在应用前台同步；$reminderLeadTime由系统日历提醒（非精确闹钟）。\n\n'
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
    return showGlassDialog<CalendarSyncWritableCalendar>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
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

  void _showSnack(String message) => AppFeedback.toast(context, message);
}
