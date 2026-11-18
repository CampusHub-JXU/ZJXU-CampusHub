import 'package:material_ui/material_ui.dart';

import '../../core/theme/app_design_tokens.dart';
import '../../core/theme/app_typography.dart';
import 'app_tile_surface.dart';

/// 单值详情页（校园卡余额 / 寝室电量）的无框读数：标签行 + 大号数字 + 单位，
/// 直接落在页面底色上，不套卡（见 design-guidelines 4.7）。
class DetailReadout extends StatelessWidget {
  const DetailReadout({
    super.key,
    required this.label,
    required this.valueText,
    this.unit,
    this.trailing,
    this.muted = false,
  });

  /// 标签行文字，如「剩余电量」「校园卡余额」。
  final String label;

  /// 主数值；无数据传 `--`，隐藏传 `****`。
  final String valueText;

  /// 写在数字后的单位，如「度」「元」；无单位的量（GPA）传 null。
  final String? unit;

  /// 标签行尾元素（状态文字或 44×44 图标按钮）。
  final Widget? trailing;

  /// 占位态（无数据）：数字转 `outlineVariant`，不与真实读数同权重。
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = context.appText;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.label,
                ),
              ),
              ?trailing,
            ],
          ),
        ),
        // 大字号 / 窄屏下数字与单位整体等比缩小，不挤压换行。
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                valueText,
                style: muted
                    ? text.readout.copyWith(color: cs.outlineVariant)
                    : text.readout,
              ),
              if (unit != null) ...[
                const SizedBox(width: AppSpacing.sm),
                Text(unit!, style: text.unit),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// 有上限的量（电量 / 学分进度）用的 6dp 细实心电平条。
///
/// **首帧直接落在目标长度**：详情页 push / pop 回来后的重挂载、旋转、主题
/// 切换、同值刷新都不会重播 `0 → 目标` 的入场动画——缓存读数必须一次到位，
/// 不能每次进页都从零走满。只有挂载之后 [fraction] 真实变化时，才从**当前
/// 长度**做一次 600ms ease-out 过渡到新长度（不会先回到 0）；系统开启
/// 「减弱动效」时任何变化都直接到位。没有任何循环动画（`pumpAndSettle` 能结束）。
class DetailLevelBar extends StatelessWidget {
  const DetailLevelBar({super.key, required this.fraction, this.color});

  /// 0–1 的填充比例，越界自动钳制。
  final double fraction;

  /// 填充色；为空取 `colorScheme.primary`。
  final Color? color;

  /// 真实值变化时的过渡时长；挂载首帧不经过它。
  static const Duration _changeDuration = Duration(milliseconds: 600);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final target = fraction.clamp(0.0, 1.0).toDouble();
    final fillColor = color ?? cs.primary;
    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: SizedBox(
          height: 6,
          child: ColoredBox(
            color: cs.surfaceContainerHighest,
            // 系统「移除动画」：直接渲染目标，连控制器都不建，变化也瞬时到位。
            child: MediaQuery.disableAnimationsOf(context)
                ? _fill(fillColor, target)
                : TweenAnimationBuilder<double>(
                    // begin == end：挂载首帧即为目标长度，不重播 0→目标。
                    // begin 只在首次挂载生效，之后被忽略；end 变化时
                    // TweenAnimationBuilder 会从「当前长度」过渡到新值。
                    tween: Tween<double>(begin: target, end: target),
                    duration: _changeDuration,
                    curve: Curves.easeOutCubic,
                    builder: (context, value, _) => _fill(fillColor, value),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _fill(Color fillColor, double value) {
    return FractionallySizedBox(
      alignment: Alignment.centerLeft,
      widthFactor: value,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: fillColor,
          borderRadius: BorderRadius.circular(3),
        ),
      ),
    );
  }
}

/// [DetailActionGrid] 的一格动作。
class DetailAction {
  const DetailAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.primary = false,
  });

  final IconData icon;
  final String title;

  /// 当前状态或去向（「微信」「低于 20 度」），不写空话。
  final String subtitle;
  final VoidCallback onTap;

  /// 页面主动作：`primary` 实底 / `onPrimary` 字；其余格走 [AppTileSurface]。
  final bool primary;
}

/// 读数下方的等宽动作瓦片行：图标在上、标题 + 副标题在下、左对齐。
class DetailActionGrid extends StatelessWidget {
  const DetailActionGrid({super.key, required this.actions});

  final List<DetailAction> actions;

  static const double _gap = 10;
  static const double _minHeight = 104;

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < actions.length; i++) ...[
            if (i > 0) const SizedBox(width: _gap),
            Expanded(child: _buildTile(context, actions[i])),
          ],
        ],
      ),
    );
  }

  Widget _buildTile(BuildContext context, DetailAction action) {
    final cs = Theme.of(context).colorScheme;
    final text = context.appText;
    final primary = action.primary;
    final content = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: _minHeight),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Icon(
              action.icon,
              size: 24,
              color: primary ? cs.onPrimary : cs.primary,
            ),
            const SizedBox(height: AppSpacing.md),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  action.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: primary
                      ? text.rowTitle.copyWith(color: cs.onPrimary)
                      : text.rowTitle,
                ),
                const SizedBox(height: 2),
                Text(
                  action.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: primary
                      ? text.meta.copyWith(
                          color: cs.onPrimary.withValues(alpha: 0.82),
                        )
                      : text.meta,
                ),
              ],
            ),
          ],
        ),
      ),
    );
    final tile = primary
        ? Material(
            color: cs.primary,
            shape: RoundedSuperellipseBorder(
              borderRadius: BorderRadius.circular(AppRadius.tile),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(onTap: action.onTap, child: content),
          )
        : AppTileSurface(
            padding: EdgeInsets.zero,
            onTap: action.onTap,
            child: content,
          );
    return Semantics(
      button: true,
      label: '${action.title}，${action.subtitle}',
      excludeSemantics: true,
      onTap: action.onTap,
      child: tile,
    );
  }
}
