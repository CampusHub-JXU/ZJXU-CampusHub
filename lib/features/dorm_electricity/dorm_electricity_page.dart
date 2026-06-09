import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/notification/app_notification_service.dart';
import 'dorm_electricity_service.dart';
import 'widgets/electricity_battery_header.dart';

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
  bool _hasConfig = false;
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
      duration: const Duration(milliseconds: 3200),
    );
    _matrixBreathAnim ??= CurvedAnimation(
      parent: breathController,
      curve: Curves.easeInOut,
    );
    if (!breathController.isAnimating) {
      breathController.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _matrixFillController?.dispose();
    _matrixBreathController?.dispose();
    super.dispose();
  }

  Future<void> _load({bool forceRefresh = false}) async {
    setState(() => _loading = true);
    _hasConfig = await _service.hasRoomConfig();
    if (_hasConfig) {
      final oldValue = _electricity;
      _electricity = await _service.fetchElectricity(
        forceRefresh: forceRefresh,
      );
      _error = _service.lastError;

      if (forceRefresh) {
        await _service.checkAndAlert(
          onAlert: ({required value, required threshold}) {
            AppNotificationService.instance.showNotification(
              id: 100,
              title: '寝室电费不足',
              body:
                  '剩余电量 ${_service.formatElectricity(value)} 度，'
                  '低于 ${threshold.toInt()} 度阈值，请及时充值',
              payload: 'dorm-electricity',
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
    if (!mounted) return;
    setState(() => _loading = false);
  }

  _ElectricityColors _resolveColors(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isLight = Theme.of(context).brightness == Brightness.light;
    final value = _electricity;
    _ElectricityColors buildColors(Color statusColor, String label) {
      final accent = Color.lerp(statusColor, cs.primary, isLight ? 0.18 : 0.1)!;
      return _ElectricityColors(
        primary: accent,
        cardBg: isLight ? cs.surfaceContainerLowest : cs.surfaceContainerLow,
        label: label,
      );
    }

    if (value == null) {
      return buildColors(cs.primary, '未知');
    }
    return buildColors(_statusColorFor(value), _statusLabelFor(value));
  }

  Color _statusColorFor(double value) {
    const safe = Color(0xFF16A34A);
    const warning = Color(0xFFE79A16);
    const low = Color(0xFFE86A1A);
    const danger = Color(0xFFC73434);

    if (value >= 50) return safe;
    if (value >= 20) {
      final t = ((value - 20) / 30).clamp(0.0, 1.0).toDouble();
      return Color.lerp(warning, safe, t)!;
    }
    if (value >= 10) {
      final t = ((value - 10) / 10).clamp(0.0, 1.0).toDouble();
      return Color.lerp(low, warning, t)!;
    }
    final t = (value / 10).clamp(0.0, 1.0).toDouble();
    return Color.lerp(danger, low, t)!;
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
      appBar: AppBar(
        title: const Text('寝室电费'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '选择寝室',
            onPressed: () async {
              await context.pushNamed('dorm-electricity-settings');
              _load(forceRefresh: true);
            },
          ),
        ],
      ),
      body: _loading
          ? _buildLoadingState(cs)
          : !_hasConfig
          ? _buildNoConfig(context, cs)
          : RefreshIndicator(
              onRefresh: () => _load(forceRefresh: true),
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
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildNoConfig(BuildContext context, ColorScheme cs) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: AppColors.success.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Icon(
                Icons.home_outlined,
                size: 36,
                color: AppColors.success,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              '尚未配置寝室',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '选择寝室后即可查看剩余电量',
              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () async {
                await context.pushNamed('dorm-electricity-settings');
                _load(forceRefresh: true);
              },
              icon: const Icon(Icons.add_home_outlined, size: 18),
              label: const Text('去选择寝室'),
            ),
          ],
        ),
      ),
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
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_error != null) ...[
            _buildErrorBanner(cs),
            const SizedBox(height: 12),
          ],
          _buildElectricityDetailCard(context, cs, colors, value),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _InfoTile(
                  icon: Icons.access_time_outlined,
                  label: '更新时间',
                  value: updatedAtText,
                  iconColor: colors.primary,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _InfoTile(
                  icon: Icons.speed_outlined,
                  label: '预警阈值',
                  value:
                      '${DormElectricityService.defaultAlertThreshold.toInt()}度',
                  iconColor: colors.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _InfoTile(
            icon: Icons.notifications_outlined,
            label: '低电量通知',
            value: '低于阈值时推送提醒',
            iconColor: colors.primary,
            trailing: Icon(
              Icons.arrow_forward_ios,
              size: 13,
              color: cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  // ── Electricity Detail Card ────────────────────────────────────────────────

  Widget _buildElectricityDetailCard(
    BuildContext context,
    ColorScheme cs,
    _ElectricityColors colors,
    String value,
  ) {
    _ensureMatrixAnimations();
    final matrixFillAnim = _matrixFillAnim!;
    final matrixBreathAnim = _matrixBreathAnim!;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: colors.cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: Color.lerp(
            cs.outlineVariant,
            colors.primary,
            0.34,
          )!.withValues(alpha: 0.36),
          width: 0.8,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: Listenable.merge([matrixFillAnim, matrixBreathAnim]),
            builder: (context, _) {
              return TweenAnimationBuilder<Color?>(
                tween: ColorTween(end: colors.primary),
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                builder: (context, animatedColor, _) {
                  final accent = animatedColor ?? colors.primary;
                  final statusBackgroundColor = accent.withValues(
                    alpha: Theme.of(context).brightness == Brightness.light
                        ? 0.1
                        : 0.16,
                  );
                  return RepaintBoundary(
                    child: ElectricityBatteryHeader(
                      valueText: value,
                      statusLabel: colors.label,
                      fraction: _chargeFraction,
                      fillAnimationValue: matrixFillAnim.value,
                      breathValue: matrixBreathAnim.value,
                      accentColor: accent,
                      statusBackgroundColor: statusBackgroundColor,
                    ),
                  );
                },
              );
            },
          ),
          if (_electricity != null && _electricity! < 10)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: cs.errorContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 16,
                      color: cs.onErrorContainer,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '电量不足，请及时充值',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: cs.onErrorContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  double get _chargeFraction {
    final value = _electricity;
    if (value == null) return 0;
    return (value / 100).clamp(0.0, 1.0).toDouble();
  }

  // ── Error Banner ───────────────────────────────────────────────────────────

  Widget _buildErrorBanner(ColorScheme cs) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: cs.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.wifi_off_outlined, size: 18, color: cs.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(switch (_error) {
              '数据解析失败' => '数据解析失败，请刷新重试',
              final message? => message,
              _ => '请确认已连接校园网络',
            }, style: TextStyle(fontSize: 13, color: cs.onErrorContainer)),
          ),
        ],
      ),
    );
  }
}

// ── Info Tile ────────────────────────────────────────────────────────────────

class _InfoTile extends StatelessWidget {
  const _InfoTile({
    required this.icon,
    required this.label,
    required this.value,
    this.iconColor,
    this.trailing,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color? iconColor;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isLight = Theme.of(context).brightness == Brightness.light;
    final resolvedIconColor = iconColor ?? cs.primary;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
      decoration: BoxDecoration(
        color: isLight ? cs.surfaceContainerLowest : cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: Color.lerp(
            cs.outlineVariant,
            resolvedIconColor,
            0.12,
          )!.withValues(alpha: isLight ? 0.5 : 0.32),
          width: 0.8,
        ),
        boxShadow: isLight
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.025),
                  blurRadius: 14,
                  offset: const Offset(0, 6),
                ),
              ]
            : null,
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: resolvedIconColor),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: 1),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface,
                  ),
                ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

// ── Color Set ────────────────────────────────────────────────────────────────

class _ElectricityColors {
  const _ElectricityColors({
    required this.primary,
    required this.cardBg,
    required this.label,
  });

  final Color primary;
  final Color cardBg;
  final String label;
}
