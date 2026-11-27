import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/auth/unified_auth.dart';
import '../../core/auth/zhengfang_auth.dart';
import '../../core/calendar/calendar_sync_channel.dart';
import '../../core/notification/app_notification_service.dart';
import '../../core/system_surface/campus_widget_bridge.dart';
import '../../core/system_surface/system_settings_launcher.dart';
import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/app_typography.dart';
import '../../shared/widgets/app_feedback.dart';
import '../../shared/widgets/app_icon_badge.dart';
import '../../shared/widgets/app_state_view_transition.dart';
import '../../shared/widgets/plain_list.dart';

/// 新手欢迎向导的「已完成」持久化标记。
///
/// 首启一次、跳过或点「开始使用」即置 true；不并入 `AppPreferencesStore`
/// （它只承载主题偏好，见 onboarding 任务决策）。测试环境经
/// `SharedPreferences.setMockInitialValues({})` 统一复位。
const String welcomeCompletedPrefsKey = 'welcome_completed';

/// 欢迎引导内动作落点：拿到当前全屏路由所在的导航栈，由调用方决定去向
/// （首启与「设置 → 重放」共用同一组目标，见 `app.dart` 默认注入）。
typedef WelcomeAction = void Function(NavigatorState navigator);

/// 全屏欢迎路由：不走 `showDialog`（设计棘轮只减不增），用普通 push 弹全屏
/// 页面，页面转场由全局 `pageTransitionsTheme` 统一接管。
class WelcomeFlow {
  WelcomeFlow._();

  /// 当前在途 / 已完成的欢迎路由；用于去重并让调用方能 await 关闭。
  static Future<void>? _activeFlow;

  /// 当前是否有欢迎路由在屏上（含正在关闭的）。
  static bool get isShowing => _activeFlow != null;

  /// 首次启动是否应当展示（未持久化完成标记即视为新用户）。
  static Future<bool> shouldShow() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(welcomeCompletedPrefsKey) != true;
  }

  /// 写入完成标记；跳过、点「开始使用」与系统返回都算「完成」。
  static Future<void> markCompleted() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(welcomeCompletedPrefsKey, true);
  }

  /// 打开欢迎页；已在屏上时直接复用在途 Future，不重复 push。
  ///
  /// 「设置 → 重放新手引导」已改走注册路由 `welcome`（routes.dart 组合层
  /// 持有 WelcomePage 与动作落点），本入口保留给需要当前导航栈的调用方；
  /// 首启见 [showOnNavigator]，直接把根导航传进来，避免依赖 overlay 内建
  /// 上下文。[onLoginShortcut] / [onNotificationsShortcut] /
  /// [onCalendarShortcut] / [onAiShortcut] 为可选的外部跳转落点。
  static Future<void> show(
    BuildContext context, {
    WelcomeAction? onLoginShortcut,
    WelcomeAction? onNotificationsShortcut,
    WelcomeAction? onCalendarShortcut,
    WelcomeAction? onAiShortcut,
  }) {
    return showOnNavigator(
      Navigator.of(context),
      onLoginShortcut: onLoginShortcut,
      onNotificationsShortcut: onNotificationsShortcut,
      onCalendarShortcut: onCalendarShortcut,
      onAiShortcut: onAiShortcut,
    );
  }

  /// 在指定导航栈上打开欢迎页（首启传根导航，可盖在 shell 与 dock 之上）。
  static Future<void> showOnNavigator(
    NavigatorState navigator, {
    WelcomeAction? onLoginShortcut,
    WelcomeAction? onNotificationsShortcut,
    WelcomeAction? onCalendarShortcut,
    WelcomeAction? onAiShortcut,
  }) {
    final existing = _activeFlow;
    if (existing != null) return existing;

    final route = MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => WelcomePage(
        onLoginShortcut: onLoginShortcut,
        onNotificationsShortcut: onNotificationsShortcut,
        onCalendarShortcut: onCalendarShortcut,
        onAiShortcut: onAiShortcut,
      ),
    );
    final flow = navigator
        .push(route)
        .then((_) => unawaited(markCompleted()))
        .whenComplete(() => _activeFlow = null);
    _activeFlow = flow;
    return flow;
  }

  /// 测试辅助：清掉在途引用（路由由测试自身 teardown 弹掉）。
  static void debugReset() {
    _activeFlow = null;
  }
}

