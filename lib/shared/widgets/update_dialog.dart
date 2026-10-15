import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/app_typography.dart';
import '../../core/update/apk_download_route.dart';
import '../../core/update/apk_update_controller.dart';
import '../../core/update/update_model.dart';
import 'app_feedback.dart';
import 'glass_dialog_route.dart';

/// 应用内更新弹窗。
///
/// 展示版本号、发布时间与更新说明，并在**受支持的 Android** 上提供受管
/// 下载 / 安装流程：点「更新」后由原生 DownloadManager 在应用外下载，原生
/// 在安装包校验通过且处于前台时自动调起系统安装确认；本弹窗只投影
/// [ApkUpdateController] 的原生权威状态，**不**下载、不合成进度。
///
/// 既有调用方 `showUpdateDialog(context, release)` 行为不变：非 Android /
/// 缺少原生通道 / 版本未提供可信安装包资产时，降级为原有的外部浏览器
/// 下载 / 版本页链接（[AppRelease.launchUrl]），绝不谎称正在应用内下载。
///
/// [controller] 缺省用 [ApkUpdateController.instance]；测试可注入独立实例。
Future<void> showUpdateDialog(
  BuildContext context,
  AppRelease release, {
  ApkUpdateController? controller,
}) {
  return showGlassDialog<void>(
    context: context,
    builder: (_) => _UpdateDialogContent(
      release: release,
      controller: controller ?? ApkUpdateController.instance,
    ),
  );
}

/// 无需联网获取 Release，即可恢复原生已有下载 / 安装控制。
Future<void> showManagedUpdateDialog(
  BuildContext context, {
  ApkUpdateController? controller,
}) {
  return showGlassDialog<void>(
    context: context,
    builder: (_) => _UpdateDialogContent(
      controller: controller ?? ApkUpdateController.instance,
    ),
  );
}

class _UpdateDialogContent extends StatefulWidget {
  const _UpdateDialogContent({this.release, required this.controller});

  final AppRelease? release;
  final ApkUpdateController controller;

  @override
  State<_UpdateDialogContent> createState() => _UpdateDialogContentState();
}

