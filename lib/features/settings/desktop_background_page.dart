import 'dart:async';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../../core/actions/campus_action_ids.dart';
import '../../core/notification/app_notification_service.dart';
import '../../core/shortcut/app_shortcut_service.dart';
import '../../core/system_surface/campus_widget_bridge.dart';
import '../../core/system_surface/system_settings_launcher.dart';
import '../../core/system_surface/widget_refresh_state.dart';
import '../../core/theme/app_typography.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_feedback.dart';
import '../../shared/widgets/plain_list.dart';

/// 设置 → 桌面与后台（PRD §42，契约 `docs/desktop-widget-v2.md` §6）。
///
/// 状态驱动：每行只显示标题 + 真实状态（未满足的项用强调色）。
/// 状态全部只读查询，**打开设置页不代表已授权**；从系统设置返回（resumed）时重新查询。
/// 不提供误导性的「一键全部开启」。
class DesktopBackgroundPage extends StatefulWidget {
  const DesktopBackgroundPage({super.key, this.now, this.refreshRecordLoader});

  final Future<WidgetRefreshRecord?> Function()? refreshRecordLoader;

  /// 测试用时钟；null 用 [DateTime.now]。
  final DateTime Function()? now;

  @override
  State<DesktopBackgroundPage> createState() => _DesktopBackgroundPageState();
}

