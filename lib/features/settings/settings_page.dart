import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/auth/zhengfang_auth.dart';
import '../../core/cache/json_cache_store.dart';
import '../../core/calendar/calendar_reminder_settings.dart';
import '../../core/calendar/calendar_sync_channel.dart';
import '../../core/calendar/calendar_sync_control.dart';
import '../../core/calendar/calendar_sync_models.dart';
import '../../core/semester/current_term_resolver.dart';
import '../../core/semester/schedule_term_context.dart';
import '../../core/semester/semester_calendar.dart';
import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/app_preferences_controller.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/page_transition_activity.dart';
import '../../core/theme/personalization_controller.dart';
import '../../core/update/apk_download_route.dart';
import '../../core/update/apk_update_controller.dart';
import '../../core/update/update_checker.dart';
import '../../core/update/update_model.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_dropdown.dart';
import '../../shared/widgets/app_feedback.dart';
import '../../shared/widgets/app_icon_badge.dart';
import '../../shared/widgets/app_search_field.dart';
import '../../shared/widgets/app_surface_style.dart';
import '../../shared/widgets/app_tile_surface.dart';
import '../../shared/widgets/glass_dialog_route.dart';
import '../../shared/widgets/plain_list.dart';
import '../../shared/widgets/update_dialog.dart';
import 'calendar_legacy_cleanup_dialog.dart';
import 'settings_search_index.dart';
import 'widgets/semester_start_picker_sheet.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  /// 宽屏（平板 / 折叠屏展开）下内容列限宽居中；手机宽度不受影响。
  static const double _contentMaxWidth = 640;

  /// Bento 磁贴之间的间距，与「我的」页双列磁贴一致。
  static const double _bentoGap = AppSpacing.sm;

  /// 无小标题分组之间的垂直间距。
  static const double _groupGap = 14;

  /// 缓存平台包信息 Future，避免 build 重建时重复经 MethodChannel 查询。
  static final Future<PackageInfo> _packageInfoFuture =
      PackageInfo.fromPlatform();

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

/// 首次开启时用户选择的目标日历类型。
enum _CalendarSyncTarget {
  /// 本应用专属本地日历（[CalendarSyncControl.enable] 不传 calendarId）。
  local,

  /// 用户从系统可写日历中显式选择。
  existing,
}