/// 单页清单式迎新页：核心权限就地授权 + 桌面组件添加 + 账号/AI 快捷入口。
///
/// 使用独立 [ScaffoldMessenger] 包裹内部 [Scaffold]，避免根
/// `ScaffoldMessenger` 把启动代理提示 SnackBar 复制一份到本全屏页，同时让本页
/// 自己的 `AppFeedback.toastOn` 正常展示。
class WelcomePage extends StatefulWidget {
  const WelcomePage({
    super.key,
    this.onLoginShortcut,
    this.onNotificationsShortcut,
    this.onCalendarShortcut,
    this.onAiShortcut,
    this.checkNotificationsEnabled,
    this.requestNotificationPermission,
    this.calendarChannel,
    this.readBackgroundStatus,
    this.openSystemSettings,
    this.requestWidgetPin,
    this.isCampusLoggedIn,
    this.isAcademicLoggedIn,
  });

  /// 「校园账号登录」行点击落点：关闭迎新页后导航到「我的」页。
  final WelcomeAction? onLoginShortcut;

  /// 保留参数以兼容既有路由/调用方；当前页优先就地请求通知权限与系统设置。
  final WelcomeAction? onNotificationsShortcut;

  /// 保留参数以兼容既有路由/调用方；当前页优先就地请求日历读写权限。
  final WelcomeAction? onCalendarShortcut;

  /// 「AI 助手配置」行点击落点：关闭迎新页后导航到 AI 设置页。
  final WelcomeAction? onAiShortcut;

  /// 测试/注入用：查询系统通知权限是否开启。
  final Future<bool> Function()? checkNotificationsEnabled;

  /// 测试/注入用：就地请求系统通知权限。
  final Future<bool> Function()? requestNotificationPermission;

  /// 测试/注入用：日历同步通道（默认 [defaultCalendarSyncChannel]）。
  final CalendarSyncChannel? calendarChannel;

  /// 测试/注入用：查询后台运行与电池优化状态。
  final Future<SystemBackgroundStatus> Function()? readBackgroundStatus;

  /// 测试/注入用：打开系统设置页。
  final Future<SystemSettingsOpenResult> Function(SystemSettingsTarget target)?
  openSystemSettings;

  /// 测试/注入用：请求固定桌面课表组件。
  final Future<CampusWidgetPinResult> Function(CampusWidgetSize size)?
  requestWidgetPin;

  /// 测试/注入用：统一认证登录态。
  final bool Function()? isCampusLoggedIn;

  /// 测试/注入用：教务系统登录态。
  final bool Function()? isAcademicLoggedIn;

  @override
  State<WelcomePage> createState() => _WelcomePageState();
}

class _WelcomePageState extends State<WelcomePage> with WidgetsBindingObserver {
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  bool _loading = true;
  bool _notificationsEnabled = false;
  bool _calendarGranted = false;
  bool? _batteryIgnoring;
  bool _campusLoggedIn = false;
  bool _academicLoggedIn = false;

  bool _notificationBusy = false;
  bool _calendarBusy = false;
  bool _widgetBusy = false;