class _UpdateDialogContentState extends State<_UpdateDialogContent>
    with WidgetsBindingObserver {
  static const Duration _pollInterval = Duration(seconds: 1);

  ApkUpdateController get _controller => widget.controller;

  /// 原生受管更新能力（非 Android / 缺少原生通道为 false）。
  bool _supported = false;

  /// 首次能力探测 + 原生状态查询是否已完成（未完成前只显示版本信息）。
  bool _bootstrapped = false;

  /// 应用是否在前台：后台时不轮询、不刷新，下载由原生继续。
  bool _foreground = true;

  /// 有原生调用在途：期间禁用按钮，避免重复点击。
  bool _busy = false;

  bool _legacyLaunching = false;

  Timer? _pollTimer;

  /// 线路选择与自动回退（只在轮询回调里观察进度，不持有后台定时器）。
  late final ApkDownloadRouter _router = ApkDownloadRouter(
    controller: widget.controller,
  );

  ApkUpdateState get _state => _controller.state.value;

  /// 版本是否提供了**可信的**规范安装包资产（可走应用内受管下载）。
  bool get _hasCanonicalAsset {
    final url = widget.release?.canonicalAssetUrl;
    return url != null && ApkUpdateUrlPolicy.isCanonicalAssetUrl(url);
  }

  /// 是否可在本弹窗内走应用内受管下载 / 安装。
  bool get _canManaged =>
      _supported && (_hasCanonicalAsset || _state.phase.isActive);

  bool get _releaseMatchesManaged {
    final release = widget.release;
    if (release == null || !_state.phase.isActive) return true;
    final tag = _state.releaseTag;
    final url = release.canonicalAssetUrl;
    if (tag != null && url != null && _hasCanonicalAsset) {
      return Uri.parse(url).pathSegments[4] == tag;
    }
    return false;
  }

  String get _managedVersion => _state.version ?? _state.releaseTag ?? '未知版本';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller.state.addListener(_onStateChanged);
    _router.status.addListener(_onStateChanged);
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    // 关闭弹窗 / 页面销毁只停止本弹窗的监听与轮询，**不**取消下载：
    // 原生 DownloadManager 继续，重开弹窗再查询即可。
    _pollTimer?.cancel();
    _pollTimer = null;
    _router.stopWatching();
    _router.status.removeListener(_onStateChanged);
    _controller.state.removeListener(_onStateChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (foreground == _foreground) return;
    _foreground = foreground;
    if (foreground && _supported) {
      // 回前台（含从「安装权限设置」返回）：查询一次原生真实状态。
      unawaited(_controller.refreshActiveUpdate());
    }
    _syncPolling();
  }

  Future<void> _bootstrap() async {
    // 冷启动挂载：先做一次真实能力探测，再查询一次原生状态。
    final supported = await _controller.isSupported();
    if (!mounted) return;
    _supported = supported;
    if (supported) {
      await _controller.refreshActiveUpdate();
      if (!mounted) return;
    }
    setState(() => _bootstrapped = true);
    _syncPolling();
  }

  void _onStateChanged() {
    if (!mounted) return;
    setState(() {});
    _syncPolling();
  }

  /// 轮询只在「弹窗挂载 + 支持应用内更新 + 前台 + 状态处于活动阶段」时进行，
  /// 慢节奏（~1s）地刷新原生真实状态；其余情况一律停表，不留下后台 Dart
  /// 定时器。
  void _syncPolling() {
    final shouldPoll =
        mounted && _supported && _foreground && _state.phase.isActive;
    if (shouldPoll) {
      _pollTimer ??= Timer.periodic(_pollInterval, (_) {
        unawaited(_pollOnce());
      });
      return;
    }
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  /// 一次轮询：先刷新原生真实状态，再让线路协调器据此判断是否需要自动回退。
  Future<void> _pollOnce() async {
    await _controller.refreshActiveUpdate();
    final release = widget.release;
    if (!mounted || release == null) return;
    await _router.onPolled(release);
  }

  // ── 原生调用 ──────────────────────────────────────────────────────────────

  /// 下载线路由「设置 → 更新下载线路」决定（默认自动），弹窗只在点击时读取，
  /// 自己不提供选线入口。
  Future<void> _startDownload() => _run(() async {
    final release = widget.release;
    if (release == null) return;
    final route = await ApkDownloadRoutePreference.load();
    await _router.start(release, route);
  });

  Future<void> _cancelDownload() => _run(() async {
    _router.stopWatching();
    await _controller.cancelActiveUpdate();
  });

  Future<void> _requestInstall() async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    var launched = false;
    var called = false;
    await _run(() async {
      if (!_releaseMatchesManaged) return;
      called = true;
      launched = await _controller.requestInstall(
        expectedReleaseTag: _state.releaseTag,
      );
    });
    if (!called || launched || !mounted) return;
    // 原生未发起安装器、且状态仍停在「可安装」时（例如 FileProvider 路径不匹配
    // 这类原生侧静默失败），必须如实提示——绝不能让「安装更新」看起来点了没反应。
    // 若原生已把状态改成「需要允许安装应用」，状态区已有引导，不叠加提示。
    if (_state.phase == ApkUpdatePhase.readyToInstall && messenger != null) {
      AppFeedback.toastOn(
        messenger,
        _failureText(ApkUpdateFailureReason.installerUnavailable),
      );
    }
  }

  Future<void> _openInstallPermissionSettings() => _run(() async {
    await _controller.openInstallPermissionSettings();
  });

  /// 统一的原生调用包装：在途期间禁用按钮，异常不向 UI 抛出（控制器已
  /// 把失败投影为状态）。
  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 降级路径：外部浏览器打开下载 / 版本页（与原行为一致，关闭弹窗后跳转）。
  Future<void> _openLegacyLink(BuildContext context) async {
    if (_legacyLaunching) return;
    _legacyLaunching = true;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final navigator = Navigator.of(context);
    try {
      final uri = Uri.tryParse(widget.release?.launchUrl ?? '');
      if (uri == null) {
        if (messenger != null) AppFeedback.toastOn(messenger, '更新链接无效');
        return;
      }
      navigator.pop();
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched && messenger != null) {
        AppFeedback.toastOn(messenger, '无法打开更新链接');
      }
    } finally {
      _legacyLaunching = false;
    }
  }

  // ── 构建 ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final release = widget.release;
    final showRelease = release != null && _releaseMatchesManaged;
    final title = showRelease
        ? '发现新版本 v${release.version}'
        : '已有更新 v$_managedVersion';

    return AlertDialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      title: Text(title),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (showRelease)
                Text(
                  '发布时间：${_formatDate(release.publishedAt)}',
                  style: context.appText.secondary,
                ),
              if (_bootstrapped) ...[
                const SizedBox(height: AppSpacing.md),
                _buildManagedSection(context),
              ],
              if (showRelease) ...[
                const SizedBox(height: AppSpacing.md),
                Text('更新内容', style: context.appText.label),
                const SizedBox(height: AppSpacing.sm),
                _buildChangelog(context, release.changelog),
              ],
              if (!_releaseMatchesManaged) ...[
                const SizedBox(height: AppSpacing.md),
                Text(
                  '现有更新与 v${release!.version} 不同；可取消现有更新，或重新下载该版本。',
                  style: context.appText.secondary,
                ),
              ],
            ],
          ),
        ),
      ),
      actions: _buildActions(context),
    );
  }

  /// 受管区：状态文案 + 预留稳定高度的真实进度条 + 少量说明。仅在支持
  /// 应用内更新时出现；否则给出一句诚实的降级说明。
  Widget _buildManagedSection(BuildContext context) {
    final text = context.appText;
    if (!_supported) {
      return Text('当前平台不支持应用内更新，可通过下方按钮前往下载页。', style: text.meta);
    }
    if (widget.release == null && !_state.phase.isActive) {
      return Text('当前没有可继续的更新，请关闭后重新检查更新。', style: text.meta);
    }
    if (!_hasCanonicalAsset && !_state.phase.isActive) {
      return Text('该版本未提供可校验的安装包，无法应用内下载；可通过下方按钮前往下载页。', style: text.meta);
    }

    final phase = _state.phase;
    final status = _statusText(phase);
    final hint = _hintText(phase);
    final progress = _progressInfo(phase);
    final routeNotice = _routeNotice(phase);
    final isError =
        phase == ApkUpdatePhase.failed || phase == ApkUpdatePhase.unavailable;
    final showBar = switch (phase) {
      ApkUpdatePhase.enqueued ||
      ApkUpdatePhase.downloading ||
      ApkUpdatePhase.verifying ||
      ApkUpdatePhase.paused ||
      ApkUpdatePhase.readyToInstall ||
      ApkUpdatePhase.permissionRequired ||
      ApkUpdatePhase.installerOpened => true,
      _ => false,
    };
    // 只有真正在等待结果的阶段才允许不确定进度动画；暂停 / 失败 / 取消不再动。
    final animate = switch (phase) {
      ApkUpdatePhase.enqueued ||
      ApkUpdatePhase.downloading ||
      ApkUpdatePhase.verifying => true,
      _ => false,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (status != null)
          Text(
            status,
            style: isError
                ? text.secondary.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  )
                : text.secondary,
          ),
        if (status != null && showBar) const SizedBox(height: AppSpacing.sm),
        if (showBar)
          SizedBox(
            height: 4,
            width: double.infinity,
            child: _buildProgressBar(context, progress.value, animate: animate),
          ),
        if (progress.label != null) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(progress.label!, style: text.meta),
        ],
        if (hint != null) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(hint, style: text.meta),
        ],
        if (routeNotice != null) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(routeNotice, style: text.meta),
        ],
      ],
    );
  }

  // ── 线路说明（只读；线路在「设置 → 更新下载线路」调整）──

  String _sourceLabel(ApkDownloadSource? source) => switch (source) {
    ApkDownloadSource.r2 => 'Cloudflare R2',
    ApkDownloadSource.edgeone => 'EdgeOne',
    ApkDownloadSource.github => 'GitHub',
    null => '当前线路',
  };

  /// 当前线路 / 最近一次自动回退说明（只描述真实发生过的事，不预告）。
  String? _routeNotice(ApkUpdatePhase phase) {
    final status = _router.status.value;
    if (status.switching) {
      return '${_sourceLabel(status.fellBackFrom)} 不稳定，正在切换到 '
          '${_sourceLabel(status.active)}…';
    }
    if (status.exhausted && phase == ApkUpdatePhase.failed) {
      return '所有线路均未成功下载，可稍后重试或改用浏览器下载。';
    }
    if (phase == ApkUpdatePhase.failed &&
        status.route != ApkDownloadRoute.auto) {
      return '可在「设置 → 更新下载线路」更换线路后重试。';
    }
    if (status.lastFallback != null && phase.isActive) {
      final why = switch (status.lastFallback!) {
        ApkFallbackReason.connectTimeout => '连接超时',
        ApkFallbackReason.stalled => '长时间无数据',
        ApkFallbackReason.slow => '下载速度过低',
        ApkFallbackReason.paused => '下载被暂停',
        ApkFallbackReason.failed => '下载失败',
      };
      return '${_sourceLabel(status.fellBackFrom)} $why，已切换到 '
          '${_sourceLabel(status.active)}。';
    }
    if (status.fellBackFrom != null && phase.isActive) {
      return '该版本暂无 ${_sourceLabel(status.fellBackFrom)} 线路，'
          '已改用 ${_sourceLabel(status.active)}。';
    }
    if (status.active != null && phase.isActive) {
      return '下载线路：${_sourceLabel(status.active)}';
    }
    return null;
  }

  /// 更新说明：去掉 Markdown 标记与提交类型前缀，限高可滚动，避免弹窗被
  /// 长日志撑满、把按钮挤出屏幕。
  Widget _buildChangelog(BuildContext context, String raw) {
    final text = context.appText;
    final lines = _changelogLines(raw);
    if (lines.isEmpty) {
      return Text('暂无更新说明', style: text.secondary);
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 220),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final line in lines)
              Padding(
                padding: EdgeInsets.only(
                  top: line.heading ? AppSpacing.sm : 2,
                  bottom: 2,
                ),
                child: line.heading
                    ? Text(line.text, style: text.label)
                    : Text(line.text, style: text.secondary),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildProgressBar(
    BuildContext context,
    double? value, {
    required bool animate,
  }) {
    final cs = Theme.of(context).colorScheme;
    // 尊重系统「移除动画」；非等待阶段（暂停等）也不做无限循环，改用静态轨道。
    if (value == null && (!animate || AppMotion.reduced(context))) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(2),
        ),
      );
    }
    return LinearProgressIndicator(
      value: value,
      minHeight: 4,
      borderRadius: BorderRadius.circular(2),
    );
  }

  // ── 状态文案 ──────────────────────────────────────────────────────────────

  String? _statusText(ApkUpdatePhase phase) => switch (phase) {
    ApkUpdatePhase.idle => null,
    ApkUpdatePhase.enqueued => '正在加入下载队列…',
    ApkUpdatePhase.downloading => '正在下载安装包…',
    ApkUpdatePhase.paused => '下载已暂停',
    ApkUpdatePhase.verifying => '正在校验安装包…',
    ApkUpdatePhase.readyToInstall => '下载完成，可安装更新',
    ApkUpdatePhase.permissionRequired => '需要允许安装应用',
    ApkUpdatePhase.installerOpened => '已打开系统安装确认',
    ApkUpdatePhase.failed => _failureText(_state.reason),
    ApkUpdatePhase.canceled => '已取消下载',
    ApkUpdatePhase.unavailable => _failureText(_state.reason),
  };

  String? _hintText(ApkUpdatePhase phase) => switch (phase) {
    ApkUpdatePhase.paused => '可取消后重新下载。',
    ApkUpdatePhase.readyToInstall => '系统可能已自动弹出安装确认；若未出现，可点下方按钮手动安装。',
    ApkUpdatePhase.permissionRequired => '请在系统设置中允许本应用安装应用，返回后会自动刷新。',
    ApkUpdatePhase.installerOpened => '请在系统界面完成安装，本应用不会自动安装。',
    ApkUpdatePhase.unavailable || ApkUpdatePhase.failed => null,
    _ => null,
  };

  String _failureText(ApkUpdateFailureReason? reason) => switch (reason) {
    ApkUpdateFailureReason.network => '网络连接失败，请检查网络后重试',
    ApkUpdateFailureReason.storageInsufficient => '设备存储空间不足，请清理后重试',
    ApkUpdateFailureReason.verificationFailed => '安装包校验未通过，已停止安装',
    ApkUpdateFailureReason.signatureMismatch => '安装包签名不符，已停止安装',
    ApkUpdateFailureReason.packageMismatch => '安装包与当前应用不匹配',
    ApkUpdateFailureReason.versionNotNewer => '该版本不新于当前版本',
    ApkUpdateFailureReason.abiUnsupported => '该安装包不支持当前设备',
    ApkUpdateFailureReason.permissionDenied => '未获得安装权限',
    ApkUpdateFailureReason.installerUnavailable => '无法打开系统安装程序',
    ApkUpdateFailureReason.untrustedAsset => '更新来源不可信，无法应用内下载',
    ApkUpdateFailureReason.unsupported => '当前平台不支持应用内更新',
    ApkUpdateFailureReason.unknown || null => '更新失败，请稍后重试',
    ApkUpdateFailureReason.nativeError => '更新失败，请稍后重试',
  };

  ({double? value, String? label}) _progressInfo(ApkUpdatePhase phase) {
    final bytes = _state.bytesDownloaded;
    final total = _state.totalBytes;
    switch (phase) {
      case ApkUpdatePhase.readyToInstall:
      case ApkUpdatePhase.permissionRequired:
      case ApkUpdatePhase.installerOpened:
        return (value: 1, label: null);
      case ApkUpdatePhase.downloading:
      case ApkUpdatePhase.paused:
        if (bytes != null && total != null && total > 0) {
          final value = (bytes / total).clamp(0.0, 1.0);
          return (
            value: value,
            label: '${_formatBytes(bytes)} / ${_formatBytes(total)}',
          );
        }
        if (bytes != null) {
          return (value: null, label: '已下载 ${_formatBytes(bytes)}');
        }
        return (value: null, label: null);
      default:
        return (value: null, label: null);
    }
  }

  // ── 动作 ──────────────────────────────────────────────────────────────────

  List<Widget> _buildActions(BuildContext context) {
    // 能力探测未完成 / 不支持 / 资产不可信时都先给降级入口，避免弹窗在探测
    // 期间没有任何可操作按钮。
    if (!_canManaged) {
      return [
        _dismissButton(context),
        if (widget.release != null) _legacyButton(context, filled: true),
      ];
    }

    if (!_releaseMatchesManaged) {
      return [
        _cancelButton(context),
        _dismissButton(context),
        if (_hasCanonicalAsset)
          _primaryButton(
            context,
            '重新下载 v${widget.release!.version}',
            _startDownload,
          ),
      ];
    }
    if (widget.release == null && !_state.phase.isActive) {
      return [_dismissButton(context)];
    }

    switch (_state.phase) {
      case ApkUpdatePhase.idle:
        return [
          _dismissButton(context),
          _primaryButton(context, '更新', _startDownload),
        ];
      case ApkUpdatePhase.enqueued:
      case ApkUpdatePhase.downloading:
      case ApkUpdatePhase.verifying:
      case ApkUpdatePhase.paused:
        return [_cancelButton(context), _dismissButton(context)];
      case ApkUpdatePhase.readyToInstall:
        return [
          _dismissButton(context),
          _primaryButton(context, '安装更新', _requestInstall),
        ];
      case ApkUpdatePhase.permissionRequired:
        return [
          _dismissButton(context),
          _primaryButton(context, '允许安装应用', _openInstallPermissionSettings),
        ];
      case ApkUpdatePhase.installerOpened:
        return [_dismissButton(context)];
      case ApkUpdatePhase.canceled:
      case ApkUpdatePhase.failed:
        return [
          _legacyButton(context, filled: false),
          _dismissButton(context),
          _primaryButton(context, '重试', _startDownload),
        ];
      case ApkUpdatePhase.unavailable:
        return [_dismissButton(context), _legacyButton(context, filled: true)];
    }
  }

  /// 关闭按钮：只关闭弹窗，**不**取消下载。
  Widget _dismissButton(BuildContext context) {
    final downloading = _canManaged && _state.phase != ApkUpdatePhase.idle;
    return TextButton(
      onPressed: _busy ? null : () => Navigator.of(context).pop(),
      child: Text(downloading ? '关闭' : '稍后再说'),
    );
  }

  Widget _primaryButton(
    BuildContext context,
    String label,
    Future<void> Function() action,
  ) {
    return FilledButton(
      onPressed: _busy ? null : () => unawaited(action()),
      child: Text(label),
    );
  }

  /// 取消当前受管下载（只影响原生受管的那一条，并清理其文件）。
  Widget _cancelButton(BuildContext context) {
    return TextButton(
      onPressed: _busy ? null : () => unawaited(_cancelDownload()),
      child: const Text('取消下载'),
    );
  }

  /// 降级为外部浏览器下载 / 版本页（仅在无法应用内受管或明确失败时出现）。
  Widget _legacyButton(BuildContext context, {required bool filled}) {
    final label = widget.release?.hasDownloadUrl == true ? '下载 APK' : '查看版本';
    if (filled) {
      return FilledButton(
        onPressed: _busy ? null : () => unawaited(_openLegacyLink(context)),
        child: Text(label),
      );
    }
    return TextButton(
      onPressed: _busy ? null : () => unawaited(_openLegacyLink(context)),
      child: const Text('改用浏览器下载'),
    );
  }
}

