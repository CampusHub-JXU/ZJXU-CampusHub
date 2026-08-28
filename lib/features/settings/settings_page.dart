import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/logging/app_logger.dart';
import '../../core/notification/app_notification_service.dart';
import '../../core/semester/current_term_resolver.dart';
import '../../core/semester/semester_calendar.dart';
import '../../core/semester/schedule_term_context.dart';
import '../../core/update/update_checker.dart';
import '../../core/update/update_model.dart';
import '../../shared/widgets/app_dropdown.dart';
import '../../shared/widgets/update_dialog.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

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
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(const SnackBar(content: Text('当前已是最新版本')));
        break;
      case UpdateCheckStatus.error:
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(const SnackBar(content: Text('检查更新失败，请稍后重试')));
        break;
      case UpdateCheckStatus.checking:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('外观', style: textTheme.titleMedium),
          const SizedBox(height: 12),
          Card(
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              leading: const Icon(Icons.palette_outlined),
              title: const Text('主题与外观'),
              subtitle: const Text('主题模式、颜色、纯黑模式、文本缩放'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.pushNamed('theme-settings'),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              leading: const Icon(Icons.wallpaper_outlined),
              title: const Text('首页个性化'),
              subtitle: const Text('背景图片、Shader、毛玻璃效果'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.pushNamed('personalization'),
            ),
          ),
          const SizedBox(height: 16),
          Text('学期', style: textTheme.titleMedium),
          const SizedBox(height: 12),
          ValueListenableBuilder<DateTime>(
            valueListenable: SemesterCalendar.instance.semesterStartDate,
            child: const _CurrentTermTile(),
            builder: (context, semesterStartDate, child) {
              return Card(
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    ?child,
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    ListTile(
                      title: const Text('当前学期开学日'),
                      subtitle: Text(
                        '${_formatDate(semesterStartDate)}（用于周次与下一节课计算）',
                      ),
                      trailing: const Icon(Icons.edit_calendar_outlined),
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
                        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
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
                ),
              );
            },
          ),
          const SizedBox(height: 16),
          Text('设置会立即生效。', style: textTheme.bodySmall),
          const SizedBox(height: 24),
          Text('版本', style: textTheme.titleMedium),
          const SizedBox(height: 12),
          FutureBuilder<PackageInfo>(
            future: PackageInfo.fromPlatform(),
            builder: (context, snapshot) {
              final version = snapshot.hasData
                  ? '当前版本 v${snapshot.data!.version}+${snapshot.data!.buildNumber}'
                  : '查看当前版本信息';
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
                      return Card(
                        clipBehavior: Clip.antiAlias,
                        child: ListTile(
                          leading: const Icon(Icons.system_update_outlined),
                          title: const Text('检查更新'),
                          subtitle: Text(subtitle),
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
                                ),
                          onTap: isChecking
                              ? null
                              : () {
                                  _checkForUpdate(context);
                                },
                        ),
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
                  : '';
              return Center(
                child: Text(
                  '嘉兴大学-智能中台 $version',
                  style: textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              );
            },
          ),
          if (kDebugMode) ...[
            const SizedBox(height: 16),
            Text('调试', style: textTheme.titleMedium),
            const SizedBox(height: 12),
            ValueListenableBuilder<bool>(
              valueListenable: AppLogger.instance.loggingEnabled,
              builder: (context, loggingEnabled, child) {
                return ValueListenableBuilder<LogConfig>(
                  valueListenable: AppLogger.instance.config,
                  builder: (context, logConfig, _) {
                    return Card(
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SwitchListTile.adaptive(
                            title: const Text('调试日志'),
                            subtitle: const Text('开启后记录调试期日志和异常'),
                            value: loggingEnabled,
                            onChanged: (value) {
                              AppLogger.instance.setEnabled(value);
                            },
                          ),
                          ListTile(
                            title: const Text('最低日志级别'),
                            subtitle: Text(
                              _formatLogLevel(logConfig.minimumLevel),
                            ),
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
                          SwitchListTile.adaptive(
                            title: const Text('WebView 生命周期日志'),
                            subtitle: const Text('页面加载、跳转和白屏探测细节'),
                            value: logConfig.webviewLifecycleEnabled,
                            onChanged: (value) {
                              AppLogger.instance.updateConfig(
                                logConfig.copyWith(
                                  webviewLifecycleEnabled: value,
                                ),
                              );
                            },
                          ),
                          SwitchListTile.adaptive(
                            title: const Text('WebView 控制台日志'),
                            subtitle: const Text('记录页面 console warning/error'),
                            value: logConfig.webviewConsoleEnabled,
                            onChanged: (value) {
                              AppLogger.instance.updateConfig(
                                logConfig.copyWith(
                                  webviewConsoleEnabled: value,
                                ),
                              );
                            },
                          ),
                          SwitchListTile.adaptive(
                            title: const Text('网络详细日志'),
                            subtitle: const Text('记录请求和响应细节，噪音较大'),
                            value: logConfig.networkVerboseEnabled,
                            onChanged: (value) {
                              AppLogger.instance.updateConfig(
                                logConfig.copyWith(
                                  networkVerboseEnabled: value,
                                ),
                              );
                            },
                          ),
                          const Divider(height: 1),
                          ListTile(
                            title: const Text('通知测试'),
                            subtitle: const Text('发送一条本地测试通知'),
                            trailing: const Icon(Icons.send_outlined),
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
                          const Divider(height: 1),
                          ListTile(
                            leading: const Icon(
                              Icons.notifications_active_outlined,
                            ),
                            title: const Text('推送令牌'),
                            subtitle: const Text('查看 FCM 推送注册状态'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => context.pushNamed('push-debug'),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ],
        ],
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

    return ListTile(
      leading: const Icon(Icons.school_outlined),
      title: const Text('当前学年学期'),
      subtitle: Text('${_termLabel(term)} · $subtitle'),
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
