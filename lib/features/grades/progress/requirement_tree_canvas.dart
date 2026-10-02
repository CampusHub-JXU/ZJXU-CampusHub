import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/app_design_tokens.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/widgets/detail_readout.dart';
import 'academic_progress_model.dart';

/// 学分要求树的画布布局（纯函数，便于测试）。
///
/// 从左到右按层级排列：每个末节点占一行，父节点竖直居中于首尾子节点之间。
/// 树深只有 3–4 层而末节点很多，横排能让竖屏同时看到更多类别。
class RequirementTreeLayout {
  const RequirementTreeLayout({
    required this.nodes,
    required this.edges,
    required this.size,
  });

  static const double nodeWidth = 132;
  static const double nodeHeight = 72;
  static const double columnGap = 32;
  static const double rowGap = 10;

  /// 画布四周留白 = 页边距；平移边界不再额外加 margin，四边一致。
  static const double padding = AppSpacing.pageMargin;

  /// 节点 ID → 画布上的矩形。
  final Map<String, Rect> nodes;
  final List<RequirementTreeEdge> edges;
  final Size size;
}

/// 父 → 子连线；[alternative] 为「或者」关系（画虚线）。
class RequirementTreeEdge {
  const RequirementTreeEdge(this.from, this.to, {this.alternative = false});

  final Offset from;
  final Offset to;
  final bool alternative;
}

RequirementTreeLayout layoutRequirementTree(List<RequirementNode> roots) {
  const w = RequirementTreeLayout.nodeWidth;
  const h = RequirementTreeLayout.nodeHeight;
  const pad = RequirementTreeLayout.padding;
  final nodes = <String, Rect>{};
  final edges = <RequirementTreeEdge>[];
  var row = 0;
  var maxDepth = 0;

  double place(RequirementNode node, int depth) {
    maxDepth = math.max(maxDepth, depth);
    final left = pad + depth * (w + RequirementTreeLayout.columnGap);
    final double top;
    if (node.children.isEmpty) {
      top = pad + row * (h + RequirementTreeLayout.rowGap);
      row++;
    } else {
      final childTops = [
        for (final child in node.children) place(child, depth + 1),
      ];
      top = (childTops.first + childTops.last) / 2;
    }
    final rect = Rect.fromLTWH(left, top, w, h);
    nodes[node.id] = rect;
    for (final child in node.children) {
      final childRect = nodes[child.id]!;
      edges.add(
        RequirementTreeEdge(
          rect.centerRight,
          childRect.centerLeft,
          alternative:
              node.children.length > 1 &&
              node.relation != RequirementRelation.all,
        ),
      );
    }
    return top;
  }

  for (final root in roots) {
    place(root, 0);
  }
  final width =
      pad * 2 + (maxDepth + 1) * w + maxDepth * RequirementTreeLayout.columnGap;
  final height = row == 0
      ? pad * 2
      : pad * 2 + row * h + (row - 1) * RequirementTreeLayout.rowGap;
  return RequirementTreeLayout(
    nodes: nodes,
    edges: edges,
    size: Size(width, height),
  );
}

/// 学分要求树画布：可拖动 / 缩放，平移限制在树的边界内，最小缩放为
/// 「整棵树放得下」。点末节点回调 [onLeafTap]（由页面弹出课程列表）。
///
/// 节点用平色填充，不用 `AppTileSurface`：真实模糊在变换下会持续重绘。
class RequirementTreeCanvas extends StatefulWidget {
  const RequirementTreeCanvas({
    super.key,
    required this.roots,
    required this.onLeafTap,
  });

  final List<RequirementNode> roots;
  final ValueChanged<RequirementNode> onLeafTap;

  @override
  State<RequirementTreeCanvas> createState() => _RequirementTreeCanvasState();
}

class _RequirementTreeCanvasState extends State<RequirementTreeCanvas> {
  static const double _maxScale = 2.5;

  late RequirementTreeLayout _layout;
  late List<RequirementNode> _flat;
  final _controller = TransformationController();

  @override
  void initState() {
    super.initState();
    _relayout();
  }

