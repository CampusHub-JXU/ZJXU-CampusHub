import 'dart:async';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../../core/actions/campus_action_ids.dart';
import '../../core/shortcut/app_shortcut_service.dart';
import '../../core/system_surface/campus_widget_bridge.dart';
import '../../core/system_surface/widget_refresh_state.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_feedback.dart';
import '../../shared/widgets/plain_list.dart';

/// 设置 → 桌面组件（PRD §42，契约 `docs/desktop-widget-v2.md` §6）。
///
/// 展示桌面小组件预览与放置数量、最近同步/刷新记录，以及今日课表桌面快捷方式。
/// 从桌面返回（resumed）时重新查询真实放置数量与同步状态。
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
  WidgetRefreshRecord? _refresh;

  /// 原生渲染的各尺寸组件预览 PNG；通道缺失 / 渲染失败时对应项缺省。
  Map<CampusWidgetSize, Uint8List> _previews = const {};

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
    // 从桌面返回后重新查询真实放置状态，不沿用旧值。
    if (state == AppLifecycleState.resumed) unawaited(_refreshStatus());
  }

  Future<void> _refreshStatus() async {
    final generation = ++_generation;
    final results = await Future.wait<Object?>([
      CampusWidgetBridge.instance.getStatus(),
      (widget.refreshRecordLoader ?? WidgetRefreshState.instance.load)()
          .catchError((_) => null),
    ]);
    if (!mounted || generation != _generation) return;
    setState(() {
      _widgets = results[0]! as CampusWidgetStatus;
      _refresh = results[1] as WidgetRefreshRecord?;
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

  DateTime _now() => widget.now?.call() ?? DateTime.now();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppAppBar(title: const Text('桌面组件'), leading: const BackButton()),
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
          const SizedBox(height: kPlainListGroupGap),
          const PlainSectionHeader('快捷方式'),
          PlainListGroup(
            children: [
              PlainListRow(
                title: '今日课表快捷方式',
                onTap: () => _addShortcut(context),
              ),
            ],
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
