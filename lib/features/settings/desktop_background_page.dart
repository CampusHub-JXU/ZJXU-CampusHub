import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/actions/campus_action_ids.dart';
import '../../core/notification/app_notification_service.dart';
import '../../core/shortcut/app_shortcut_service.dart';
import '../../core/system_surface/campus_widget_bridge.dart';
import '../../core/system_surface/system_settings_launcher.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_card.dart';
import '../../shared/widgets/app_icon_badge.dart';

/// 设置 → 桌面与后台（PRD §42）。
///
/// 只提供真实可用的入口与真实说明，不提供误导性的「一键全部开启」。
class DesktopBackgroundPage extends StatelessWidget {
  const DesktopBackgroundPage({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppAppBar(
        title: const Text('桌面与后台'),
        leading: const BackButton(),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          const _SectionHeader('桌面组件'),
          const SizedBox(height: 8),
          _GroupCard(
            children: [
              _ActionRow(
                icon: Icons.widgets_outlined,
                title: '添加桌面组件',
                subtitle: '在桌面查看下一节课、余额与通知，数据随 App 更新',
                onTap: () => _addWidget(context),
              ),
            ],
          ),
          const SizedBox(height: 24),
          const _SectionHeader('快捷方式'),
          const SizedBox(height: 8),
          _GroupCard(
            children: [
              _ActionRow(
                icon: Icons.push_pin_outlined,
                title: '添加「今日课表」快捷方式',
                subtitle: '固定到桌面后可直接打开今日课表',
                onTap: () => _addShortcut(context),
              ),
              _Hairline(color: cs.outlineVariant),
              _ActionRow(
                icon: Icons.settings_outlined,
                title: '打开快捷方式权限设置',
                subtitle: '部分系统（如 MIUI/HyperOS）需手动允许创建快捷方式',
                onTap: () => _openShortcutSettings(context),
              ),
            ],
          ),
          const SizedBox(height: 24),
          const _SectionHeader('通知'),
          const SizedBox(height: 8),
          _GroupCard(children: [_NotificationPermissionRow()]),
          const SizedBox(height: 24),
          const _SectionHeader('后台运行'),
          const SizedBox(height: 8),
          _GroupCard(
            children: [
              _ActionRow(
                icon: Icons.schedule_outlined,
                title: '后台运行状态',
                subtitle: '通知与课表更新由系统后台任务调度，App 不会在后台自动弹出界面。点按打开应用详情页检查系统后台限制',
                onTap: () => _openSystemSettings(
                  context,
                  SystemSettingsTarget.appDetails,
                ),
              ),
              _Hairline(color: cs.outlineVariant),
              _ActionRow(
                icon: Icons.alarm_outlined,
                title: '精确闹钟',
                subtitle: '若需准点提醒，请允许本应用使用「闹钟和提醒」。点按打开对应设置页',
                onTap: () => _openSystemSettings(
                  context,
                  SystemSettingsTarget.exactAlarms,
                ),
              ),
              _Hairline(color: cs.outlineVariant),
              _ActionRow(
                icon: Icons.battery_saver_outlined,
                title: '电池优化',
                subtitle: '系统省电策略可能延后后台任务。点按仅打开电池优化列表页，需手动将本应用设为「无限制」（会更耗电）',
                onTap: () => _openSystemSettings(
                  context,
                  SystemSettingsTarget.batteryOptimization,
                ),
              ),
              _Hairline(color: cs.outlineVariant),
              _ActionRow(
                icon: Icons.phone_android_outlined,
                title: 'HyperOS / MIUI 自启动',
                subtitle:
                    '小米系系统可能出现链式启动确认，属系统正常行为。点按尝试打开自启动管理，部分系统不保证直达，可能需手动查找',
                onTap: () => _openSystemSettings(
                  context,
                  SystemSettingsTarget.autostart,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _addWidget(BuildContext context) async {
    final requested = await CampusWidgetBridge.instance.requestPin();
    if (!context.mounted) return;
    _showSnackBar(
      context,
      requested ? '已请求添加桌面组件，请在桌面确认' : '当前设备或桌面不支持固定组件，请在桌面手动添加',
    );
  }

  Future<void> _addShortcut(BuildContext context) async {
    final result = await AppShortcutService.instance.requestPinnedShortcut(
      CampusActionIds.scheduleToday,
      title: '今日课表',
    );
    if (!context.mounted) return;
    _showSnackBar(context, result.message);
  }

  Future<void> _openShortcutSettings(BuildContext context) async {
    final opened = await AppShortcutService.instance
        .openShortcutPermissionSettings();
    if (!context.mounted) return;
    if (!opened) {
      _showSnackBar(context, '未能打开系统设置，请手动前往系统应用管理');
    }
  }

  /// 跳转系统设置页；命中目标页不打扰，降级 / 失败时明确说明实际打开的页面。
  Future<void> _openSystemSettings(
    BuildContext context,
    SystemSettingsTarget target,
  ) async {
    final result = await SystemSettingsLauncher.instance.open(target);
    if (!context.mounted) return;
    final message = _systemSettingsFallbackMessage(target, result);
    if (message != null) _showSnackBar(context, message);
  }

  /// 打开设置页失败 / 降级时的提示；命中目标页返回 null。
  ///
  /// 打开成功不代表权限已授予，这里只反馈真实打开的页面。
  static String? _systemSettingsFallbackMessage(
    SystemSettingsTarget target,
    SystemSettingsOpenResult result,
  ) {
    // 应用详情页本身是「后台运行状态」行的目标页，请求它时按成功处理。
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

void _showSnackBar(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

class _NotificationPermissionRow extends StatefulWidget {
  @override
  State<_NotificationPermissionRow> createState() =>
      _NotificationPermissionRowState();
}

class _NotificationPermissionRowState extends State<_NotificationPermissionRow>
    with WidgetsBindingObserver {
  bool _checking = true;

  /// 真实查询结果；null 表示查询失败，状态未知（不谎称已开启）。
  bool? _enabled;

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
    // 从系统设置返回后重新查询真实权限状态，不沿用旧值。
    if (state == AppLifecycleState.resumed) unawaited(_refreshStatus());
  }

  Future<void> _refreshStatus() async {
    bool? enabled;
    try {
      enabled = await AppNotificationService.instance.areNotificationsEnabled();
    } catch (_) {
      enabled = null;
    }
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _checking = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final status = _checking
        ? '检查中…'
        : switch (_enabled) {
            true => '已开启，点按可前往系统通知设置',
            false => '未开启，点按前往系统设置开启',
            null => '状态未知，点按前往系统通知设置查看',
          };
    return _ActionRow(
      icon: Icons.notifications_outlined,
      title: '通知权限',
      subtitle: status,
      // 已开启也可点按：直达应用通知设置（打开成功不代表已授权）。
      onTap: () => _openNotificationSettings(context),
    );
  }

  Future<void> _openNotificationSettings(BuildContext context) async {
    final result = await SystemSettingsLauncher.instance.open(
      SystemSettingsTarget.notifications,
    );
    if (!context.mounted) return;
    // 命中目标页不提示，返回页面时由生命周期回调刷新真实权限状态。
    final message = switch (result) {
      SystemSettingsOpenResult.target => null,
      SystemSettingsOpenResult.appDetails => '未能直达通知设置，已打开应用详情页，请在「通知」中手动开启',
      SystemSettingsOpenResult.settings => '未能直达通知设置，已打开系统设置首页，请在「通知管理」中手动开启',
      SystemSettingsOpenResult.unavailable => '未能打开系统设置，请手动前往系统「应用管理」调整',
    };
    if (message != null) _showSnackBar(context, message);
  }
}

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
      ),
    );
  }
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

class _Hairline extends StatelessWidget {
  const _Hairline({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Divider(height: 1, thickness: 1, indent: 64, color: color);
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final subtitle = this.subtitle;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              AppIconBadge(
                icon: icon,
                size: AppIconBadgeSize.small,
                accentColor: cs.primary,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 15,
                        color: cs.onSurface,
                        height: 1.2,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurfaceVariant,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (onTap != null)
                Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: cs.onSurfaceVariant.withValues(alpha: 0.45),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