  int _refreshGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.isCampusLoggedIn == null) {
      UnifiedAuthService.instance.addListener(_onAuthChanged);
    }
    if (widget.isAcademicLoggedIn == null) {
      ZhengfangAuth.instance.addListener(_onAuthChanged);
    }
    _syncAccountStatus(notify: false);
    unawaited(_refreshStatus());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (widget.isCampusLoggedIn == null) {
      UnifiedAuthService.instance.removeListener(_onAuthChanged);
    }
    if (widget.isAcademicLoggedIn == null) {
      ZhengfangAuth.instance.removeListener(_onAuthChanged);
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从系统权限或电池优化设置返回后立即重查真实状态。
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshStatus());
    }
  }

  void _onAuthChanged() {
    if (!mounted) return;
    _syncAccountStatus(notify: true);
  }

  void _syncAccountStatus({required bool notify}) {
    final campus =
        widget.isCampusLoggedIn?.call() ??
        UnifiedAuthService.instance.isLoggedIn;
    final academic =
        widget.isAcademicLoggedIn?.call() ?? ZhengfangAuth.instance.isLoggedIn;
    if (!notify) {
      _campusLoggedIn = campus;
      _academicLoggedIn = academic;
      return;
    }
    if (_campusLoggedIn == campus && _academicLoggedIn == academic) return;
    setState(() {
      _campusLoggedIn = campus;
      _academicLoggedIn = academic;
    });
  }

  CalendarSyncChannel get _calendarChannel =>
      widget.calendarChannel ?? defaultCalendarSyncChannel;

  Future<T> _safeCall<T>(Future<T> Function() action, T fallback) async {
    try {
      return await action();
    } catch (_) {
      return fallback;
    }
  }

  Future<bool> _queryNotificationsEnabled() {
    final checker =
        widget.checkNotificationsEnabled ??
        AppNotificationService.instance.areNotificationsEnabled;
    return _safeCall(checker, false);
  }

  Future<bool> _queryCalendarPermission() {
    return _safeCall(_calendarChannel.checkPermissions, false);
  }

  Future<bool?> _queryBatteryIgnoring() async {
    final reader =
        widget.readBackgroundStatus ??
        SystemSettingsLauncher.instance.getStatus;
    final status = await _safeCall(reader, SystemBackgroundStatus.unknown);
    if (!status.available) return null;
    return status.ignoringBatteryOptimizations;
  }

  Future<void> _refreshStatus() async {
    final generation = ++_refreshGeneration;
    final results = await Future.wait<Object?>([
      _queryNotificationsEnabled(),
      _queryCalendarPermission(),
      _queryBatteryIgnoring(),
    ]);
    if (!mounted || generation != _refreshGeneration) return;
    setState(() {
      _notificationsEnabled = results[0]! as bool;
      _calendarGranted = results[1]! as bool;
      _batteryIgnoring = results[2] as bool?;
      _campusLoggedIn =
          widget.isCampusLoggedIn?.call() ??
          UnifiedAuthService.instance.isLoggedIn;
      _academicLoggedIn =
          widget.isAcademicLoggedIn?.call() ??
          ZhengfangAuth.instance.isLoggedIn;
      _loading = false;
    });
  }

  Future<bool> _finish() => Navigator.of(context).maybePop();

  /// 先关闭迎新页，再在原导航栈上打开外部目标页。
  Future<void> _runAction(WelcomeAction action) async {
    final navigator = Navigator.of(context);
    await _finish();
    if (!navigator.mounted) return;
    action(navigator);
  }

  void _showToast(
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    final messenger = _messengerKey.currentState;
    if (messenger == null) return;
    AppFeedback.toastOn(
      messenger,
      message,
      actionLabel: actionLabel,
      onAction: onAction,
    );
  }

  Future<void> _openSettingsWithFallback(
    SystemSettingsTarget target, {
    required String targetName,
  }) async {
    final opener =
        widget.openSystemSettings ??
        (t) => SystemSettingsLauncher.instance.open(t);
    final result = await _safeCall(
      () => opener(target),
      SystemSettingsOpenResult.unavailable,
    );
    if (!mounted) return;
    if (result == SystemSettingsOpenResult.target ||
        (result == SystemSettingsOpenResult.appDetails &&
            target == SystemSettingsTarget.appDetails)) {
      return;
    }
    final message = switch (result) {
      SystemSettingsOpenResult.target => null,
      SystemSettingsOpenResult.appDetails => '未能直达$targetName，已打开应用详情页，请手动调整',
      SystemSettingsOpenResult.settings => '未能直达$targetName，已打开系统设置首页，请手动查找',
      SystemSettingsOpenResult.unavailable => '未能打开系统设置，请手动前往系统「应用管理」调整',
    };
    if (message != null) _showToast(message);
  }

  Future<void> _handleNotificationsTap() async {
    if (_notificationBusy) return;
    if (_notificationsEnabled) {
      await _openSettingsWithFallback(
        SystemSettingsTarget.notifications,
        targetName: '通知设置',
      );
      return;
    }
    _notificationBusy = true;
    try {
      final requester =
          widget.requestNotificationPermission ??
          AppNotificationService.instance.requestPermission;
      final requested = await _safeCall(requester, false);
      final enabledNow = await _queryNotificationsEnabled();
      final granted = requested || enabledNow;
      if (!mounted) return;
      setState(() => _notificationsEnabled = granted);
      if (!granted) {
        await _openSettingsWithFallback(
          SystemSettingsTarget.notifications,
          targetName: '通知设置',
        );
      }
    } finally {
      _notificationBusy = false;
    }
  }

  Future<void> _handleCalendarTap() async {
    if (_calendarBusy) return;
    if (_calendarGranted) {
      _showToast('日历同步权限已允许');
      return;
    }
    _calendarBusy = true;
    try {
      final requested = await _safeCall(
        _calendarChannel.requestPermissions,
        false,
      );
      final checked = await _queryCalendarPermission();
      final granted = requested || checked;
      if (!mounted) return;
      setState(() => _calendarGranted = granted);
      if (!granted) {
        _showToast(
          '未获得日历权限，可前往系统应用设置手动开启',
          actionLabel: '去设置',
          onAction: () => unawaited(
            _openSettingsWithFallback(
              SystemSettingsTarget.appDetails,
              targetName: '应用详情页',
            ),
          ),
        );
      }
    } finally {
      _calendarBusy = false;
    }
  }

  Future<void> _handleBatteryTap() => _openSettingsWithFallback(
    SystemSettingsTarget.batteryOptimization,
    targetName: '电池优化设置',
  );

  Future<void> _handlePinWidgetTap() async {
    if (_widgetBusy) return;
    _widgetBusy = true;
    try {
      final requester =
          widget.requestWidgetPin ?? CampusWidgetBridge.instance.requestPin;
      final result = await _safeCall(
        () => requester(CampusWidgetSize.medium),
        CampusWidgetPinResult.error,
      );
      if (!mounted) return;
      final message = switch (result) {
        CampusWidgetPinResult.requested => '已请求添加，请在桌面确认',
        CampusWidgetPinResult.unsupported => '不支持一键添加，请长按桌面手动添加',
        CampusWidgetPinResult.rejected =>
          '桌面拒绝了添加请求；请在权限设置中允许「桌面快捷方式」或长按桌面手动添加',
        CampusWidgetPinResult.error => '添加失败，请长按桌面手动添加',
      };
      _showToast(message);
    } finally {
      _widgetBusy = false;
    }
  }

  bool get _allAccountsLoggedIn => _campusLoggedIn && _academicLoggedIn;

  String get _accountStatusValue {
    if (_allAccountsLoggedIn) return '已登录';
    if (_campusLoggedIn || _academicLoggedIn) return '部分登录';
    return '未登录';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = context.appText;

    return ScaffoldMessenger(
      key: _messengerKey,
      child: Scaffold(
        backgroundColor: cs.surface,
        body: Stack(
          children: [
            // 微弱径向光晕：外壳层的克制氛围，只落在底色上。
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: const Alignment(0.6, -0.7),
                      radius: 0.9,
                      colors: [
                        cs.primary.withValues(alpha: 0.08),
                        cs.surface.withValues(alpha: 0),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // 顶部栏：仅保留右上角「跳过」，不设死高度以适配大字号缩放。
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          AppSpacing.listGutter,
                          AppSpacing.xs,
                          AppSpacing.md,
                          0,
                        ),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 48),
                          child: Row(
                            children: [
                              const Spacer(),
                              TextButton(
                                onPressed: _finish,
                                child: const Text('跳过'),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Expanded(
                        child: AppStateViewTransition(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.fromLTRB(
                              AppSpacing.listGutter,
                              AppSpacing.sm,
                              AppSpacing.listGutter,
                              AppSpacing.xl,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                AppIconBadge(
                                  icon: Icons.school_outlined,
                                  accentColor: cs.primary,
                                  size: AppIconBadgeSize.large,
                                ),
                                const SizedBox(height: AppSpacing.md),
                                Semantics(
                                  header: true,
                                  child: Wrap(
                                    crossAxisAlignment: WrapCrossAlignment.end,
                                    spacing: AppSpacing.sm,
                                    runSpacing: AppSpacing.xs,
                                    children: [
                                      Text('欢迎使用嘉兴大学', style: text.title),
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          bottom: 3,
                                        ),
                                        child: Text(
                                          'CampusHub',
                                          style: text.label.copyWith(
                                            color: cs.onSurfaceVariant,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: AppSpacing.sm),
                                Text(
                                  '按需完成基础授权与配置，即可顺畅使用课表、提醒与桌面组件',
                                  style: text.body.copyWith(
                                    color: cs.onSurfaceVariant,
                                  ),
                                ),
                                const SizedBox(height: AppSpacing.xl),
                                const PlainSectionHeader('核心权限'),
                                PlainListGroup(
                                  children: [
                                    PlainListRow(
                                      leading: AppIconBadge(
                                        icon: _notificationsEnabled
                                            ? Icons
                                                  .notifications_active_outlined
                                            : Icons.notifications_outlined,
                                        accentColor: _notificationsEnabled
                                            ? cs.secondary
                                            : cs.primary,
                                        semantic: _notificationsEnabled,
                                        size: AppIconBadgeSize.small,
                                      ),
                                      title: '通知提醒',
                                      subtitle: '接收课前提醒、成绩与校务公告',
                                      value: _loading
                                          ? '检查中…'
                                          : (_notificationsEnabled
                                                ? '已开启'
                                                : '未开启'),
                                      valueKey: const Key(
                                        'welcome_notification_status',
                                      ),
                                      emphasizeValue:
                                          !_loading && !_notificationsEnabled,
                                      onTap: _handleNotificationsTap,
                                    ),
                                    PlainListRow(
                                      leading: AppIconBadge(
                                        icon: _calendarGranted
                                            ? Icons.event_available_outlined
                                            : Icons.calendar_month_outlined,
                                        accentColor: _calendarGranted
                                            ? cs.secondary
                                            : cs.primary,
                                        semantic: _calendarGranted,
                                        size: AppIconBadgeSize.small,
                                      ),
                                      title: '日历同步权限',
                                      subtitle: '把课表写入系统日历并自动提醒',
                                      value: _loading
                                          ? '检查中…'
                                          : (_calendarGranted ? '已允许' : '未开启'),
                                      valueKey: const Key(
                                        'welcome_calendar_status',
                                      ),
                                      emphasizeValue:
                                          !_loading && !_calendarGranted,
                                      onTap: _handleCalendarTap,
                                    ),
                                    PlainListRow(
                                      leading: AppIconBadge(
                                        icon: _batteryIgnoring == true
                                            ? Icons.verified_user_outlined
                                            : Icons.battery_saver_outlined,
                                        accentColor: _batteryIgnoring == true
                                            ? cs.secondary
                                            : cs.primary,
                                        semantic: _batteryIgnoring == true,
                                        size: AppIconBadgeSize.small,
                                      ),
                                      title: '后台保活',
                                      subtitle: '允许应用在后台更新课表与桌面组件',
                                      value: _loading
                                          ? '检查中…'
                                          : switch (_batteryIgnoring) {
                                              true => '无限制',
                                              false => '受系统限制',
                                              null => '未知',
                                            },
                                      valueKey: const Key(
                                        'welcome_battery_status',
                                      ),
                                      emphasizeValue:
                                          !_loading &&
                                          _batteryIgnoring == false,
                                      onTap: _handleBatteryTap,
                                    ),
                                  ],
                                ),
                                const SizedBox(height: AppSpacing.listGroupGap),
                                const PlainSectionHeader('桌面组件与快捷功能'),
                                PlainListGroup(
                                  children: [
                                    PlainListRow(
                                      leading: AppIconBadge(
                                        icon: Icons.widgets_outlined,
                                        accentColor: cs.primary,
                                        size: AppIconBadgeSize.small,
                                      ),
                                      title: '添加桌面课表组件',
                                      subtitle: '在桌面直接查看今日课表与下一节课',
                                      onTap: _handlePinWidgetTap,
                                    ),
                                  ],
                                ),
                                const SizedBox(height: AppSpacing.listGroupGap),
                                const PlainSectionHeader('账号与进阶'),
                                PlainListGroup(
                                  children: [
                                    PlainListRow(
                                      leading: AppIconBadge(
                                        icon: _allAccountsLoggedIn
                                            ? Icons.verified_outlined
                                            : Icons.badge_outlined,
                                        accentColor: _allAccountsLoggedIn
                                            ? cs.secondary
                                            : cs.primary,
                                        semantic: _allAccountsLoggedIn,
                                        size: AppIconBadgeSize.small,
                                      ),
                                      title: '校园账号登录',
                                      subtitle: '去「我的」页登录教务与统一认证',
                                      value: _accountStatusValue,
                                      valueKey: const Key(
                                        'welcome_account_status',
                                      ),
                                      emphasizeValue: !_allAccountsLoggedIn,
                                      onTap: widget.onLoginShortcut == null
                                          ? null
                                          : () => _runAction(
                                              widget.onLoginShortcut!,
                                            ),
                                    ),
                                    PlainListRow(
                                      leading: AppIconBadge(
                                        icon: Icons.auto_awesome_outlined,
                                        accentColor: cs.tertiary,
                                        size: AppIconBadgeSize.small,
                                      ),
                                      title: 'AI 助手配置',
                                      subtitle: '课表问答与成绩解读（可选）',
                                      onTap: widget.onAiShortcut == null
                                          ? null
                                          : () => _runAction(
                                              widget.onAiShortcut!,
                                            ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: cs.surface,
                          border: Border(
                            top: BorderSide(
                              color: cs.outlineVariant.withValues(alpha: 0.35),
                              width: 0.5,
                            ),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(
                            AppSpacing.listGutter,
                            AppSpacing.md,
                            AppSpacing.listGutter,
                            AppSpacing.lg,
                          ),
                          child: SizedBox(
                            width: double.infinity,
                            child: FilledButton(
                              onPressed: _finish,
                              child: const Text('开始使用'),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
