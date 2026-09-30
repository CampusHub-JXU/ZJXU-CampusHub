import 'package:flutter/material.dart';

/// 数据卡底部的一行刷新状态：「HH:mm 更新 · 正在刷新」。
///
/// 统一替代各页的通栏「刷新xx / 正在刷新」按钮（见 design-guidelines 4.5）：
/// 刷新中显示 12px 小 spinner；失败时改为「· 刷新失败」并转 error 色，
/// 时间始终是上次成功的时间，不以缓存冒充本次刷新成功。
///
/// [onRefresh] 非空时在行尾放一个 44×44 的刷新图标（刷新中禁用）。
class RefreshStatusLine extends StatelessWidget {
  const RefreshStatusLine({
    super.key,
    this.updatedAt,
    this.refreshing = false,
    this.failed = false,
    this.loadingLabel = '正在获取…',
    this.onRefresh,
    this.refreshTooltip = '刷新',
    this.color,
    this.prefix,
    this.now,
  });

  /// 上次成功更新的时间；为空表示还没有任何数据。
  final DateTime? updatedAt;
  final bool refreshing;
  final bool failed;

  /// 没有 [updatedAt] 且正在刷新时的文案（首次加载）。
  final String loadingLabel;
  final VoidCallback? onRefresh;
  final String refreshTooltip;

  /// 覆盖文字 / spinner 颜色（放在 primaryContainer 等彩色卡上时用）。
  final Color? color;

  /// 拼在时间文案之前的读数补充（如「47% · 满电 100 度」），以「 · 」相连。
  final String? prefix;

  /// 测试注入的当前时间。
  final DateTime? now;

  static String formatUpdatedAt(DateTime time, DateTime now) {
    String two(int v) => v.toString().padLeft(2, '0');
    final hm = '${two(time.hour)}:${two(time.minute)}';
    final sameDay =
        time.year == now.year && time.month == now.month && time.day == now.day;
    return sameDay ? hm : '${time.month}月${time.day}日 $hm';
  }

  String _label(DateTime now) {
    final status = _statusLabel(now);
    final lead = prefix;
    return lead == null || lead.isEmpty ? status : '$lead · $status';
  }

  String _statusLabel(DateTime now) {
    final time = updatedAt;
    if (time == null) {
      if (refreshing) return loadingLabel;
      return failed ? '获取失败' : '尚未更新';
    }
    final base = '${formatUpdatedAt(time, now)} 更新';
    if (refreshing) return '$base · 正在刷新';
    if (failed) return '$base · 刷新失败';
    return base;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final baseColor = color ?? cs.onSurfaceVariant;
    final textColor = failed && !refreshing ? cs.error : baseColor;
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(
          fontSize: 12,
          color: textColor,
        );

    return Semantics(
      liveRegion: true,
      child: Row(
        children: [
          if (refreshing) ...[
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: baseColor,
              ),
            ),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Text(
              _label(now ?? DateTime.now()),
              style: style,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (onRefresh != null)
            SizedBox(
              width: 44,
              height: 44,
              child: IconButton(
                tooltip: refreshTooltip,
                padding: EdgeInsets.zero,
                iconSize: 18,
                color: color ?? cs.primary,
                onPressed: refreshing ? null : onRefresh,
                icon: const Icon(Icons.refresh_rounded),
              ),
            ),
        ],
      ),
    );
  }
}