  @override
  void didUpdateWidget(RequirementTreeCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.roots, widget.roots)) _relayout();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _relayout() {
    _layout = layoutRequirementTree(widget.roots);
    _flat = [for (final root in widget.roots) ..._descendants(root)];
  }

  static Iterable<RequirementNode> _descendants(RequirementNode node) sync* {
    yield node;
    for (final child in node.children) {
      yield* _descendants(child);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final size = _layout.size;
    return LayoutBuilder(
      builder: (context, constraints) {
        final fit = math.min(
          constraints.maxWidth / size.width,
          constraints.maxHeight / size.height,
        );
        return InteractiveViewer(
          transformationController: _controller,
          constrained: false,
          minScale: math.min(1, fit),
          maxScale: _maxScale,
          child: SizedBox.fromSize(
            size: size,
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _EdgePainter(
                      _layout.edges,
                      color: cs.outlineVariant,
                    ),
                  ),
                ),
                for (final node in _flat)
                  Positioned.fromRect(
                    rect: _layout.nodes[node.id]!,
                    child: _TreeNodeCard(
                      node: node,
                      onTap: node.children.isEmpty
                          ? () => widget.onLeafTap(node)
                          : null,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _TreeNodeCard extends StatelessWidget {
  const _TreeNodeCard({required this.node, this.onTap});

  final RequirementNode node;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final req = node.requiredCredits;
    final earned = node.earnedCredits ?? 0;
    final hasProgress = req != null && req > 0;
    final String meta;
    if (hasProgress) {
      meta = '${_fmt(earned)}/${_fmt(req)} 学分';
    } else if (node.id == RequirementNode.innovationId &&
        node.courses.isEmpty) {
      meta = '尚无数据';
    } else if (node.children.isEmpty) {
      meta = '共 ${node.courseTotal} 门 · 通过 ${node.passedTotal}';
    } else {
      meta = node.earnedCredits != null ? '获得 ${_fmt(earned)} 学分' : '';
    }
    final relation =
        node.children.length > 1 && node.relation != RequirementRelation.all
        ? ' · ${node.relation.label}'
        : '';
    final met = hasProgress && earned >= req;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 与校园卡动作格（AppTileSurface 亚克力）同色同描边，但不做背景模糊。
    return Material(
      color: isDark ? cs.surfaceContainerLow : cs.surfaceContainerLowest,
      shape: RoundedSuperellipseBorder(
        borderRadius: AppRadius.tileBorder,
        side: BorderSide(
          color: isDark
              ? Colors.white.withValues(alpha: 0.1)
              : cs.outlineVariant.withValues(alpha: 0.5),
          width: isDark ? 0.8 : 1.0,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                node.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.appText.secondary.copyWith(color: cs.onSurface),
              ),
              if ('$meta$relation'.isNotEmpty)
                Text(
                  '$meta$relation',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.appText.meta,
                ),
              if (hasProgress) ...[
                const SizedBox(height: 6),
                SizedBox(
                  width: double.infinity,
                  child: DetailLevelBar(
                    fraction: earned / req,
                    color: met ? cs.primary : cs.tertiary,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 直角折线：父节点右中 → 列间中线 → 子节点左中；「或者」画虚线。
class _EdgePainter extends CustomPainter {
  const _EdgePainter(this.edges, {required this.color});

  final List<RequirementTreeEdge> edges;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    for (final edge in edges) {
      final midX = (edge.from.dx + edge.to.dx) / 2;
      final points = [
        edge.from,
        Offset(midX, edge.from.dy),
        Offset(midX, edge.to.dy),
        edge.to,
      ];
      for (var i = 0; i < points.length - 1; i++) {
        if (edge.alternative) {
          _dashed(canvas, points[i], points[i + 1], paint);
        } else {
          canvas.drawLine(points[i], points[i + 1], paint);
        }
      }
    }
  }

  static void _dashed(Canvas canvas, Offset a, Offset b, Paint paint) {
    const dash = 4.0;
    const gap = 3.0;
    final total = (b - a).distance;
    if (total == 0) return;
    final dir = (b - a) / total;
    for (var d = 0.0; d < total; d += dash + gap) {
      canvas.drawLine(a + dir * d, a + dir * math.min(d + dash, total), paint);
    }
  }

  @override
  bool shouldRepaint(_EdgePainter old) =>
      !identical(old.edges, edges) || old.color != color;
}

String _fmt(double value) => value == value.roundToDouble()
    ? value.toStringAsFixed(0)
    : value.toStringAsFixed(1);
