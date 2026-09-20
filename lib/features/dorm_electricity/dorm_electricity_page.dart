import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/actions/campus_action_executor.dart';
import '../../core/logging/app_logger.dart';
import '../../core/notification/app_notification_service.dart';
import 'dorm_electricity_service.dart';
import 'widgets/electricity_battery_header.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_empty_view.dart';
import '../../shared/widgets/login_shell.dart';

class DormElectricityPage extends StatefulWidget {
  const DormElectricityPage({super.key});

  @override
  State<DormElectricityPage> createState() => _DormElectricityPageState();
}

class _DormElectricityPageState extends State<DormElectricityPage>
    with TickerProviderStateMixin {
  final _service = DormElectricityService.instance;
  double? _electricity;
  bool _loading = true;
  bool _refreshing = false;
  bool _hasConfig = false;
  bool _requiresUnifiedAuth = false;
  bool _alertEnabled = false;
  double _alertThreshold = DormElectricityService.defaultAlertThreshold;
  String? _error;
  AnimationController? _matrixFillController;
  Animation<double>? _matrixFillAnim;
  AnimationController? _matrixBreathController;
  Animation<double>? _matrixBreathAnim;

  @override
  void initState() {
    super.initState();
    _ensureMatrixAnimations();
    _load(forceRefresh: true);
  }

  void _ensureMatrixAnimations() {
    final fillController = _matrixFillController ??= AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 820),
    );
    _matrixFillAnim ??= CurvedAnimation(
      parent: fillController,
      curve: Curves.easeOutCubic,
    );

    final breathController = _matrixBreathController ??= AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4700),
    );
    _matrixBreathAnim ??= CurvedAnimation(
      parent: breathController,
      curve: Curves.linear,
    );
    if (!breathController.isAnimating) {
      breathController.repeat();
    }
  }

  @override
  void dispose() {
    _matrixFillController?.dispose();
    _matrixBreathController?.dispose();
    super.dispose();
  }

  /// [blocking] 为 true 时用整页加载态覆盖内容（首次加载 / 切换寝室）；
  /// 为 false 时保留当前内容，仅由调用方自己的按钮/下拉指示器表达进度
  /// （手动刷新 + 下拉刷新）。
  Future<void> _load({bool forceRefresh = false, bool blocking = true}) async {
    if (!mounted) return;
    if (blocking) setState(() => _loading = true);
    _hasConfig = await _service.hasRoomConfig();
    _alertEnabled = await _service.getAlertEnabled();
    _alertThreshold = await _service.getAlertThreshold();
    if (!mounted) return;
    if (_hasConfig) {
      final oldValue = _electricity;
      _electricity = await _service.fetchElectricity(
        forceRefresh: forceRefresh,
      );
      _error = _service.lastError;
      _requiresUnifiedAuth = _service.requiresAuthentication;

      // 查询失败（网关不健康）时跳过低电量预警，避免紧跟着再发一整轮
      // RPC，把失败面翻倍。
      if (forceRefresh && _error == null) {
        await _service.checkAndAlert(
          onAlert: ({required value, required threshold}) {
            unawaited(
              _showLowElectricityNotification(
                value: value,
                threshold: threshold,
              ),
            );
          },
        );
      }

      if (mounted) {
        if (oldValue == null && _electricity != null) {
          _ensureMatrixAnimations();
          _matrixFillController?.forward(from: 0);
        } else if (_electricity != oldValue) {
          _ensureMatrixAnimations();
          _matrixFillController?.forward(from: 0);
        }
      }
    }
    if (!_hasConfig) {
      _requiresUnifiedAuth = false;
      _error = null;
    }
    if (!mounted) return;
    setState(() {
      if (blocking) _loading = false;
    });
  }

  /// 手动/下拉刷新：不覆盖内容，只点亮按钮或下拉指示器。
  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await _load(forceRefresh: true, blocking: false);
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _showLowElectricityNotification({
    required double value,
    required double threshold,
  }) async {
    try {
      await AppNotificationService.instance.showNotification(
        id: 100,
        title: '寝室电费不足',
        body:
            '剩余电量 ${_service.formatElectricity(value)} 度，'
            '低于 ${threshold.toInt()} 度阈值，请及时充值',
        payload: 'dorm-electricity',
      );
    } catch (error, stackTrace) {
      AppLogger.instance.storage(
        LogLevel.warn,
        '寝室电费低电量通知发送失败',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _openRecharge() async {
    await CampusActionExecutor.instance.executeWechat(
      context,
      url: DormElectricityService.rechargeUrl,
      title: '电费充值',
      successMessage: '已跳转到微信，请在微信中完成电费充值',
      failureMessage: '未能打开页面，充值链接已复制，请到微信中打开',
      autoCopyOnFailure: true,
    );
  }

  _ElectricityColors _resolveColors(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // 状态强调色统一跟随全局主题色，不再为电量单独引入绿色系。
    return _ElectricityColors(
      primary: cs.primary,
      label: _electricity == null ? '未知' : _statusLabelFor(_electricity!),
    );
  }

  String _statusLabelFor(double value) {
    if (value >= 50) return '充足';
    if (value >= 20) return '适中';
    if (value >= 10) return '偏低';
    return '不足';
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppAppBar(
        title: const Text('寝室电费'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '选择寝室',
            onPressed: () async {
              await context.pushNamed('dorm-electricity-settings');
              if (mounted) _load(forceRefresh: true);
            },
          ),
        ],
      ),
      body: _loading
          ? _buildLoadingState(cs)
          : !_hasConfig
          ? _buildNoConfig(context)
          : RefreshIndicator(
              onRefresh: _refresh,
              child: _buildContent(context, cs),
            ),
    );
  }

  Widget _buildLoadingState(ColorScheme cs) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 36,
            height: 36,
            child: CircularProgressIndicator(strokeWidth: 3, color: cs.primary),
          ),
          const SizedBox(height: 16),
          Text(
            '正在获取电量…',
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildNoConfig(BuildContext context) {
    return AppEmptyView(
      title: '尚未配置寝室',
      message: '选择寝室后即可查看剩余电量',
      icon: Icons.home_outlined,
      actionLabel: '去选择寝室',
      onAction: () async {
        await context.pushNamed('dorm-electricity-settings');
        if (mounted) _load(forceRefresh: true);
      },
    );
  }

  Widget _buildContent(BuildContext context, ColorScheme cs) {
    final colors = _resolveColors(context);
    final value = _service.formatElectricity(_electricity);
    final updatedAt = _service.lastUpdated;
    final updatedAtText = updatedAt == null
        ? '未刷新'
        : '${updatedAt.hour.toString().padLeft(2, '0')}:${updatedAt.minute.toString().padLeft(2, '0')}';

    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_error != null) ...[
            _buildErrorBanner(context, cs),
            const SizedBox(height: 12),
          ],
          _buildDetailCard(context, cs, colors, value, updatedAtText),
        ],
      ),
    );
  }

  // ── Electricity Detail Card ────────────────────────────────────────────────

  Widget _buildDetailCard(
    BuildContext context,
    ColorScheme cs,
    _ElectricityColors colors,
    String value,
    String updatedAtText,
  ) {
    _ensureMatrixAnimations();
    final matrixFillAnim = _matrixFillAnim!;
    final matrixBreathAnim = _matrixBreathAnim!;
    final isLight = Theme.of(context).brightness == Brightness.light;

    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: colors.primary),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      builder: (context, animatedColor, _) {
        final accent = animatedColor ?? colors.primary;
        final statusBackgroundColor = accent.withValues(
          alpha: isLight ? 0.1 : 0.16,
        );
        return RepaintBoundary(
          child: Card(
            clipBehavior: Clip.antiAlias,
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ElectricityBatteryHeader(
                    valueText: value,
                    statusLabel: colors.label,
                    fraction: _chargeFraction,
                    fillAnimation: matrixFillAnim,
                    breathAnimation: matrixBreathAnim,
                    accentColor: accent,
                    statusBackgroundColor: statusBackgroundColor,
                  ),
                  const SizedBox(height: 20),
                  _buildInfoSection(context, accent, updatedAtText),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildInfoSection(
    BuildContext context,
    Color accent,
    String updatedAtText,
  ) {
    final cs = Theme.of(context).colorScheme;
    final dim = cs.onSurfaceVariant;
    final dividerColor = cs.outlineVariant.withValues(alpha: 0.45);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IntrinsicHeight(
          child: Row(
            children: [
              Expanded(
                child: _InfoRow(
                  icon: Icons.update_outlined,
                  label: '更新时间',
                  value: updatedAtText,
                  accent: accent,
                ),
              ),
              VerticalDivider(
                width: 1,
                thickness: 0.6,
                color: dividerColor,
                indent: 4,
                endIndent: 4,
              ),
              Expanded(
                child: _InfoRow(
                  icon: Icons.bolt_outlined,
                  label: '预警阈值',
                  value: _alertEnabled ? '${_alertThreshold.toInt()} 度' : '未开启',
                  accent: accent,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Divider(height: 1, thickness: 0.6, color: dividerColor),
        const SizedBox(height: 2),
        Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () async {
              await context.pushNamed('dorm-electricity-settings');
              if (mounted) _load(forceRefresh: true);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
              child: Row(
                children: [
                  Icon(Icons.notifications_outlined, size: 18, color: accent),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '低电量通知',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: cs.onSurface,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _alertEnabled
                              ? '低于 ${_alertThreshold.toInt()} 度时推送提醒'
                              : '未开启，点击前往设置',
                          style: TextStyle(fontSize: 11, color: dim),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right, size: 18, color: dim),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _refresh,
            icon: _refreshing
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: cs.onPrimary,
                    ),
                  )
                : const Icon(Icons.refresh_rounded, size: 18),
            label: Text(_refreshing ? '正在刷新' : '刷新电量'),
          ),
        ),
        const SizedBox(height: 2),
        Center(
          child: TextButton.icon(
            onPressed: _openRecharge,
            icon: const Icon(Icons.account_balance_wallet_outlined, size: 16),
            label: const Text('去微信充值'),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              foregroundColor: dim,
            ),
          ),
        ),
      ],
    );
  }

  double get _chargeFraction {
    final value = _electricity;
    if (value == null) return 0;
    return (value / 100).clamp(0.0, 1.0).toDouble();
  }

  // ── Error Banner ───────────────────────────────────────────────────────────

  Widget _buildErrorBanner(BuildContext context, ColorScheme cs) {
    // 登录态缺失时统一提示「电费获取失败」，把动作交给下方登录按钮；
    // 其余错误保留服务侧的具体原因。
    final message = _requiresUnifiedAuth
        ? '电费获取失败，登录一卡通后重试'
        : switch (_error) {
            '数据解析失败' => '数据解析失败，请刷新重试',
            final value? => value,
            _ => '请确认已连接校园网络',
          };
    // 中性容器 + 错误色图标表达异常；图标、文案、按钮同处一行并垂直居中，
    // 上下左右使用对称内边距，避免参差的行高与不居中的图标。
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(Icons.wifi_off_outlined, size: 18, color: cs.error),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(fontSize: 13, height: 1.35, color: cs.onSurface),
            ),
          ),
          if (_requiresUnifiedAuth) ...[
            const SizedBox(width: 12),
            FilledButton.tonal(
              onPressed: _loginAndRetry,
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 18),
              ),
              child: const Text('登录'),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _loginAndRetry() async {
    final loggedIn = await showUnifiedAuthLoginModal(
      context,
      title: '登录一卡通',
      description: '登录一卡通后在后台完成电费认证，当前页面仍保持原生界面',
    );
    if (!mounted || !loggedIn) return;

    await _service.invalidateGatewaySession();
    if (!mounted) return;
    await _load(forceRefresh: true);
  }
}

// ── Info Row ────────────────────────────────────────────────────────────────

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.accent,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dim = cs.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    color: dim,
                    letterSpacing: 0.2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface,
                    fontFeatures: const [FontFeature.tabularFigures()],
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

// ── Color Set ────────────────────────────────────────────────────────────────

class _ElectricityColors {
  const _ElectricityColors({required this.primary, required this.label});

  final Color primary;
  final String label;
}
