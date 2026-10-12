import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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
import '../../core/theme/app_typography.dart';
import '../../core/update/update_checker.dart';
import '../../core/update/update_model.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_dropdown.dart';
import '../../shared/widgets/app_feedback.dart';
import '../../shared/widgets/glass_dialog_route.dart';
import '../../shared/widgets/plain_list.dart';
import '../../shared/widgets/update_dialog.dart';
import 'calendar_legacy_cleanup_dialog.dart';

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
/// 开关 / 目标日历选择 / 遗留扫描预览与确认全部由 core 的
/// [CalendarSyncControl] / [CalendarSyncChannel] 承担；本组件不读取课表、
/// 不生成事件、不展示学号，只呈现 core 聚合好的数量与结果。
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

  /// 有开启 / 扫描 / 清理请求在途：期间忽略重复点击，避免重复原生调用。
  bool _busy = false;

  /// 在途 Future 的真实进度文案；仅请求进行中非 null，空闲时**不**显示任何指示器。
  String? _progress;

  /// 最近一次清理结果摘要（仅本会话持有，用于 cleanupPending 时说明残留）。
  String? _cleanupNote;

  @override
  void initState() {
    super.initState();
    _control.addListener(_handleControlChanged);
    // paused 的副标题取决于当前是否有已验证教务身份，登录 / 登出时需要重绘。
    ZhengfangAuth.instance.addListener(_handleControlChanged);
    unawaited(
      _control.load().then((_) {
        if (!mounted) return;
        setState(() {});
      }),
    );
  }

  @override
  void dispose() {
    _control.removeListener(_handleControlChanged);
    ZhengfangAuth.instance.removeListener(_handleControlChanged);
    super.dispose();
  }

  void _handleControlChanged() {
    if (!mounted) return;
    setState(() {});
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

  /// 非 enabled 状态才显示「扫描遗留日程」入口；enabled 时由关闭开关的确认触发。
  bool get _showScanEntry => _control.state != CalendarSyncControlState.enabled;

  @override
  Widget build(BuildContext context) {
    final state = _control.state;
    final progress = _progress;
    // 外层已在「课表与后台」分组卡片里，这里只排行，不再套卡片。
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        PlainSwitchRow(
          title: '同步到系统日历',
          subtitle: _subtitle,
          value: state == CalendarSyncControlState.enabled,
          // 开启 / 扫描 / 清理请求在途：整行置灰，避免重复触发原生调用。
          enabled: !_busy,
          onChanged: (value) {
            if (_busy) return;
            unawaited(value ? _requestEnable() : _startScan());
          },
        ),
        if (progress != null)
          _busyRow(progress)
        else if (_showScanEntry)
          PlainListRow(
            title: '扫描遗留日程',
            subtitle: '只读扫描带当前应用标记的遗留日程，不会删除任何日程',
            onTap: () => unawaited(_startScan()),
          ),
        if (state == CalendarSyncControlState.cleanupPending &&
            _cleanupNote != null)
          PlainListRow(title: '上次清理结果', subtitle: _cleanupNote),
      ],
    );
  }

  /// 在途提示行：真实 Future 进行中才构建，空闲时不占位、不显示动画。
  Widget _busyRow(String label) => Padding(
    padding: const EdgeInsets.fromLTRB(
      kPlainListRowInset,
      8,
      kPlainListRowInset,
      8,
    ),
    child: Row(
      children: [
        const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 12),
        Expanded(child: Text(label, style: context.appText.secondary)),
      ],
    ),
  );

  /// 开关打开：先用**当前**已验证身份校验，再让用户选择目标日历。
  Future<void> _requestEnable() async {
    final auth = ZhengfangAuth.instance;
    final studentId = auth.currentStudentId?.trim() ?? '';
    if (!auth.isLoggedIn || studentId.isEmpty) {
      _showSnack('请先登录教务系统，再开启课表日历同步');
      return;
    }
    if (_control.state == CalendarSyncControlState.cleanupPending) {
      _showSnack('存在未完成的清理，请先点击「扫描遗留日程」');
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

  /// 扫描遗留日程（只读第一步）：enabled 时先关闭同步但**不删除**，再展示预览。
  ///
  /// 关闭确认只说明「扫描会先关闭同步，不会删除日程」，是否删除留给预览确认；
  /// 关闭后控制态进入 `cleanupPending`，不自动重新开启、不自动登录、不新建日历。
  Future<void> _startScan() async {
    if (_busy) return;
    if (_control.state == CalendarSyncControlState.enabled) {
      setState(() => _busy = true);
      final confirmed = await AppFeedback.confirm(
        context,
        title: '关闭课表日历同步',
        message:
            '扫描会先关闭同步，不会删除任何日程。\n\n'
            '将只读扫描本应用在全部历史账号与学期写入系统日历的遗留日程，'
            '再由你确认是否清理；不会影响其他应用或系统日历中的其他事件。',
        confirmLabel: '关闭并扫描',
        destructive: true,
      );
      if (!mounted) return;
      setState(() => _busy = false);
      if (!confirmed) return;
    }
    await _runScan();
  }

  /// 真正发起只读扫描：展示真实进度，成功后进入预览；失败如实提示、不假称完成。
  Future<void> _runScan() async {
    setState(() {
      _busy = true;
      _progress = '正在扫描遗留日程…';
    });
    CalendarLegacyCleanupScan? scan;
    try {
      scan = await _control.scanLegacyOwnedEvents();
    } on CalendarSyncException {
      scan = null;
    } catch (_) {
      scan = null;
    }
    if (!mounted) return;
    setState(() => _progress = null);
    if (scan == null) {
      setState(() => _busy = false);
      _showSnack('扫描遗留日程失败，请稍后重试');
      return;
    }
    await _presentPreview(scan);
    if (mounted) setState(() => _busy = false);
  }

  /// 展示扫描预览并按用户选择处理；**非确认分支一律放弃同一预览对象**。
  Future<void> _presentPreview(CalendarLegacyCleanupScan scan) async {
    // 完整扫描、无残留且本地已无记录：确实没有可处理对象，如实提示并放弃预览
    //（不伪造「系统日历干净」）；仅在可 dismiss 时才回到关闭态。
    if (scan.dismissible) {
      await _control.dismissLegacyCleanupPreview(scan);
      if (mounted) _showSnack('未发现带当前应用标记的遗留日程');
      return;
    }

    final decision = await AppFeedback.sheet<CalendarLegacyCleanupDecision>(
      context,
      builder: (_) => CalendarLegacyCleanupPreviewSheet(scan: scan),
      scrollControlled: true,
    );

    // 用户确认删除：即使页面已离开也照常交给 core 完成（绝不中断在途删除）。
    if (decision == CalendarLegacyCleanupDecision.cleanup) {
      await _runCleanup(scan);
      return;
    }

    // 取消 / 关闭 / 重新扫描 / 授予权限都放弃同一预览对象；不删除任何事件。
    await _control.dismissLegacyCleanupPreview(scan);
    if (!mounted) return;
    switch (decision) {
      case CalendarLegacyCleanupDecision.requestPermission:
        await _requestCalendarPermission();
      case CalendarLegacyCleanupDecision.rescan:
        await _runScan();
      case CalendarLegacyCleanupDecision.cleanup:
      case CalendarLegacyCleanupDecision.dismiss:
      case null:
        break;
    }
  }

  /// 用户明确要求后才申请日历权限（绝不在 build / 进入页面时自动申请）。
  Future<void> _requestCalendarPermission() async {
    final channel = defaultCalendarSyncChannel;
    bool granted;
    try {
      granted =
          await channel.checkPermissions() ||
          await channel.requestPermissions();
    } catch (_) {
      granted = false;
    }
    if (!mounted) return;
    if (!granted) {
      _showSnack('未获得日历读写权限，无法扫描遗留日程');
      return;
    }
    await _runScan();
  }

  /// 删除**用户已确认**的预览候选：只调 core 的精确三元组删除，失败如实报告。
  Future<void> _runCleanup(CalendarLegacyCleanupScan scan) async {
    if (mounted) setState(() => _progress = '正在清理遗留日程…');
    CalendarLegacyCleanupResult? result;
    try {
      result = await _control.cleanupLegacyOwnedEvents(scan);
    } on CalendarSyncException {
      result = null;
    } catch (_) {
      result = null;
    }
    final message = result == null
        ? '清理失败，请重新扫描后重试'
        : _cleanupResultMessage(result);
    if (!mounted) return;
    setState(() {
      _progress = null;
      _cleanupNote = message;
    });
    _showSnack(message);
  }

  String _cleanupResultMessage(CalendarLegacyCleanupResult result) {
    // 只有 core 权威判定 complete 才说「已清理」。
    if (result.complete) return '已清理遗留日程';
    if (result.failures.contains(CalendarLegacyCleanupFailure.invalidPreview)) {
      return '扫描已过期，请重新扫描';
    }
    final reasons = _describeCleanupFailures(result.failures);
    if (result.aborted) {
      return reasons.isEmpty ? '操作已中断，请重新扫描后重试' : '操作已中断（$reasons），请重新扫描后重试';
    }
    if (result.residualCount > 0) {
      final base =
          '已删除 ${result.deletedCount} 条，仍有 ${result.residualCount} 条未能确认';
      return reasons.isEmpty ? base : '$base（$reasons）';
    }
    // 残留未知为 0 但未完成：绝不显示「0 残留 / 全部清理」。
    final base = '清理未完成；仍有未能确认的范围';
    return reasons.isEmpty ? base : '$base（$reasons）';
  }

  static String _describeCleanupFailures(
    Set<CalendarLegacyCleanupFailure> failures,
  ) {
    final labels = <String>[];
    for (final failure in failures) {
      if (failure == CalendarLegacyCleanupFailure.invalidPreview ||
          failure == CalendarLegacyCleanupFailure.aborted) {
        continue;
      }
      final label = legacyCleanupFailureLabel(failure);
      if (!labels.contains(label)) labels.add(label);
    }
    return labels.join('、');
  }

  Future<_CalendarSyncTarget?> _askCalendarTarget() {
    return showGlassDialog<_CalendarSyncTarget>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
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
      _showSnack('存在未完成的清理，请先点击「扫描遗留日程」');
      return;
    }
    _showSnack(
      result.failure?.kind == CalendarSyncFailureKind.permissionDenied
          ? '未获得日历读写权限，同步未开启'
          : '开启失败，请稍后重试',
    );
  }

  void _showSnack(String message) => AppFeedback.toast(context, message);
}
