import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/calendar/calendar_sync_channel.dart';
import '../../core/notification/app_notification_service.dart';
import '../../core/shortcut/app_shortcut_service.dart';
import '../../core/system_surface/system_settings_launcher.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_feedback.dart';
import '../../shared/widgets/plain_list.dart';

/// 设置 → 权限与后台。
///
/// 状态驱动：每行只显示标题 + 真实状态（未满足的项用强调色）。
/// 状态全部只读查询，**打开设置页不代表已授权**；从系统设置返回（resumed）时重新查询。
/// 不提供误导性的「一键全部开启」。
class PermissionsSettingsPage extends StatefulWidget {
  const PermissionsSettingsPage({super.key, this.calendarChannel});

  /// 测试可注入日历通道替身；null 时使用 [defaultCalendarSyncChannel]。
  final CalendarSyncChannel? calendarChannel;

  @override
  State<PermissionsSettingsPage> createState() =>
      _PermissionsSettingsPageState();
}

class _PermissionsSettingsPageState extends State<PermissionsSettingsPage>
    with WidgetsBindingObserver {
  bool _loading = true;
  bool _requestingCalendar = false;
  SystemBackgroundStatus _system = SystemBackgroundStatus.unknown;

  /// 通知权限真实查询结果；null = 查询失败，状态未知（不谎称已开启）。
  bool? _notificationsEnabled;

  /// 日历读写权限真实查询结果；null = 查询失败，状态未知（不谎称已允许）。
  bool? _calendarPermissionsEnabled;

  /// 只采用最新一轮查询的结果，防止慢的旧查询覆盖新状态。
  int _generation = 0;

  CalendarSyncChannel get _calendarChannel =>
      widget.calendarChannel ?? defaultCalendarSyncChannel;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refreshStatus());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从系统设置返回后重新查询真实状态，不沿用旧值。
    if (state == AppLifecycleState.resumed) unawaited(_refreshStatus());
  }

  Future<void> _refreshStatus() async {
    final generation = ++_generation;
    final results = await Future.wait<Object?>([
      SystemSettingsLauncher.instance.getStatus(),
      _queryNotifications(),
      _queryCalendarPermissions(),
    ]);
    if (!mounted || generation != _generation) return;
    final system = results[0]! as SystemBackgroundStatus;
    setState(() {
      _system = system;
      _notificationsEnabled =
          results[1] as bool? ?? system.notificationsEnabled;
      _calendarPermissionsEnabled = results[2] as bool?;
      _loading = false;
    });
  }

  Future<bool?> _queryNotifications() async {
    try {
      return await AppNotificationService.instance.areNotificationsEnabled();
    } catch (_) {
      return null;
    }
  }

  Future<bool?> _queryCalendarPermissions() async {
    try {
      return await _calendarChannel.checkPermissions();
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppAppBar(
        title: const Text('权限与后台'),
        leading: const BackButton(),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          kPlainListGutter,
          16,
          kPlainListGutter,
          32,
        ),
        children: [
          const PlainSectionHeader('应用权限'),
          PlainListGroup(children: _permissionRows(context)),
          const SizedBox(height: kPlainListGroupGap),
          const PlainSectionHeader('后台运行'),
          PlainListGroup(children: _backgroundRows(context)),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 应用权限

  List<Widget> _permissionRows(BuildContext context) {
    final calendar = _calendarPermissionsEnabled;
    return [
      PlainListRow(
        title: '通知权限',
        value: _loading
            ? '检查中…'
            : switch (_notificationsEnabled) {
                true => '已开启',
                false => '未开启',
                null => '未知',
              },
        emphasizeValue: !_loading && _notificationsEnabled == false,
        onTap: () => _openNotificationSettings(context),
      ),
      PlainListRow(
        title: '日历读写权限',
        value: _loading
            ? '检查中…'
            : switch (calendar) {
                true => '已允许',
                false => '未允许',
                null => '未知',
              },
        emphasizeValue: !_loading && calendar == false,
        onTap: !_loading && calendar == false
            ? () => _requestCalendarPermissions(context)
            : null,
      ),
      PlainListRow(
        title: '桌面快捷方式权限',
        subtitle: '部分系统默认禁止创建，需手动允许',
        onTap: () => _openShortcutSettings(context),
      ),
    ];
  }

  // ------------------------------------------------------------ 后台运行

  List<Widget> _backgroundRows(BuildContext context) {
    final system = _system;
    final exact = system.exactAlarmsAllowed;
    final exactNotApplicable = system.available && exact == null;
    final battery = system.ignoringBatteryOptimizations;
    return [
      PlainListRow(
        title: '精确闹钟',
        value: _loading
            ? '检查中…'
            : !system.available
            ? '未知'
            : switch (exact) {
                true => '已允许',
                false => '未允许',
                null => '无需设置',
              },
        emphasizeValue: !_loading && exact == false,
        onTap: exactNotApplicable
            ? null
            : () => _openSystemSettings(
                context,
                SystemSettingsTarget.exactAlarms,
              ),
      ),
      PlainListRow(
        title: '电池优化',
        value: _loading
            ? '检查中…'
            : switch (battery) {
                true => '无限制',
                false => '受系统限制',
                null => system.available ? '无需设置' : '未知',
              },
        emphasizeValue: !_loading && battery == false,
        onTap: () => _openSystemSettings(
          context,
          SystemSettingsTarget.batteryOptimization,
        ),
      ),
      if (system.isXiaomiFamily)
        PlainListRow(
          title: '自启动',
          value: '无法检测',
          onTap: () =>
              _openSystemSettings(context, SystemSettingsTarget.autostart),
        ),
      PlainListRow(
        title: '系统应用信息',
        onTap: () =>
            _openSystemSettings(context, SystemSettingsTarget.appDetails),
      ),
    ];
  }

  // ------------------------------------------------------------- 动作

  Future<void> _requestCalendarPermissions(BuildContext context) async {
    if (_requestingCalendar) return;
    _requestingCalendar = true;
    var granted = false;
    var requestFailed = false;
    try {
      granted = await _calendarChannel.requestPermissions();
    } catch (_) {
      requestFailed = true;
    } finally {
      _requestingCalendar = false;
    }
    await _refreshStatus();
    if (!context.mounted) return;
    if (!granted && !requestFailed && _calendarPermissionsEnabled != true) {
      AppFeedback.toast(
        context,
        '未获得日历读写权限；若已设为不再询问，请在「系统应用信息」中手动开启',
        actionLabel: '去设置',
        onAction: () => unawaited(
          _openSystemSettings(context, SystemSettingsTarget.appDetails),
        ),
      );
    }
  }

  Future<void> _openShortcutSettings(BuildContext context) async {
    final opened = await AppShortcutService.instance
        .openShortcutPermissionSettings();
    if (!context.mounted) return;
    if (!opened) _toast(context, '未能打开系统设置，请手动前往系统应用管理');
  }

  Future<void> _openNotificationSettings(BuildContext context) async {
    final result = await SystemSettingsLauncher.instance.open(
      SystemSettingsTarget.notifications,
    );
    if (!context.mounted) return;
    // 命中目标页不提示，返回页面时由生命周期回调刷新真实状态。
    final message = switch (result) {
      SystemSettingsOpenResult.target => null,
      SystemSettingsOpenResult.appDetails => '未能直达通知设置，已打开应用详情页，请在「通知」中手动开启',
      SystemSettingsOpenResult.settings => '未能直达通知设置，已打开系统设置首页，请在「通知管理」中手动开启',
      SystemSettingsOpenResult.unavailable => '未能打开系统设置，请手动前往系统「应用管理」调整',
    };
    if (message != null) _toast(context, message);
  }

  /// 跳转系统设置页；命中目标页不打扰，降级 / 失败时明确说明实际打开的页面。
  Future<void> _openSystemSettings(
    BuildContext context,
    SystemSettingsTarget target,
  ) async {
    final result = await SystemSettingsLauncher.instance.open(target);
    if (!context.mounted) return;
    final message = _systemSettingsFallbackMessage(target, result);
    if (message != null) _toast(context, message);
  }

  /// 打开设置页失败 / 降级时的提示；命中目标页返回 null。
  ///
  /// 打开成功不代表权限已授予，这里只反馈真实打开的页面。
  static String? _systemSettingsFallbackMessage(
    SystemSettingsTarget target,
    SystemSettingsOpenResult result,
  ) {
    // 应用详情页本身是「系统应用信息」行的目标页，请求它时按成功处理。
    if (result == SystemSettingsOpenResult.appDetails &&
        target == SystemSettingsTarget.appDetails) {
      return null;
    }
    return switch (result) {
      SystemSettingsOpenResult.target => null,
      SystemSettingsOpenResult.appDetails => '未能直达该设置项，已打开应用详情页，请在系统中手动查找',
      SystemSettingsOpenResult.settings => '未能直达该设置项，已打开系统设置首页，请手动查找',
      SystemSettingsOpenResult.unavailable => '未能打开系统设置，请手动前往系统「应用管理」调整',
    };
  }
}

void _toast(BuildContext context, String message) =>
    AppFeedback.toast(context, message);
