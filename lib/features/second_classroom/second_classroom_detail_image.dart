part of 'second_classroom_page.dart';

/// 活动详情顶部的图片（活动海报 / 报名二维码）。
///
/// 详情页图片此前按 16:9 `BoxFit.cover` 展示，二维码下半部分被父容器裁掉，
/// 且整块不可点击（issue #86）。这里改为**完整展示、不裁切**：
///
/// * 外框固定 1:1，图片在框内 `BoxFit.contain`，避免任何方向被裁；
/// * 白底 + 四周留出 [_quietZone] 的空白边界，保证二维码扫码所需的 quiet zone；
/// * 外框宽度受 [_maxWidth] 约束，窄屏 / 系统字体放大时也不会溢出；
/// * 点击打开大图预览（[InteractiveViewer] 可缩放），加载中 / 加载失败 / 无图
///   都有可交互的反馈，不留无法点击的空白区。
class _ActivityDetailImage extends StatefulWidget {
  const _ActivityDetailImage({
    required this.imageUrl,
    this.statusLabel,
    this.statusTone = AppStatusTone.neutral,
  });

  final String imageUrl;
  final String? statusLabel;
  final AppStatusTone statusTone;

  @override
  State<_ActivityDetailImage> createState() => _ActivityDetailImageState();
}

class _ActivityDetailImageState extends State<_ActivityDetailImage> {
  static const double _maxWidth = 320;

  /// 白底留白：二维码四边需要连续浅色区域才能被稳定识别。
  static const double _quietZone = 12;

  /// 加载失败后点「重试」重建图片用的令牌（同时清掉失败缓存）。
  int _reloadToken = 0;

  void _retry() {
    // 与 build 一致地 trim：缓存键必须和实际请求的 URL 相同，否则清不掉失败项。
    PaintingBinding.instance.imageCache.evict(
      NetworkImage(widget.imageUrl.trim()),
    );
    setState(() => _reloadToken++);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final imageUrl = widget.imageUrl.trim();
    final hasImage = imageUrl.isNotEmpty;
    final statusLabel = widget.statusLabel;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 招募状态标签放在 1:1 图片区域**之外**：它原先叠在图片左上角，
        // 正好压住二维码的定位图案（finder pattern），导致扫码失败。
        if (statusLabel != null && statusLabel.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: Align(
              alignment: Alignment.centerLeft,
              child: AppStatusTag(statusLabel, tone: widget.statusTone),
            ),
          ),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _maxWidth),
            child: AspectRatio(
              aspectRatio: 1,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.card),
                child: Material(
                  // 二维码需要纯白底色与留白才能被扫描设备识别；无图时退回中性
                  // 底色，不假装有一张二维码。
                  color: hasImage ? Colors.white : cs.surfaceContainerHighest,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (!hasImage)
                        Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.image_outlined,
                                color: cs.onSurfaceVariant,
                                size: 40,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                '暂无活动图片',
                                textAlign: TextAlign.center,
                                style: context.appText.secondary.copyWith(
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        )
                      else
                        InkWell(
                          onTap: () =>
                              _openActivityImagePreview(context, imageUrl),
                          child: Padding(
                            padding: const EdgeInsets.all(_quietZone),
                            child: Image.network(
                              imageUrl,
                              key: ValueKey(
                                'activity_detail_image:$_reloadToken',
                              ),
                              fit: BoxFit.contain,
                              loadingBuilder: (context, child, progress) =>
                                  progress == null
                                  ? child
                                  : const Center(
                                      child: SizedBox(
                                        width: 28,
                                        height: 28,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.5,
                                        ),
                                      ),
                                    ),
                              errorBuilder: (context, error, stackTrace) =>
                                  _DetailImageLoadError(onRetry: _retry),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (hasImage) ...[
          const SizedBox(height: 8),
          Text(
            '点击查看大图',
            style: context.appText.meta.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}

/// 图片加载失败态：简短文案 + 重试，避免死掉的空白区。
class _DetailImageLoadError extends StatelessWidget {
  const _DetailImageLoadError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.broken_image_outlined,
            color: cs.onSurfaceVariant,
            size: 32,
          ),
          const SizedBox(height: 8),
          Text(
            '图片加载失败',
            textAlign: TextAlign.center,
            style: context.appText.secondary.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }
}

/// 打开活动图片的大图预览（可缩放），沿用 [AppFeedback] 弹层入口。
void _openActivityImagePreview(BuildContext context, String imageUrl) {
  AppFeedback.sheet<void>(
    context,
    scrollControlled: true,
    builder: (sheetContext) => _ActivityImagePreviewSheet(imageUrl: imageUrl),
  );
}

class _ActivityImagePreviewSheet extends StatefulWidget {
  const _ActivityImagePreviewSheet({required this.imageUrl});

  final String imageUrl;

  @override
  State<_ActivityImagePreviewSheet> createState() =>
      _ActivityImagePreviewSheetState();
}

class _ActivityImagePreviewSheetState
    extends State<_ActivityImagePreviewSheet> {
  int _reloadToken = 0;

  void _retry() {
    PaintingBinding.instance.imageCache.evict(NetworkImage(widget.imageUrl));
    setState(() => _reloadToken++);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.82,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.xs,
              AppSpacing.sm,
              0,
            ),
            child: Row(
              children: [
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    '活动图片',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  tooltip: '关闭',
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.xs,
                AppSpacing.md,
                AppSpacing.md,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.card),
                // 白底让二维码在预览里同样保持 quiet zone。
                child: ColoredBox(
                  color: Colors.white,
                  child: InteractiveViewer(
                    minScale: 1,
                    maxScale: 4,
                    child: Center(
                      child: Image.network(
                        widget.imageUrl,
                        key: ValueKey('activity_image_preview:$_reloadToken'),
                        fit: BoxFit.contain,
                        loadingBuilder: (context, child, progress) =>
                            progress == null
                            ? child
                            : const Center(
                                child: SizedBox(
                                  width: 28,
                                  height: 28,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                  ),
                                ),
                              ),
                        errorBuilder: (context, error, stackTrace) =>
                            _DetailImageLoadError(onRetry: _retry),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
