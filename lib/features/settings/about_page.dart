import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/logging/app_logger.dart';
import '../../core/notification/app_notification_service.dart';
import '../../core/perf/frame_timing_collector.dart';
import '../../core/theme/app_typography.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_brand_icon.dart';
import '../../shared/widgets/app_dropdown.dart';
import '../../shared/widgets/app_feedback.dart';
import '../../shared/widgets/external_url_launcher.dart';
import '../../shared/widgets/plain_list.dart';

/// 作者与项目信息（唯一来源）。
const String kAppAuthor = 'FHfanshu';
const String kAppAuthorEmail = 'fhfanshu@outlook.com';
const String kAppAuthorProfileUrl = 'https://github.com/FHfanshu';
const String kAppProjectUrl = 'https://github.com/FHfanshu/ZJXU-CampusHub';

/// 关于页头像资源：应用图标（由 `tools/brand/app_icon_master.png` 缩放）与
/// 作者 GitHub 头像（随包分发，不在运行时联网拉取）。
const String kAppIconAsset = 'assets/brand/app_icon.png';
const String kAppAuthorAvatarAsset = 'assets/brand/author_avatar.jpg';

/// 「关于与诊断」页：版本、作者联系方式、APK 分发地址与登录诊断日志；
/// 连续点按顶栏「关于」标题 5 次可展开隐藏的调试日志控制项。
class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  static const int _debugUnlockTaps = 5;
  static const Duration _tapResetWindow = Duration(seconds: 2);

  int _titleTapCount = 0;
  DateTime? _lastTitleTapAt;
  bool _debugToolsUnlocked = false;

  void _onTitleTap() {
    if (_debugToolsUnlocked) return;
    final now = DateTime.now();
    if (_lastTitleTapAt == null ||
        now.difference(_lastTitleTapAt!) > _tapResetWindow) {
      _titleTapCount = 1;
    } else {
      _titleTapCount++;
    }
    _lastTitleTapAt = now;
    if (_titleTapCount >= _debugUnlockTaps) {
      setState(() => _debugToolsUnlocked = true);
      AppFeedback.toast(context, '已显示调试选项');
    }
  }

  String _formatLogLevel(LogLevel level) {
    return switch (level) {
      LogLevel.debug => 'Debug',
      LogLevel.info => 'Info',
      LogLevel.warn => 'Warn',
      LogLevel.error => 'Error',
    };
  }

  Future<void> _open(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    final ok = uri.scheme == 'mailto'
        ? await launchExternalUriFromWebView(uri, logPrefix: '关于页')
        : await openInExternalBrowser(url, logPrefix: '关于页');
    if (!ok) {
      AppLogger.instance.webview(LogLevel.warn, '关于页链接打开失败: $url');
    }
  }

  /// 复制本次启动以来的认证诊断轨迹（已脱敏），用于真机复现登录问题。
  Future<void> _copyAuthTrail(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await Clipboard.setData(
        ClipboardData(text: AppLogger.instance.formatAuthTrail()),
      );
      AppFeedback.toastOn(messenger, '登录诊断日志已复制');
    } on PlatformException {
      AppFeedback.toastOn(messenger, '复制失败');
    }
  }

  Future<String> _buildDiagnosticReport() async {
    var appVersion = 'unknown';
    try {
      final info = await PackageInfo.fromPlatform();
      appVersion = '${info.appName} v${info.version}+${info.buildNumber}';
    } catch (_) {
      // 版本信息不可用时仍导出其余内容。
    }
    return AppLogger.instance.buildDiagnosticReport(appVersion: appVersion);
  }

  /// 导出 Markdown 文件并打开系统分享；分享不可用时回退为复制全文。
  ///
  /// 文件只写到应用临时目录，不经过网络，也不自动上传。
  Future<void> _exportDiagnosticReport(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    String? report;
    try {
      report = await _buildDiagnosticReport();
      final directory = await getTemporaryDirectory();
      final fileName = _diagnosticFileName(DateTime.now());
      final file = File('${directory.path}/$fileName');
      // 报告最多几百条日志，单次同步写入；导出是用户主动操作，不在热路径。
      file.writeAsStringSync(report, flush: true);
      final result = await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'text/markdown')],
          fileNameOverrides: [fileName],
          subject: 'JXU 诊断日志',
          text: 'JXU 完整诊断日志（Markdown）',
        ),
      );
      if (result.status == ShareResultStatus.unavailable) {
        await _copyDiagnosticFallback(messenger, report);
      }
    } catch (error, stackTrace) {
      AppLogger.instance.log(
        LogLevel.warn,
        LogCategory.general,
        '导出诊断日志失败',
        error: error,
        stackTrace: stackTrace,
      );
      if (report != null) {
        await _copyDiagnosticFallback(messenger, report);
      } else {
        AppFeedback.toastOn(messenger, '导出失败，请重试');
      }
    }
  }

  String _diagnosticFileName(DateTime now) {
    String two(int value) => value.toString().padLeft(2, '0');
    return 'JXU-diagnostics-${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}'
        '${now.millisecond.toString().padLeft(3, '0')}.md';
  }

  Future<void> _copyDiagnosticFallback(
    ScaffoldMessengerState messenger,
    String report,
  ) async {
    try {
      await Clipboard.setData(ClipboardData(text: report));
      AppFeedback.toastOn(messenger, '系统分享不可用，已复制到剪贴板');
    } catch (_) {
      AppFeedback.toastOn(messenger, '导出失败，请重试');
    }
  }

  Widget _buildHeader(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 20),
      child: Row(
        children: [
          const AppBrandIcon(size: 76),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '嘉兴大学',
                  style: textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                FutureBuilder<PackageInfo>(
                  future: PackageInfo.fromPlatform(),
                  builder: (context, snapshot) {
                    final info = snapshot.data;
                    return Text(
                      info == null
                          ? ' '
                          : 'v${info.version}+${info.buildNumber}',
                      key: const Key('about_version'),
                      style: textTheme.titleMedium?.copyWith(
                        color: cs.onSurfaceVariant,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAuthor(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Semantics(
        button: true,
        label: '开发者 $kAppAuthor',
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _open(kAppAuthorProfileUrl),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircleAvatar(
                  radius: 30,
                  backgroundImage: AssetImage(kAppAuthorAvatarAsset),
                ),
                const SizedBox(height: 8),
                Text(kAppAuthor, style: context.appText.secondary),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDebugSection(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ValueListenableBuilder<bool>(
      valueListenable: AppLogger.instance.loggingEnabled,
      builder: (context, loggingEnabled, child) {
        return ValueListenableBuilder<LogConfig>(
          valueListenable: AppLogger.instance.config,
          builder: (context, logConfig, _) {
            return PlainListGroup(
              children: [
                PlainSwitchRow(
                  title: '调试日志',
                  value: loggingEnabled,
                  onChanged: (value) {
                    AppLogger.instance.setEnabled(value);
                  },
                ),
                PlainListRow(
                  title: '最低日志级别',
                  trailing: AppDropdown<LogLevel>(
                    key: const Key('about_debug_min_level_dropdown'),
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
                  value: logConfig.webviewLifecycleEnabled,
                  onChanged: (value) {
                    AppLogger.instance.updateConfig(
                      logConfig.copyWith(webviewLifecycleEnabled: value),
                    );
                  },
                ),
                PlainSwitchRow(
                  title: 'WebView 控制台日志',
                  value: logConfig.webviewConsoleEnabled,
                  onChanged: (value) {
                    AppLogger.instance.updateConfig(
                      logConfig.copyWith(webviewConsoleEnabled: value),
                    );
                  },
                ),
                PlainSwitchRow(
                  title: '网络详细日志',
                  value: logConfig.networkVerboseEnabled,
                  onChanged: (value) {
                    AppLogger.instance.updateConfig(
                      logConfig.copyWith(networkVerboseEnabled: value),
                    );
                  },
                ),
                PlainListRow(
                  title: '通知测试',
                  trailing: Icon(
                    Icons.send_outlined,
                    size: 20,
                    color: cs.onSurfaceVariant,
                  ),
                  onTap: () {
                    final now = DateTime.now();
                    final hh = now.hour.toString().padLeft(2, '0');
                    final mm = now.minute.toString().padLeft(2, '0');
                    AppNotificationService.instance.showNotification(
                      id: 999,
                      title: '测试通知',
                      body: '这是一条来自调试模式的测试通知，$hh:$mm',
                      payload: 'test',
                    );
                  },
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppAppBar(
        title: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _onTitleTap,
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('关于'),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          kPlainListGutter,
          8,
          kPlainListGutter,
          32,
        ),
        children: [
          _buildHeader(context),
          Text('个人开发的第三方校园工具，与嘉兴大学官方无关。', style: context.appText.secondary),
          const SizedBox(height: kPlainListGroupGap),
          const PlainSectionHeader('开发者'),
          _buildAuthor(context),
          const SizedBox(height: kPlainListGroupGap),
          PlainListGroup(
            children: [
              PlainListRow(
                title: '联系邮箱',
                value: kAppAuthorEmail,
                onTap: () => _open('mailto:$kAppAuthorEmail'),
              ),
              PlainListRow(title: '发布页', onTap: () => _open(kAppProjectUrl)),
            ],
          ),
          const SizedBox(height: kPlainListGroupGap),
          const PlainSectionHeader('诊断'),
          PlainListGroup(
            children: [
              PlainListRow(
                title: '复制登录诊断日志',
                subtitle: '已脱敏，不含密码与验证码',
                showChevron: false,
                onTap: () => _copyAuthTrail(context),
              ),
              PlainListRow(
                title: '导出诊断日志',
                subtitle: 'Markdown 文件，含登录轨迹与最近日志',
                showChevron: false,
                onTap: () => _exportDiagnosticReport(context),
              ),
              ValueListenableBuilder<bool>(
                valueListenable: AppLogger.instance.diagnosticCapture,
                builder: (context, capture, child) {
                  final active = AppLogger.instance.diagnosticCaptureActive;
                  return PlainSwitchRow(
                    title: '记录完整诊断日志',
                    subtitle: kDebugMode
                        ? 'Debug 构建默认记录；Release 可手动开启'
                        : active
                        ? '已开启：保留更多网络与启动日志'
                        : '默认关闭：开启后导出内容更完整',
                    value: active,
                    enabled: !kDebugMode,
                    onChanged: (value) => unawaited(
                      AppLogger.instance.setDiagnosticCapture(value),
                    ),
                  );
                },
              ),
              // 性能诊断是内部工具：未以 --dart-define 启用时整行不出现。
              if (kPerfDiagnosticsEnabled)
                PlainListRow(
                  title: '性能诊断',
                  subtitle: '离线采集帧时',
                  titleBadge: '内部',
                  onTap: () => context.pushNamed('performance-diagnostics'),
                ),
            ],
          ),
          if (_debugToolsUnlocked) ...[
            const SizedBox(height: kPlainListGroupGap),
            const PlainSectionHeader('调试'),
            _buildDebugSection(context),
          ],
        ],
      ),
    );
  }
}
