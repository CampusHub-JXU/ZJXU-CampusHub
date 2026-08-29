import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/notification/app_notification_service.dart';
import 'dorm_electricity_service.dart';
import 'widgets/electricity_battery_header.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_empty_view.dart';

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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final value = _electricity;

    if (value == null) {
      // 未知状态用主题色，暗色酒红下提亮避免字体发脏。
      final unknownAccent = isDark
          ? HSLColor.fromColor(cs.primary)
                .withLightness(
                  (HSLColor.fromColor(cs.primary).lightness + 0.12).clamp(
                    0.5,
                    0.7,
                  ),
                )
                .withSaturation(
                  (HSLColor.fromColor(cs.primary).saturation * 0.9).clamp(
                    0.4,
                    0.7,
                  ),
                )
                .toColor()
          : cs.primary;
      return _ElectricityColors(primary: unknownAccent, label: '未知');
    }
    // 状态色保持纯净，不再与品牌酒红 lerp，避免暗色下变脏。
    return _ElectricityColors(
      primary: _statusColorFor(value, isDark: isDark),
      label: _statusLabelFor(value),
    );
  }

  Color _statusColorFor(double value, {required bool isDark}) {
    const safe = Color(0xFF16A34A);
    const warning = Color(0xFFE79A16);
    const low = Color(0xFFE86A1A);
    const danger = Color(0xFFC73434);

    Color resolve(Color c) {
      if (!isDark) return c;
      // 暗色下统一提亮 + 略降饱和，避免低明度状态色在深背景上发脏。
      final hsl = HSLColor.fromColor(c);
      return hsl
          .withLightness((hsl.lightness + 0.08).clamp(0.45, 0.68))
          .withSaturation((hsl.saturation * 0.92).clamp(0.4, 0.72))
          .toColor();
    }

    if (value >= 50) return resolve(safe);
    if (value >= 20) {
      final t = ((value - 20) / 30).clamp(0.0, 1.0).toDouble();
      return resolve(Color.lerp(warning, safe, t)!);
    }
    if (value >= 10) {
      final t = ((value - 10) / 10).clamp(0.0, 1.0).toDouble();
      return resolve(Color.lerp(low, warning, t)!);
    }
    final t = (value / 10).clamp(0.0, 1.0).toDouble();
    return resolve(Color.lerp(danger, low, t)!);
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
              _load(forceRefresh: true);
            },
          ),
        ],
      ),
      body: _loading
          ? _buildLoadingState(cs)
          : !_hasConfig
          ? _buildNoConfig(context)
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

  Widget _buildNoConfig(BuildContext context) {
    return AppEmptyView(
      title: '尚未配置寝室',
      message: '选择寝室后即可查看剩余电量',
      icon: Icons.home_outlined,
      actionLabel: '去选择寝室',
      onAction: () async {
        await context.pushNamed('dorm-electricity-settings');
        _load(forceRefresh: true);
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
            _buildErrorBanner(cs),
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
                  value:
                      '${DormElectricityService.defaultAlertThreshold.toInt()} 度',
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
                          '低于阈值时推送提醒',
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
      ],
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
