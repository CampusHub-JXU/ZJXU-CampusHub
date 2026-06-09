import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/notification/app_notification_service.dart';
import 'dorm_electricity_service.dart';

class DormElectricityPage extends StatefulWidget {
  const DormElectricityPage({super.key});

  @override
  State<DormElectricityPage> createState() => _DormElectricityPageState();
}

class _DormElectricityPageState extends State<DormElectricityPage>
    with SingleTickerProviderStateMixin {
  final _service = DormElectricityService.instance;
  double? _electricity;
  bool _loading = true;
  bool _hasConfig = false;
  String? _error;
  late AnimationController _batteryAnimController;
  late Animation<double> _batteryAnim;

  @override
  void initState() {
    super.initState();
    _batteryAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _batteryAnim = CurvedAnimation(
      parent: _batteryAnimController,
      curve: Curves.easeOutCubic,
    );
    _load(forceRefresh: true);
  }

  @override
  void dispose() {
    _batteryAnimController.dispose();
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
          _batteryAnimController.forward(from: 0);
        } else if (_electricity != oldValue) {
          _batteryAnimController.forward(from: 0);
        }
      }
    }
    if (!mounted) return;
    setState(() => _loading = false);
  }

  _ElectricityColors _resolveColors(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final value = _electricity;
    if (value == null) {
      return _ElectricityColors(
        primary: AppColors.success,
        background: AppColors.success.withValues(alpha: 0.08),
        cardBg: cs.surfaceContainerLow,
        label: '未知',
      );
    }
    if (value >= 50) {
      return _ElectricityColors(
        primary: const Color(0xFF16A34A),
        background: const Color(0xFF16A34A).withValues(alpha: 0.06),
        cardBg: cs.surfaceContainerLow,
        label: '充足',
      );
    }
    if (value >= 20) {
      return _ElectricityColors(
        primary: const Color(0xFFF59E0B),
        background: const Color(0xFFF59E0B).withValues(alpha: 0.06),
        cardBg: cs.surfaceContainerLow,
        label: '适中',
      );
    }
    if (value >= 10) {
      return _ElectricityColors(
        primary: const Color(0xFFF97316),
        background: const Color(0xFFF97316).withValues(alpha: 0.06),
        cardBg: cs.surfaceContainerLow,
        label: '偏低',
      );
    }
    return _ElectricityColors(
      primary: const Color(0xFFDC2626),
      background: const Color(0xFFDC2626).withValues(alpha: 0.06),
      cardBg: cs.surfaceContainerLow,
      label: '不足',
    );
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
          : _buildContent(context, cs),
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

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (_error != null) ...[
            _buildErrorBanner(cs),
            const SizedBox(height: 14),
          ],
          _buildElectricityDetailCard(context, cs, colors, value),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _InfoTile(
                  icon: Icons.access_time_rounded,
                  label: '更新时间',
                  value: updatedAtText,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _InfoTile(
                  icon: Icons.speed_rounded,
                  label: '预警阈值',
                  value:
                      '${DormElectricityService.defaultAlertThreshold.toInt()}度',
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _InfoTile(
            icon: Icons.notifications_outlined,
            label: '低电量通知',
            value: '低于阈值时推送提醒',
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
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: colors.cardBg,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: colors.primary.withValues(alpha: 0.12),
          width: 0.8,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: _batteryAnim,
            builder: (context, _) {
              return _BatteryHeader(
                fraction: _gaugeFraction,
                animationValue: _batteryAnim.value,
                colors: colors,
              );
            },
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
            child: Column(
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '当前剩余',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Flexible(
                                child: Text(
                                  value,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 48,
                                    fontWeight: FontWeight.w900,
                                    height: 0.95,
                                    color: colors.primary,
                                  ),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.only(
                                  left: 5,
                                  bottom: 4,
                                ),
                                child: Text(
                                  '度',
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                    color: colors.primary.withValues(
                                      alpha: 0.72,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    _ElectricityStatePill(colors: colors),
                  ],
                ),
                if (_electricity != null && _electricity! < 10) ...[
                  const SizedBox(height: 14),
                  Container(
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
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  double get _gaugeFraction {
    final value = _electricity;
    if (value == null) return 0;
    return (value / 100).clamp(0.0, 1.0);
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

// ── Battery Header ──────────────────────────────────────────────────────────

class _BatteryHeader extends StatelessWidget {
  const _BatteryHeader({
    required this.fraction,
    required this.animationValue,
    required this.colors,
  });

  final double fraction;
  final double animationValue;
  final _ElectricityColors colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 148,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF202124), Color(0xFF303236)],
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  '电量详情',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.08),
                  ),
                ),
                child: Text(
                  colors.label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: colors.primary,
                  ),
                ),
              ),
            ],
          ),
          const Spacer(),
          SizedBox(
            width: double.infinity,
            height: 58,
            child: CustomPaint(
              painter: _BatteryTrackPainter(
                fraction: fraction,
                animationValue: animationValue,
                fillColor: colors.primary,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Text(
                '0 度',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: Colors.white.withValues(alpha: 0.42),
                ),
              ),
              const Spacer(),
              Text(
                '100 度',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: Colors.white.withValues(alpha: 0.42),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _BatteryTrackPainter extends CustomPainter {
  _BatteryTrackPainter({
    required this.fraction,
    required this.animationValue,
    required this.fillColor,
  });

  final double fraction;
  final double animationValue;
  final Color fillColor;

  @override
  void paint(Canvas canvas, Size size) {
    final bodyRect = Rect.fromLTWH(0, 6, size.width - 18, size.height - 12);
    final bodyRadius = Radius.circular(bodyRect.height / 2.8);
    final bodyRRect = RRect.fromRectAndRadius(bodyRect, bodyRadius);

    canvas.drawRRect(
      bodyRRect,
      Paint()..color = Colors.white.withValues(alpha: 0.08),
    );
    canvas.drawRRect(
      bodyRRect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.white.withValues(alpha: 0.14),
    );

    final terminalRect = Rect.fromLTWH(
      bodyRect.right + 5,
      size.height / 2 - 10,
      10,
      20,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(terminalRect, const Radius.circular(3)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = Colors.white.withValues(alpha: 0.32),
    );

    final innerRect = bodyRect.deflate(9);
    final progress = (fraction * animationValue).clamp(0.0, 1.0);
    final fillRight = innerRect.left + innerRect.width * progress;
    const dotSize = 3.1;
    const dotGap = 3.0;

    for (var y = innerRect.top; y <= innerRect.bottom - dotSize; y += 6.1) {
      for (var x = innerRect.left; x <= innerRect.right - dotSize; x += 6.1) {
        final dotCenterX = x + dotSize / 2;
        final lit = dotCenterX <= fillRight;
        final normalizedX = ((dotCenterX - innerRect.left) / innerRect.width)
            .clamp(0.0, 1.0);
        final alpha = lit ? 0.36 + normalizedX * 0.52 : 0.08;
        final dotColor = lit
            ? Color.lerp(
                fillColor.withValues(alpha: 0.64),
                Colors.white,
                normalizedX * 0.12,
              )!.withValues(alpha: alpha)
            : Colors.white.withValues(alpha: alpha);

        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, y, dotSize, dotSize),
            const Radius.circular(0.8),
          ),
          Paint()..color = dotColor,
        );
      }
    }

    if (progress <= 0) return;

    final capCenterX = fillRight
        .clamp(innerRect.left + 12, innerRect.right - 12)
        .toDouble();
    final capRect = Rect.fromCenter(
      center: Offset(capCenterX, innerRect.center.dy),
      width: 24,
      height: innerRect.height + dotGap,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(capRect, const Radius.circular(8)),
      Paint()..color = Colors.white.withValues(alpha: 0.95),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(capRect.deflate(1.2), const Radius.circular(7)),
      Paint()..color = fillColor.withValues(alpha: 0.08),
    );
  }

  @override
  bool shouldRepaint(_BatteryTrackPainter old) =>
      fraction != old.fraction ||
      animationValue != old.animationValue ||
      fillColor != old.fillColor;
}

class _ElectricityStatePill extends StatelessWidget {
  const _ElectricityStatePill({required this.colors});

  final _ElectricityColors colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '电量${colors.label}',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: colors.primary,
        ),
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
    this.trailing,
  });

  final IconData icon;
  final String label;
  final String value;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: cs.outlineVariant.withValues(alpha: 0.4),
          width: 0.8,
        ),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: cs.onSurfaceVariant),
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
    required this.background,
    required this.cardBg,
    required this.label,
  });

  final Color primary;
  final Color background;
  final Color cardBg;
  final String label;
}