class _DesktopBackgroundPageState extends State<DesktopBackgroundPage>
    with WidgetsBindingObserver {
  bool _loading = true;
  CampusWidgetStatus _widgets = CampusWidgetStatus.unknown;
  SystemBackgroundStatus _system = SystemBackgroundStatus.unknown;
  WidgetRefreshRecord? _refresh;

  /// 原生渲染的各尺寸组件预览 PNG；通道缺失 / 渲染失败时对应项缺省。
  Map<CampusWidgetSize, Uint8List> _previews = const {};

  /// 通知权限真实查询结果；null = 查询失败，状态未知（不谎称已开启）。
  bool? _notificationsEnabled;

  /// 只采用最新一轮查询的结果，防止慢的旧查询覆盖新状态。
  int _generation = 0;

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
    // 从系统设置 / 桌面返回后重新查询真实状态，不沿用旧值。
    if (state == AppLifecycleState.resumed) unawaited(_refreshStatus());
  }

  Future<void> _refreshStatus() async {
    final generation = ++_generation;
    final results = await Future.wait<Object?>([
      CampusWidgetBridge.instance.getStatus(),
      SystemSettingsLauncher.instance.getStatus(),
      (widget.refreshRecordLoader ?? WidgetRefreshState.instance.load)()
          .catchError((_) => null),
      _queryNotifications(),
    ]);
    if (!mounted || generation != _generation) return;
    final system = results[1]! as SystemBackgroundStatus;
    setState(() {
      _widgets = results[0]! as CampusWidgetStatus;
      _system = system;
      _refresh = results[2] as WidgetRefreshRecord?;
      _notificationsEnabled =
          results[3] as bool? ?? system.notificationsEnabled;
      _loading = false;
    });
    unawaited(_loadPreviews());
  }

  /// 预览位图按卡内展示宽（物理像素）栅格化，字号保持真实 sp 规格；
  /// 与状态查询解耦：渲染失败 / 通道缺失只少一块图，不影响页面。
  Future<void> _loadPreviews() async {
    final generation = _generation;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    // PlainListGroup 内边距：卡片两侧 kPlainListGutter + 组内 padding 16×2。
    final contentWidth =
        MediaQuery.sizeOf(context).width - kPlainListGutter * 2 - 32;
    final previews = <CampusWidgetSize, Uint8List>{};
    for (final size in CampusWidgetSize.values) {
      final widthDp = size == CampusWidgetSize.small
          ? contentWidth * 0.5
          : contentWidth;
      final png = await CampusWidgetBridge.instance.getPreview(
        size,
        widthPx: (widthDp * dpr).round(),
      );
      if (png != null) previews[size] = png;
    }
    if (!mounted || generation != _generation) return;
    setState(() => _previews = previews);
  }

  Future<bool?> _queryNotifications() async {
    try {
      return await AppNotificationService.instance.areNotificationsEnabled();
    } catch (_) {
      return null;
    }
  }

  DateTime _now() => widget.now?.call() ?? DateTime.now();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppAppBar(
        title: const Text('桌面与后台'),
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
          const PlainSectionHeader('桌面组件'),
          PlainListGroup(children: _widgetRows(context)),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              '点按对应行请求添加到桌面；预览为示意数据，组件外观随系统深/浅色换色。',
              style: context.appText.meta,
            ),
          ),
          const SizedBox(height: kPlainListGroupGap),
          const PlainSectionHeader('快捷方式'),
          PlainListGroup(
            children: [
              PlainListRow(
                title: '今日课表快捷方式',
                subtitle: '固定到桌面，一键打开今日课表',
                onTap: () => _addShortcut(context),
              ),
              PlainListRow(
                title: '桌面快捷方式权限',
                subtitle: '部分系统默认禁止创建，需手动允许',
                onTap: () => _openShortcutSettings(context),
              ),
            ],
          ),
          const SizedBox(height: kPlainListGroupGap),
          const PlainSectionHeader('后台运行'),
          PlainListGroup(children: _backgroundRows(context)),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text('点按行前往系统设置，返回后自动刷新状态。', style: context.appText.meta),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 桌面组件

  List<Widget> _widgetRows(BuildContext context) {
    final refresh = _refresh;
    return [
      for (final size in CampusWidgetSize.values) ...[
        _WidgetPreview(size: size, png: _previews[size]),
        PlainListRow(
          title: '${size.sizeLabel} ${size.contentLabel}',
          value: _installedText(size),
          onTap: () => _addWidget(context, size),
        ),
      ],
      PlainListRow(
        title: '上次同步',
        value: _loading
            ? '检查中…'
            : _relativeTime(_widgets.lastSnapshotAt) ?? '尚未同步',
      ),
      if (refresh != null)
        PlainListRow(
          title: '上次后台刷新',
          value:
              '${_relativeTime(refresh.lastAttemptAt)} · ${_outcomeText(refresh.lastOutcome)}',
          emphasizeValue:
              refresh.lastOutcome != WidgetRefreshOutcome.ok &&
              refresh.lastOutcome != WidgetRefreshOutcome.skippedForeground,
        ),
    ];
  }

  String? _installedText(CampusWidgetSize size) {
    if (_loading) return null;
    final count = _widgets.installedCount(size);
    if (count > 0) return '已放置 $count 个';
    // 通道不可用时数量未知，不显示「未放置」以免误导。
    return identical(_widgets, CampusWidgetStatus.unknown) ? null : '未放置';
  }

  static String _outcomeText(WidgetRefreshOutcome outcome) => switch (outcome) {
    WidgetRefreshOutcome.ok => '成功',
    WidgetRefreshOutcome.partial => '部分成功',
    WidgetRefreshOutcome.authFailed => '登录失效',
    WidgetRefreshOutcome.offline => '无网络',
    WidgetRefreshOutcome.error => '失败',
    WidgetRefreshOutcome.skippedForeground => '前台已在刷新',
  };

  /// 「刚刚」/「N 分钟前」/「N 小时前」/「M月d日 HH:mm」；null 返回 null。
  String? _relativeTime(DateTime? at) {
    if (at == null) return null;
    final diff = _now().difference(at);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    if (diff.inHours < 24) return '${diff.inHours} 小时前';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${at.month}月${at.day}日 ${two(at.hour)}:${two(at.minute)}';
  }

  // ------------------------------------------------------------ 后台运行

  List<Widget> _backgroundRows(BuildContext context) {
    final system = _system;
    final exact = system.exactAlarmsAllowed;
    final exactNotApplicable = system.available && exact == null;
    final battery = system.ignoringBatteryOptimizations;
    return [
      PlainListRow(
        title: '通知',
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

  /// 请求把组件固定到桌面。放到哪一页 / 哪个空位由桌面决定，App 无法控制，
  /// 所以只如实反馈「请求已发出」，不承诺落点。
  Future<void> _addWidget(BuildContext context, CampusWidgetSize size) async {
    final result = await CampusWidgetBridge.instance.requestPin(size);
    if (!context.mounted) return;
    switch (result) {
      case CampusWidgetPinResult.requested:
        _toast(context, '已请求添加，请在桌面确认');
      case CampusWidgetPinResult.unsupported:
        _toast(context, '当前桌面不支持一键添加，请长按桌面 → 小组件 → 嘉兴大学 手动添加');
      case CampusWidgetPinResult.rejected:
        AppFeedback.toast(
          context,
          '桌面拒绝了添加请求；如为小米/HyperOS，可在权限设置中允许「桌面快捷方式」后重试',
          actionLabel: '去设置',
          onAction: () => unawaited(_openShortcutSettings(context)),
        );
      case CampusWidgetPinResult.error:
        _toast(context, '添加失败，请长按桌面 → 小组件 → 嘉兴大学 手动添加');
    }
  }

  Future<void> _addShortcut(BuildContext context) async {
    final result = await AppShortcutService.instance.requestPinnedShortcut(
      CampusActionIds.scheduleToday,
      title: '今日课表',
    );
    if (!context.mounted) return;
    _toast(context, result.message);
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

/// 原生 previewLayout 位图预览，按真实桌面格子占位：2×2 半宽方形，
/// 4×2 / 4×4 全宽。位图缺失（通道不可用 / 渲染失败）时整块隐藏。
class _WidgetPreview extends StatelessWidget {
  const _WidgetPreview({required this.size, required this.png});

  final CampusWidgetSize size;
  final Uint8List? png;

  /// 与 `appwidget-provider` minWidth/minHeight 同比例的展示宽高比。
  static const _aspect = <CampusWidgetSize, double>{
    CampusWidgetSize.small: 1,
    CampusWidgetSize.medium: 250 / 110,
    CampusWidgetSize.large: 1,
  };

  @override
  Widget build(BuildContext context) {
    final png = this.png;
    if (png == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: FractionallySizedBox(
        widthFactor: size == CampusWidgetSize.small ? 0.5 : 1,
        alignment: Alignment.centerLeft,
        child: Semantics(
          image: true,
          label: '${size.contentLabel}组件预览',
          child: ClipRSuperellipse(
            borderRadius: BorderRadius.circular(20),
            child: AspectRatio(
              aspectRatio: _aspect[size]!,
              child: Image.memory(
                png,
                key: Key('desktop_widget_preview_${size.code}'),
                fit: BoxFit.fill,
                gaplessPlayback: true,
                filterQuality: FilterQuality.medium,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