String _formatDate(DateTime value) {
  final year = value.year.toString().padLeft(4, '0');
  final month = value.month.toString().padLeft(2, '0');
  final day = value.day.toString().padLeft(2, '0');
  final hour = value.hour.toString().padLeft(2, '0');
  final minute = value.minute.toString().padLeft(2, '0');
  return '$year-$month-$day $hour:$minute';
}

String _formatBytes(int bytes) {
  const kb = 1024;
  const mb = 1024 * 1024;
  if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  if (bytes >= kb) return '${(bytes / kb).toStringAsFixed(0)} KB';
  return '$bytes B';
}

class _ChangelogLine {
  const _ChangelogLine(this.text, {this.heading = false});

  final String text;
  final bool heading;
}

final RegExp _commitPrefix = RegExp(r'^[a-zA-Z]+(\([^)]*\))?!?:\s*');

/// Release 正文 → 可读行：标题去 `#`，`- ` 变为 `· `，去掉 `type(scope):` 提交前缀
/// 与文首「更新日志」标题；空行折叠。纯展示，不改变发布内容本身。
List<_ChangelogLine> _changelogLines(String raw) {
  final result = <_ChangelogLine>[];
  for (final original in raw.split(RegExp(r'\r?\n'))) {
    var line = original.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#')) {
      final title = line.replaceFirst(RegExp(r'^#+\s*'), '').trim();
      if (title.isEmpty || (result.isEmpty && title == '更新日志')) continue;
      result.add(_ChangelogLine(title, heading: true));
      continue;
    }
    if (line.startsWith('- ') || line.startsWith('* ')) {
      line = line.substring(2).trim().replaceFirst(_commitPrefix, '');
      if (line.isEmpty) continue;
      result.add(_ChangelogLine('· $line'));
      continue;
    }
    result.add(_ChangelogLine(line.replaceAll('`', '')));
  }
  return result;
}