class _SettingsPageState extends State<SettingsPage> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  // ── 学期识别状态 ──────────────────────────────────────────────────────────
  ScheduleTermContext? _resolved;
  bool _termLoading = true;

  // ── 课表日历同步状态 ──────────────────────────────────────────────────────
  CalendarSyncControl get _control => CalendarSyncControl.instance;
  CalendarReminderSettings get _reminder => CalendarReminderSettings.instance;

  /// 有开启 / 扫描 / 清理请求在途：期间忽略重复点击，避免重复原生调用。
  bool _busy = false;

  /// Coalesces async store/auth notifications until a route transition is idle.
  bool _transitionRefreshScheduled = false;

  /// 在途 Future 的真实进度文案；仅请求进行中非 null，空闲时**不**显示任何指示器。
  String? _progress;

  /// 最近一次清理结果摘要（仅本会话持有，用于 cleanupPending 时说明残留）。
  String? _cleanupNote;

  @override
  void initState() {
    super.initState();
    unawaited(_resolveTerm());
    _control.addListener(_handleControlChanged);
    _reminder.addListener(_handleControlChanged);
    // paused 的副标题取决于当前是否有已验证教务身份，登录 / 登出时需要重绘。
    ZhengfangAuth.instance.addListener(_handleControlChanged);
    unawaited(_control.load().then((_) => _handleControlChanged()));
    // 持久化提前量在启动时已 load；此处兜底确保设置页拿到磁盘值。
    unawaited(_reminder.load().then((_) => _handleControlChanged()));
  }

  @override
  void dispose() {
    _searchController.dispose();
    _control.removeListener(_handleControlChanged);
    _reminder.removeListener(_handleControlChanged);
    ZhengfangAuth.instance.removeListener(_handleControlChanged);
    super.dispose();
  }

  Future<void> _resolveTerm() async {
    final resolved = await CurrentTermResolver.instance.resolve();
    // The settings route is snapshot during its push/pop transition. Keep the
    // async read out of that interval so it cannot invalidate the snapshot.
    await PageTransitionActivity.instance.whenIdle();
    if (!mounted) return;
    setState(() {
      _resolved = resolved;
      _termLoading = false;
    });
  }

  void _handleControlChanged() {
    if (!mounted || _transitionRefreshScheduled) return;
    _transitionRefreshScheduled = true;
    unawaited(_refreshAfterTransition());
  }

  Future<void> _refreshAfterTransition() async {
    await PageTransitionActivity.instance.whenIdle();
    if (!mounted) return;
    _transitionRefreshScheduled = false;
    setState(() {});
  }

  static String _formatDotDate(DateTime date) =>
      '${date.month.toString().padLeft(2, '0')}.${date.day.toString().padLeft(2, '0')}';

  static String _compactTermLabel(ScheduleTermContext term) {
    final startShort = (term.academicYear % 100).toString().padLeft(2, '0');
    final endShort = ((term.academicYear + 1) % 100).toString().padLeft(2, '0');
    return '$startShort-$endShort · ${term.termLabel}';
  }

  String? get _calendarDetailNotice => switch (_control.state) {
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

  /// 0 不是「不提醒」：原生 `CalendarProviderStore` 对每个归属事件固定插入
  /// 一条 `MINUTES = reminderMinutes` 的 `METHOD_ALERT` 提醒，0 表示**课程
  /// 开始时**提醒，因此如实标注，不谎称可关闭提醒。
  static String _reminderLabel(int minutes) =>
      minutes <= 0 ? '课程开始时提醒' : '提前 $minutes 分钟';

  Future<void> _pickSemesterStartDate(
    BuildContext context,
    DateTime currentDate,
  ) async {
    final picked = await showSemesterStartPickerSheet(
      context,
      initialDate: currentDate,
    );
    if (picked == null) return;
    await SemesterCalendar.instance.setSemesterStartDate(picked);
  }

  Future<void> _checkForUpdate(BuildContext context) async {
    // 先查询持久化的原生请求，冷启动离线也能取消下载或继续安装。
    final controller = ApkUpdateController.instance;
    if (await controller.isSupported()) {
      await controller.refreshActiveUpdate();
      if (!context.mounted) return;
      if (controller.state.value.phase.isActive) {
        final release = UpdateChecker.instance.availableRelease.value;
        if (release != null) {
          await showUpdateDialog(context, release);
        } else {
          await showManagedUpdateDialog(context);
        }
        return;
      }
    }
    if (!context.mounted) return;

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

  /// 「重放新手引导」：走注册路由（routes.dart 组合层持有 WelcomePage 与
  /// 各动作落点），设置页不横向依赖 welcome feature。
  Future<void> _replayWelcome(BuildContext context) =>
      context.pushNamed('welcome');

  void _clearSearch() {
    _searchController.clear();
    setState(() => _searchQuery = '');
  }

  Widget _buildCheckUpdateRow(BuildContext context) {
    return ValueListenableBuilder<AppRelease?>(
      valueListenable: UpdateChecker.instance.availableRelease,
      builder: (context, release, _) {
        return ValueListenableBuilder<bool>(
          valueListenable: UpdateChecker.instance.isChecking,
          builder: (context, isChecking, _) {
            return FutureBuilder<PackageInfo>(
              future: SettingsPage._packageInfoFuture,
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
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : null,
                  showChevron: false,
                  onTap: isChecking ? null : () => _checkForUpdate(context),
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildReminderRow() {
    final state = _control.state;
    return PlainListRow(
      title: '课前提醒',
      // 同步未开启时提醒提前量不生效：禁用下拉（原生 0.5 透明度）并说明原因。
      subtitle: state == CalendarSyncControlState.enabled ? null : '开启日历同步后可设置',
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
        onChanged: state == CalendarSyncControlState.enabled
            ? (value) {
                if (value == null) return;
                unawaited(_reminder.setReminderMinutes(value));
              }
            : null,
      ),
    );
  }

  List<Widget> _buildSearchResults(
    BuildContext context,
    String query,
    bool isAndroid,
  ) {
    final tokens = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();
    final entries = <_SettingsSearchEntry>[
      _SettingsSearchEntry(
        keywords: '主题与材质 主题 材质 模式 浅色 深色 跟随系统 色彩 配色 颜色 字体 排版',
        builder: (context) => ListenableBuilder(
          listenable: AppPreferencesController.instance,
          builder: (context, _) => PlainListRow(
            title: '主题与材质',
            value: _ThemeBentoTile._themeModeLabel(
              AppPreferencesController.instance.state.themeMode,
            ),
            onTap: () => context.pushNamed('appearance-theme'),
          ),
        ),
      ),
      _SettingsSearchEntry(
        keywords: '首页个性化 首页 个性化 壁纸 流体 背景 图标 视效',
        builder: (context) {
          final personalization = PersonalizationController.instance;
          return ListenableBuilder(
            listenable: Listenable.merge([
              personalization.shaderEnabled,
              personalization.backgroundImagePath,
            ]),
            builder: (context, _) {
              final hasWallpaper =
                  personalization.backgroundImagePath.value?.isNotEmpty ??
                  false;
              final statusText = personalization.shaderEnabled.value
                  ? '流体背景'
                  : (hasWallpaper ? '自定义壁纸' : '默认背景');
              return PlainListRow(
                title: '首页个性化',
                value: statusText,
                onTap: () => context.pushNamed('appearance-personalization'),
              );
            },
          );
        },
      ),
      _SettingsSearchEntry(
        keywords: '开学日 开学 学期 日期 校历 恢复默认',
        builder: (context) {
          final term = _resolved ?? ScheduleTermContext.current();
          return ValueListenableBuilder<DateTime>(
            valueListenable: SemesterCalendar.instance.semesterStartDate,
            builder: (context, date, _) => PlainListRow(
              title: '开学日',
              value: '${_formatDotDate(date)} · ${_compactTermLabel(term)}',
              onTap: () => _pickSemesterStartDate(context, date),
            ),
          );
        },
      ),
      _SettingsSearchEntry(
        androidOnly: true,
        keywords: '写入系统日历 写入 系统 日历 同步 课表',
        builder: (context) {
          final state = _control.state;
          final isEnabled = state == CalendarSyncControlState.enabled;
          final statusText = switch (state) {
            CalendarSyncControlState.enabled =>
              _control.isWaitingForIdentity
                  ? '需重新登录'
                  : _reminderLabel(_reminder.reminderMinutes),
            CalendarSyncControlState.off => null,
            CalendarSyncControlState.paused =>
              ZhengfangAuth.instance.verifiedStudentId == null
                  ? '已暂停 · 待登录'
                  : '已暂停 · 账号不符',
            CalendarSyncControlState.cleanupPending => '待清理遗留日程',
          };
          return PlainSwitchRow(
            title: '写入系统日历',
            subtitle: statusText,
            value: isEnabled,
            enabled: !_busy,
            onChanged: (nextValue) {
              if (_busy) return;
              unawaited(nextValue ? _requestEnable() : _startScan());
            },
          );
        },
      ),
      _SettingsSearchEntry(
        androidOnly: true,
        keywords: '课前提醒 课前 提醒 日历 通知 提前 分钟',
        builder: (_) => _buildReminderRow(),
      ),
      _SettingsSearchEntry(
        androidOnly: true,
        visible: _progress != null || _showScanEntry,
        keywords: '扫描遗留日程 扫描 遗留 日程 清理 日历',
        builder: (_) => _progress != null
            ? _busyRow(_progress!)
            : PlainListRow(
                title: '扫描遗留日程',
                onTap: () => unawaited(_startScan()),
              ),
      ),
      _SettingsSearchEntry(
        keywords: '桌面组件与后台 桌面 组件 小组件 快捷方式 后台 保活 通知',
        builder: (context) => PlainListRow(
          title: '桌面组件与后台',
          onTap: () => context.pushNamed('desktop-background'),
        ),
      ),
      _SettingsSearchEntry(
        keywords: 'ai 模型与接口 模型 接口 大模型 api 密钥 key',
        builder: (context) => PlainListRow(
          title: 'AI 模型与接口',
          onTap: () => context.pushNamed('ai-settings'),
        ),
      ),
      _SettingsSearchEntry(
        keywords: '检查更新 检查 更新 版本 升级 新版本',
        builder: _buildCheckUpdateRow,
      ),
      _SettingsSearchEntry(
        keywords: '更新下载线路 更新 下载 线路 节点 自动 r2 cloudflare edgeone',
        builder: (_) => const _UpdateRouteRow(),
      ),
      _SettingsSearchEntry(
        keywords: '清除离线缓存 清除 离线 缓存 清理',
        builder: (context) => PlainListRow(
          title: '清除离线缓存',
          onTap: () => _clearOfflineCache(context),
        ),
      ),
      _SettingsSearchEntry(
        keywords: '重放新手引导 重放 新手 引导 欢迎 向导',
        builder: (context) =>
            PlainListRow(title: '重放新手引导', onTap: () => _replayWelcome(context)),
      ),
      _SettingsSearchEntry(
        keywords: '关于与诊断 关于 诊断 日志 反馈 开发者 版本',
        builder: (context) => PlainListRow(
          title: '关于与诊断',
          onTap: () => context.pushNamed('about'),
        ),
      ),
    ];

    return [
      for (final entry in entries)
        if ((!entry.androidOnly || isAndroid) &&
            entry.visible &&
            tokens.every(entry.keywords.contains))
          entry.builder(context),
      // 子页面具体设置项（索引树见 settings_search_index.dart）：命中后
      // 以「标题 + 路径」行展示，点击直达对应子页面。
      for (final item in kSettingsSearchIndex)
        if ((!item.androidOnly || isAndroid) &&
            item.visible &&
            tokens.every(item.searchText.contains))
          PlainListRow(
            title: item.title,
            subtitle: item.breadcrumb,
            onTap: () => context.pushNamed(item.routeName),
          ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final isAndroid = Theme.of(context).platform == TargetPlatform.android;
    final trimmedQuery = _searchQuery.trim();
    final searchResults = trimmedQuery.isEmpty
        ? const <Widget>[]
        : _buildSearchResults(context, trimmedQuery, isAndroid);

    return Scaffold(
      appBar: AppAppBar(title: const Text('设置')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: SettingsPage._contentMaxWidth,
          ),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              kPlainListGutter,
              AppSpacing.md,
              kPlainListGutter,
              32,
            ),
            children: [
              _SettingsSearchField(
                controller: _searchController,
                onChanged: (value) => setState(() => _searchQuery = value),
                onClear: _clearSearch,
              ),
              const SizedBox(height: SettingsPage._groupGap),
              if (trimmedQuery.isNotEmpty) ...[
                if (searchResults.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 48),
                    child: Center(
                      child: Text('未找到相关设置', style: context.appText.meta),
                    ),
                  )
                else
                  _SettingsListGroup(children: searchResults),
              ] else ...[
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: _ThemeBentoTile(
                          onTap: () => context.pushNamed('appearance-theme'),
                        ),
                      ),
                      const SizedBox(width: SettingsPage._bentoGap),
                      Expanded(
                        child: _PersonalizationBentoTile(
                          onTap: () =>
                              context.pushNamed('appearance-personalization'),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: SettingsPage._groupGap),
                _buildSemesterAndCalendarSection(context, isAndroid),
                const SizedBox(height: SettingsPage._groupGap),
                _SettingsListGroup(
                  children: [
                    PlainListRow(
                      title: '桌面组件与后台',
                      onTap: () => context.pushNamed('desktop-background'),
                    ),
                    PlainListRow(
                      title: 'AI 模型与接口',
                      onTap: () => context.pushNamed('ai-settings'),
                    ),
                  ],
                ),
                const SizedBox(height: SettingsPage._groupGap),
                _SettingsListGroup(
                  children: [
                    _buildCheckUpdateRow(context),
                    const _UpdateRouteRow(),
                    PlainListRow(
                      title: '清除离线缓存',
                      onTap: () => _clearOfflineCache(context),
                    ),
                    PlainListRow(
                      title: '重放新手引导',
                      onTap: () => _replayWelcome(context),
                    ),
                    PlainListRow(
                      title: '关于与诊断',
                      onTap: () => context.pushNamed('about'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSemesterAndCalendarSection(
    BuildContext context,
    bool isAndroid,
  ) {
    final state = _control.state;
    final progress = _progress;
    final detailNotice = _calendarDetailNotice;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _buildSemesterBentoTile(context)),
              if (isAndroid) ...[
                const SizedBox(width: SettingsPage._bentoGap),
                Expanded(child: _buildCalendarBentoTile(context)),
              ],
            ],
          ),
        ),
        if (isAndroid) ...[
          const SizedBox(height: SettingsPage._bentoGap),
          _SettingsListGroup(
            children: [
              _buildReminderRow(),
              if (detailNotice != null)
                PlainListRow(
                  title: '同步状态',
                  subtitle: detailNotice,
                  titleColor: state == CalendarSyncControlState.cleanupPending
                      ? Theme.of(context).colorScheme.error
                      : null,
                ),
              if (progress != null)
                _busyRow(progress)
              else if (_showScanEntry)
                PlainListRow(
                  title: '扫描遗留日程',
                  onTap: () => unawaited(_startScan()),
                ),
              if (state == CalendarSyncControlState.cleanupPending &&
                  _cleanupNote != null)
                PlainListRow(title: '上次清理结果', subtitle: _cleanupNote),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildSemesterBentoTile(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final term = _resolved ?? ScheduleTermContext.current();
    final termText = _compactTermLabel(term);

    return ValueListenableBuilder<DateTime>(
      valueListenable: SemesterCalendar.instance.semesterStartDate,
      builder: (context, semesterStartDate, _) {
        final defaultStart = SemesterCalendar.defaultSemesterStartFor(
          DateTime.now(),
        );
        final isModified = !DateUtils.isSameDay(
          semesterStartDate,
          defaultStart,
        );
        return _SettingsBentoTile(
          semanticsLabel:
              '开学日 ${semesterStartDate.month}月${semesterStartDate.day}日，$termText',
          onTap: () => _pickSemesterStartDate(context, semesterStartDate),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: double.infinity,
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text('开学日', style: context.appText.group),
                    if (isModified)
                      InkWell(
                        onTap: () => unawaited(
                          SemesterCalendar.instance.resetSemesterStartDate(),
                        ),
                        borderRadius: BorderRadius.circular(AppRadius.tag),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 2,
                          ),
                          child: Text(
                            '恢复默认',
                            style: context.appText.tag.copyWith(
                              color: cs.primary,
                            ),
                          ),
                        ),
                      )
                    else
                      Icon(
                        Icons.calendar_today_outlined,
                        size: 15,
                        color: cs.onSurfaceVariant.withValues(alpha: 0.45),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Text(
                _formatDotDate(semesterStartDate),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.appText.numValue,
              ),
              const SizedBox(height: 6),
              const Spacer(),
              Row(
                children: [
                  Flexible(
                    child: Text(
                      termText,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: context.appText.meta,
                    ),
                  ),
                  if (_termLoading) ...[
                    const SizedBox(width: 6),
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 1.8),
                    ),
                  ],
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCalendarBentoTile(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final state = _control.state;
    final isEnabled = state == CalendarSyncControlState.enabled;

    final (String statusText, Color statusColor) = switch (state) {
      CalendarSyncControlState.enabled =>
        _control.isWaitingForIdentity
            ? ('需重新登录', cs.tertiary)
            : (_reminderLabel(_reminder.reminderMinutes), cs.primary),
      CalendarSyncControlState.off => ('未开启', cs.onSurfaceVariant),
      CalendarSyncControlState.paused => (
        ZhengfangAuth.instance.verifiedStudentId == null
            ? '已暂停 · 待登录'
            : '已暂停 · 账号不符',
        cs.tertiary,
      ),
      CalendarSyncControlState.cleanupPending => ('待清理遗留日程', cs.error),
    };

    void handleToggle(bool nextValue) {
      if (_busy) return;
      unawaited(nextValue ? _requestEnable() : _startScan());
    }

    return _SettingsBentoTile(
      semanticsLabel: '写入系统日历',
      semanticsToggled: isEnabled,
      onTap: _busy ? null : () => handleToggle(!isEnabled),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              AppIconBadge(
                icon: Icons.event_repeat_outlined,
                accentColor: isEnabled ? cs.primary : cs.onSurfaceVariant,
                semantic: !isEnabled,
                size: AppIconBadgeSize.small,
              ),
              const Spacer(),
              SizedBox(
                height: 28,
                child: Transform.scale(
                  scale: 0.84,
                  alignment: Alignment.centerRight,
                  child: Switch.adaptive(
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    value: isEnabled,
                    onChanged: _busy ? null : handleToggle,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          const Spacer(),
          Text(
            '写入系统日历',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.appText.rowTitleStrong.copyWith(height: 1.2),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            statusText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.appText.meta.copyWith(color: statusColor),
          ),
        ],
      ),
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

class _SettingsSearchEntry {
  const _SettingsSearchEntry({
    required this.keywords,
    required this.builder,
    this.androidOnly = false,
    this.visible = true,
  });

  final String keywords;
  final Widget Function(BuildContext context) builder;
  final bool androidOnly;
  final bool visible;
}

class _SettingsSearchField extends StatefulWidget {
  const _SettingsSearchField({
    required this.controller,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  State<_SettingsSearchField> createState() => _SettingsSearchFieldState();
}

class _SettingsSearchFieldState extends State<_SettingsSearchField> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'SettingsSearchField');
  Offset? _outsidePointerDown;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChanged);
    _focusNode.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _handleTapDownOutside(PointerDownEvent event) {
    _outsidePointerDown = event.position;
  }

  void _handleTapUpOutside(PointerUpEvent event) {
    final down = _outsidePointerDown;
    _outsidePointerDown = null;
    if (down == null || (event.position - down).distance > 18.0) return;
    _focusNode.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(AppRadius.control);
    final focused = _focusNode.hasFocus;
    return TapRegion(
      onTapOutside: _handleTapDownOutside,
      onTapUpOutside: _handleTapUpOutside,
      child: AnimatedContainer(
        duration: AppMotion.reduced(context) ? Duration.zero : AppMotion.quick,
        foregroundDecoration: ShapeDecoration(
          shape: RoundedSuperellipseBorder(
            borderRadius: radius,
            side: focused
                ? BorderSide(color: cs.primary, width: 1.4)
                : BorderSide.none,
          ),
        ),
        child: AppHardTileShell(
          radius: AppRadius.control,
          child: AppTileSurface(
            borderRadius: radius,
            blurred: false,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: AppSearchField(
              controller: widget.controller,
              focusNode: _focusNode,
              hintText: '搜索设置',
              onChanged: widget.onChanged,
              onClear: widget.onClear,
              borderless: true,
            ),
          ),
        ),
      ),
    );
  }
}

/// 统一 Bento 磁贴外壳：与「我的」页双列磁贴同一配方（[AppHardTileShell] +
/// [AppTileSurface] 实底无模糊 + `AppRadius.card` 12dp 圆角）。
class _SettingsBentoTile extends StatelessWidget {
  const _SettingsBentoTile({
    required this.semanticsLabel,
    this.semanticsToggled,
    required this.onTap,
    required this.child,
  });

  final String semanticsLabel;
  final bool? semanticsToggled;
  final VoidCallback? onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      toggled: semanticsToggled,
      label: semanticsLabel,
      child: AppHardTileShell(
        radius: AppRadius.card,
        child: AppTileSurface(
          borderRadius: AppRadius.cardBorder,
          padding: const EdgeInsets.all(14),
          blurred: false,
          onTap: onTap,
          child: child,
        ),
      ),
    );
  }
}

/// 左外观磁贴：主题与材质（图标 + 标题 + 当前主题模式）。
class _ThemeBentoTile extends StatelessWidget {
  const _ThemeBentoTile({required this.onTap});

  final VoidCallback onTap;

  static String _themeModeLabel(AppThemePreference mode) => switch (mode) {
    AppThemePreference.system => '跟随系统',
    AppThemePreference.light => '浅色',
    AppThemePreference.dark => '深色',
  };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: AppPreferencesController.instance,
      builder: (context, _) {
        final prefs = AppPreferencesController.instance.state;
        return _SettingsBentoTile(
          semanticsLabel: '主题与材质',
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  AppIconBadge(
                    icon: Icons.palette_outlined,
                    accentColor: cs.primary,
                    size: AppIconBadgeSize.small,
                  ),
                  const Spacer(),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: cs.onSurfaceVariant.withValues(alpha: 0.45),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              const Spacer(),
              Text(
                '主题与材质',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.appText.rowTitleStrong.copyWith(height: 1.2),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                _themeModeLabel(prefs.themeMode),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.appText.meta,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 右外观磁贴：首页个性化（图标 + 标题 + 当前背景形态）。
class _PersonalizationBentoTile extends StatelessWidget {
  const _PersonalizationBentoTile({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final personalization = PersonalizationController.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([
        personalization.shaderEnabled,
        personalization.backgroundImagePath,
      ]),
      builder: (context, _) {
        final hasWallpaper =
            personalization.backgroundImagePath.value?.isNotEmpty ?? false;
        final statusText = personalization.shaderEnabled.value
            ? '流体背景'
            : (hasWallpaper ? '自定义壁纸' : '默认背景');
        return _SettingsBentoTile(
          semanticsLabel: '首页个性化',
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  AppIconBadge(
                    icon: Icons.wallpaper_outlined,
                    accentColor: cs.primary,
                    size: AppIconBadgeSize.small,
                  ),
                  const Spacer(),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: cs.onSurfaceVariant.withValues(alpha: 0.45),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              const Spacer(),
              Text(
                '首页个性化',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.appText.rowTitleStrong.copyWith(height: 1.2),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                statusText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.appText.meta,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 普通设置分组外壳：复用 [AppHardTileShell]（浅色模式下为实色衬底 + `0.8dp`
/// 中性细描边 + 轻落底影，深色模式下透传维持平色质感），仅作用于设置页内分组，
/// 不全局修改 [PlainListGroup] 默认样式。
class _SettingsListGroup extends StatelessWidget {
  const _SettingsListGroup({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return AppHardTileShell(
      radius: AppRadius.card,
      child: PlainListGroup(children: children),
    );
  }
}

/// 「更新下载线路」：自动（默认，先 R2、卡住 / 失败 / 低速时回退 EdgeOne）/
/// Cloudflare R2 / EdgeOne。只读写 [ApkDownloadRoutePreference] 的单个枚举名，
/// 更新弹窗在点「更新」时读取，自身不再展示选线。
class _UpdateRouteRow extends StatefulWidget {
  const _UpdateRouteRow();

  @override
  State<_UpdateRouteRow> createState() => _UpdateRouteRowState();
}

class _UpdateRouteRowState extends State<_UpdateRouteRow> {
  ApkDownloadRoute _route = ApkDownloadRoute.auto;

  static String _label(ApkDownloadRoute route) => switch (route) {
    ApkDownloadRoute.auto => '自动',
    ApkDownloadRoute.r2 => 'Cloudflare R2',
    ApkDownloadRoute.edgeone => 'EdgeOne',
  };

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final route = await ApkDownloadRoutePreference.load();
    if (!mounted || route == _route) return;
    setState(() => _route = route);
  }

  @override
  Widget build(BuildContext context) {
    return PlainListRow(
      title: '更新下载线路',
      subtitle: _route == ApkDownloadRoute.auto ? null : '仅使用所选线路，不会自动切换',
      trailing: AppDropdown<ApkDownloadRoute>(
        key: const Key('update_route_dropdown'),
        inline: true,
        hint: _label(_route),
        value: _route,
        items: <AppDropdownItem<ApkDownloadRoute>>[
          for (final route in ApkDownloadRoute.values)
            AppDropdownItem<ApkDownloadRoute>(
              value: route,
              label: _label(route),
            ),
        ],
        onChanged: (value) {
          if (value == null || value == _route) return;
          setState(() => _route = value);
          unawaited(ApkDownloadRoutePreference.save(value));
        },
      ),
    );
  }
}
