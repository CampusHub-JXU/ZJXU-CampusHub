import 'package:flutter/material.dart';

import '../../core/actions/campus_action_ids.dart';
import '../../core/notification/app_notification_service.dart';
import '../../core/shortcut/app_shortcut_service.dart';
import '../../core/system_surface/campus_widget_bridge.dart';
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
              _InfoRow(
                icon: Icons.schedule_outlined,
                title: '后台运行状态',
                body: '通知与课表更新由系统后台任务调度。App 不会在后台自动弹出界面。',
              ),
              _Hairline(color: cs.outlineVariant),
              _InfoRow(
                icon: Icons.alarm_outlined,
                title: '精确闹钟',
                body: '若需要准点提醒，请在系统设置中允许本应用使用「闹钟和提醒」。',
              ),
              _Hairline(color: cs.outlineVariant),
              _InfoRow(
                icon: Icons.battery_saver_outlined,
                title: '电池优化',
                body: '系统省电策略可能延后后台任务。将本应用设为「无限制」可提升及时性，但会更耗电。',
              ),
              _Hairline(color: cs.outlineVariant),
              _InfoRow(
                icon: Icons.phone_android_outlined,
                title: 'HyperOS / MIUI 自启动',
                body: '小米系系统可能出现链式启动确认，属系统正常行为。可在「自启动管理」中允许本应用，无需要求全部放开。',
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
    _toast(context, requested ? '已请求添加桌面组件，请在桌面确认' : '当前设备或桌面不支持固定组件，请在桌面手动添加');
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
    if (!opened) {
      _toast(context, '未能打开系统设置，请手动前往系统应用管理');
    }
  }

  void _toast(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _NotificationPermissionRow extends StatefulWidget {
  @override
  State<_NotificationPermissionRow> createState() =>
      _NotificationPermissionRowState();
}

class _NotificationPermissionRowState
    extends State<_NotificationPermissionRow> {
  late final Future<bool> _enabled = AppNotificationService.instance
      .areNotificationsEnabled();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _enabled,
      builder: (context, snapshot) {
        final enabled = snapshot.data;
        final status = enabled == null
            ? '检查中…'
            : (enabled ? '已开启' : '未开启，可能收不到课程与公告提醒');
        return _ActionRow(
          icon: Icons.notifications_outlined,
          title: '通知权限',
          subtitle: status,
          onTap: enabled == true ? null : () => _request(context),
        );
      },
    );
  }

  Future<void> _request(BuildContext context) async {
    final granted = await AppNotificationService.instance.requestPermission();
    if (!context.mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(granted ? '通知权限已开启' : '未获得通知权限，请在系统设置中开启')),
      );
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

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
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
                const SizedBox(height: 4),
                Text(
                  body,
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
