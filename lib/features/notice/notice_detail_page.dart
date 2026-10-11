import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../core/notice/notice_detail.dart';
import '../../core/notice/notice_detail_service.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_error_view.dart';
import '../../shared/widgets/app_feedback.dart';
import '../../shared/widgets/auth_required_view.dart';
import '../../shared/widgets/copy_text_feedback.dart';
import '../../shared/widgets/login_shell.dart';
import '../../shared/widgets/system_downloader.dart';

/// 原网页（受统一认证保护的 WebView）路由参数：详情页兜底与「查看原网页」
/// 共用，与改造前列表直接打开 WebView 的参数一致。
Map<String, Object?> noticeOriginalPageExtra({
  required String title,
  required String url,
}) => {
  'title': title,
  'url': url,
  'emulateDingTalkEnvironment': false,
  'requireUnifiedAuthProtection': true,
  'serviceUrl': url,
  'loginDescription': '通知公告可直连访问，但需先完成统一认证',
  'showWebViewBottomBackButton': true,
  'warmUpAsResource': true,
};

/// 教务处公告原生阅读页：站点没有移动版，这里抽取正文用原生排版展示；
/// 结构不识别 / 复杂表格一律引导查看原网页，不猜测内容。
class NoticeDetailPage extends StatefulWidget {
  const NoticeDetailPage({super.key, required this.title, required this.url});

  final String title;
  final String url;

  @override
  State<NoticeDetailPage> createState() => _NoticeDetailPageState();
}

class _NoticeDetailPageState extends State<NoticeDetailPage> {
  NoticeDetailResult? _result;
  CancelToken? _cancelToken;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _cancelToken?.cancel('notice detail disposed');
    super.dispose();
  }

  Future<void> _load() async {
    _cancelToken?.cancel('notice detail reload');
    final token = _cancelToken = CancelToken();
    if (_result != null) setState(() => _result = null);
    final result = await NoticeDetailService.instance.fetch(
      widget.url,
      cancelToken: token,
    );
    if (!mounted || token != _cancelToken) return;
    setState(() => _result = result);
  }

  Future<void> _login() async {
    final ok = await showUnifiedAuthLoginModal(
      context,
      title: '登录统一认证',
      description: '登录后可查看通知公告与校园公告',
    );
    if (ok && mounted) await _load();
  }

  void _openOriginal() {
    context.pushNamed(
      'external-webview',
      extra: noticeOriginalPageExtra(title: widget.title, url: widget.url),
    );
  }

  void _openLink(String url) {
    if (isJwcNoticeDetailUrl(url)) {
      context.pushNamed('notice-detail', extra: {'title': '通知详情', 'url': url});
      return;
    }
    if (isJwcAttachmentUrl(url)) {
      unawaited(_download(NoticeAttachment(name: 'attachment', url: url)));
      return;
    }
    context.pushNamed(
      'external-webview',
      extra: {'title': '网页', 'url': url, 'showWebViewBottomBackButton': true},
    );
  }

  Future<void> _download(NoticeAttachment attachment) async {
    final messenger = ScaffoldMessenger.of(context);
    // 只对教务处域名注入登录 Cookie；其它主机的链接绝不带统一认证 Cookie。
    final cookie = isJwcAttachmentUrl(attachment.url)
        ? await NoticeDetailService.instance.cookieHeaderFor(attachment.url)
        : null;
    bool enqueued;
    try {
      enqueued = await SystemDownloader.enqueue(
        url: attachment.url,
        fileName: attachment.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_'),
        referer: widget.url,
        cookieHeader: cookie,
      );
    } on MissingPluginException {
      enqueued = false;
    }
    AppFeedback.toastOn(
      messenger,
      enqueued ? '已开始下载：${attachment.name}' : '下载失败，请重试',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppAppBar(
        title: const Text('通知详情'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'original') _openOriginal();
              if (value == 'copy') copyTextWithFeedback(context, widget.url);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'original', child: Text('查看原网页')),
              PopupMenuItem(value: 'copy', child: Text('复制链接')),
            ],
          ),
        ],
      ),
      body: switch (_result) {
        null => const Center(child: CircularProgressIndicator()),
        NoticeDetailAuthRequired() => AuthRequiredView(
          title: '登录后查看通知',
          message: '通知公告需要统一认证会话，登录后即可阅读。',
          buttonLabel: '登录统一认证',
          onAction: _login,
          icon: Icons.campaign_outlined,
        ),
        NoticeDetailUnavailable(:final structureMismatch) => AppErrorView(
          title: structureMismatch ? '暂不支持原生阅读' : '加载失败',
          message: structureMismatch
              ? '这篇通知的页面格式无法识别，可查看原网页。'
              : '网络异常，可重试或查看原网页。',
          retryLabel: structureMismatch ? '查看原网页' : '重试',
          onRetry: structureMismatch ? _openOriginal : _load,
        ),
        NoticeDetailLoaded(:final detail) => _NoticeDetailBody(
          detail: detail,
          onOpenLink: _openLink,
          onDownload: _download,
          onOpenOriginal: _openOriginal,
        ),
      },
    );
  }
}

class _NoticeDetailBody extends StatelessWidget {
  const _NoticeDetailBody({
    required this.detail,
    required this.onOpenLink,
    required this.onDownload,
    required this.onOpenOriginal,
  });

  final NoticeDetail detail;
  final ValueChanged<String> onOpenLink;
  final ValueChanged<NoticeAttachment> onDownload;
  final VoidCallback onOpenOriginal;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final meta = [
      if (detail.publishedAt != null) detail.publishedAt!,
      if (detail.source != null) detail.source!,
    ].join(' · ');

    return SelectionArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        children: [
          Text(
            detail.title,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w600,
              height: 1.4,
            ),
          ),
          if (meta.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              meta,
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Divider(color: cs.outlineVariant.withValues(alpha: 0.5)),
          const SizedBox(height: 8),
          for (final block in detail.blocks)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: switch (block) {
                NoticeParagraph() => _ParagraphView(
                  paragraph: block,
                  onOpenLink: onOpenLink,
                ),
                NoticeImage() => _ImageView(image: block),
                NoticeTable() => _TableView(
                  table: block,
                  onOpenLink: onOpenLink,
                  onOpenOriginal: onOpenOriginal,
                ),
              },
            ),
          if (detail.attachments.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              '附件（${detail.attachments.length}）',
              style: theme.textTheme.titleSmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            for (final attachment in detail.attachments)
              _AttachmentTile(
                attachment: attachment,
                onTap: () => onDownload(attachment),
              ),
          ],
        ],
      ),
    );
  }
}

class _ParagraphView extends StatefulWidget {
  const _ParagraphView({required this.paragraph, required this.onOpenLink});

  final NoticeParagraph paragraph;
  final ValueChanged<String> onOpenLink;

  @override
  State<_ParagraphView> createState() => _ParagraphViewState();
}

class _ParagraphViewState extends State<_ParagraphView> {
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();

    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final paragraph = widget.paragraph;
    final base = theme.textTheme.bodyLarge?.copyWith(height: 1.75);
    final spans = <InlineSpan>[];
    // 原文首行缩进 2 字符，且正文自身没带全角空格时补齐。
    if (paragraph.indent &&
        paragraph.align == NoticeAlign.start &&
        !paragraph.plainText.startsWith('　')) {
      spans.add(const TextSpan(text: '　　'));
    }
    for (final span in paragraph.spans) {
      TapGestureRecognizer? recognizer;
      final link = span.link;
      if (link != null) {
        recognizer = TapGestureRecognizer()
          ..onTap = () => widget.onOpenLink(link);
        _recognizers.add(recognizer);
      }
      spans.add(
        TextSpan(
          text: span.text,
          recognizer: recognizer,
          style: TextStyle(
            fontWeight: span.bold ? FontWeight.w600 : null,
            color: link != null
                ? cs.primary
                : span.emphasis
                ? cs.error
                : null,
            decoration: link != null ? TextDecoration.underline : null,
            decorationColor: cs.primary.withValues(alpha: 0.5),
          ),
        ),
      );
    }
    return Text.rich(
      TextSpan(style: base, children: spans),
      textAlign: switch (paragraph.align) {
        NoticeAlign.start => TextAlign.start,
        NoticeAlign.center => TextAlign.center,
        NoticeAlign.end => TextAlign.end,
      },
    );
  }
}

class _ImageView extends StatelessWidget {
  const _ImageView({required this.image});

  final NoticeImage image;

  @override
  Widget build(BuildContext context) {
    final w = image.width;
    final h = image.height;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: w ?? double.infinity),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: AspectRatio(
            aspectRatio: w != null && h != null ? w / h : 4 / 3,
            child: Image.network(
              image.url,
              fit: BoxFit.contain,
              errorBuilder: (context, _, _) => ColoredBox(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: const Center(child: Icon(Icons.broken_image_outlined)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TableView extends StatelessWidget {
  const _TableView({
    required this.table,
    required this.onOpenLink,
    required this.onOpenOriginal,
  });

  final NoticeTable table;
  final ValueChanged<String> onOpenLink;
  final VoidCallback onOpenOriginal;

  @override
  Widget build(BuildContext context) {
    if (!table.supported) {
      return _UnsupportedTableCard(onOpenOriginal: onOpenOriginal);
    }
    return _MergedTable(table: table, onOpenLink: onOpenLink);
  }
}

/// 结构过于复杂 / 不可靠的表格：明确回退原网页，而不是硬画错位内容。
class _UnsupportedTableCard extends StatelessWidget {
  const _UnsupportedTableCard({required this.onOpenOriginal});

  final VoidCallback onOpenOriginal;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          children: [
            Icon(Icons.table_chart_outlined, color: cs.onSurfaceVariant),
            const SizedBox(width: 12),
            const Expanded(child: Text('这个表格结构过于复杂，无法在应用内完整还原')),
            TextButton(onPressed: onOpenOriginal, child: const Text('查看原网页')),
          ],
        ),
      ),
    );
  }
}

/// 支持 rowspan / colspan 的有界原生表格渲染。
///
/// 列宽在固定小范围内按可用宽度均分（不做 Intrinsic 全量重测）；单元格高度
/// 用 [TextPainter] 逐格测量一次（与渲染同一棵 [TextSpan]，保证尺寸一致），
/// 再按占用矩阵摊到行高，最后用 [Stack] 定位——这是 Flutter `Table` 无法表达
/// 合并单元格时的最小可用方案。
class _MergedTable extends StatefulWidget {
  const _MergedTable({required this.table, required this.onOpenLink});

  final NoticeTable table;
  final ValueChanged<String> onOpenLink;

  @override
  State<_MergedTable> createState() => _MergedTableState();
}

class _MergedTableState extends State<_MergedTable> {
  static const double _padH = 10;
  static const double _padV = 8;
  static const double _minColumnWidth = 88;
  static const double _maxColumnWidth = 260;
  static const double _minRowHeight = 34;

  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();

    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final table = widget.table;
    final textScaler = MediaQuery.textScalerOf(context);
    final bodyStyle = theme.textTheme.bodyMedium ?? const TextStyle();
    final headerStyle = bodyStyle.copyWith(fontWeight: FontWeight.w600);

    // 与渲染共用同一棵 span（含链接识别器），保证测量与最终排版尺寸一致。
    final cellSpans = <TextSpan>[
      for (final cell in table.cells)
        _buildCellSpan(cell, headerStyle, bodyStyle, cs),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = table.columnCount < 1 ? 1 : table.columnCount;
        final columnWidth = (constraints.maxWidth / columns).clamp(
          _minColumnWidth,
          _maxColumnWidth,
        );
        final tableWidth = columnWidth * columns;

        final rowHeights = List<double>.filled(table.rowCount, _minRowHeight);
        final needed = List<double>.filled(table.cells.length, 0);
        for (var i = 0; i < table.cells.length; i++) {
          final cell = table.cells[i];
          final contentWidth = columnWidth * cell.columnSpan - 2 * _padH;
          final painter = TextPainter(
            text: cellSpans[i],
            textDirection: TextDirection.ltr,
            textScaler: textScaler,
            maxLines: null,
          )..layout(maxWidth: contentWidth < 1 ? 1 : contentWidth);
          needed[i] = painter.height + 2 * _padV;
        }
        // 单行单元格决定行高基线。
        for (var i = 0; i < table.cells.length; i++) {
          final cell = table.cells[i];
          if (cell.rowSpan == 1 && needed[i] > rowHeights[cell.row]) {
            rowHeights[cell.row] = needed[i];
          }
        }
        // 跨行单元格：不足的高度按跨的行数均摊补齐。
        for (var i = 0; i < table.cells.length; i++) {
          final cell = table.cells[i];
          if (cell.rowSpan <= 1) continue;
          var total = 0.0;
          for (var r = cell.row; r < cell.row + cell.rowSpan; r++) {
            total += rowHeights[r];
          }
          if (needed[i] > total) {
            final extra = (needed[i] - total) / cell.rowSpan;
            for (var r = cell.row; r < cell.row + cell.rowSpan; r++) {
              rowHeights[r] += extra;
            }
          }
        }

        final rowOffsets = List<double>.filled(table.rowCount + 1, 0);
        for (var r = 0; r < table.rowCount; r++) {
          rowOffsets[r + 1] = rowOffsets[r] + rowHeights[r];
        }
        final totalHeight = rowOffsets.last;

        final cellRects = <Rect>[];
        final headerRects = <Rect>[];
        final children = <Widget>[];
        for (var i = 0; i < table.cells.length; i++) {
          final cell = table.cells[i];
          final left = cell.column * columnWidth;
          final top = rowOffsets[cell.row];
          final width = cell.columnSpan * columnWidth;
          final height = rowOffsets[cell.row + cell.rowSpan] - top;
          final rect = Rect.fromLTWH(left, top, width, height);
          cellRects.add(rect);
          if (cell.header) headerRects.add(rect);
          children.add(
            Positioned(
              left: left,
              top: top,
              width: width,
              height: height,
              child: Semantics(
                header: cell.header,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: _padH,
                    vertical: _padV,
                  ),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: Text.rich(cellSpans[i]),
                  ),
                ),
              ),
            ),
          );
        }

        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: tableWidth,
            height: totalHeight,
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _TableBorderPainter(
                      cellRects: cellRects,
                      headerRects: headerRects,
                      borderColor: cs.outlineVariant,
                      headerColor: cs.surfaceContainerHighest,
                    ),
                  ),
                ),
                ...children,
              ],
            ),
          ),
        );
      },
    );
  }

  TextSpan _buildCellSpan(
    NoticeTableCell cell,
    TextStyle headerStyle,
    TextStyle bodyStyle,
    ColorScheme cs,
  ) {
    final children = <InlineSpan>[];
    for (final span in cell.spans) {
      TapGestureRecognizer? recognizer;
      final link = span.link;
      if (link != null) {
        recognizer = TapGestureRecognizer()
          ..onTap = () => widget.onOpenLink(link);
        _recognizers.add(recognizer);
      }
      children.add(
        TextSpan(
          text: span.text,
          recognizer: recognizer,
          style: TextStyle(
            fontWeight: span.bold || cell.header ? FontWeight.w600 : null,
            color: link != null
                ? cs.primary
                : span.emphasis
                ? cs.error
                : null,
            decoration: link != null ? TextDecoration.underline : null,
            decorationColor: cs.primary.withValues(alpha: 0.5),
          ),
        ),
      );
    }
    if (children.isEmpty) children.add(const TextSpan(text: ''));
    return TextSpan(
      style: cell.header ? headerStyle : bodyStyle,
      children: children,
    );
  }
}

/// 画合并单元格的边框与表头底色。相邻单元格边缘坐标重合，重叠描线仍是 1px，
/// 因此直接逐格描边即可得到正确的网格（合并不产生错位线）。
class _TableBorderPainter extends CustomPainter {
  const _TableBorderPainter({
    required this.cellRects,
    required this.headerRects,
    required this.borderColor,
    required this.headerColor,
  });

  final List<Rect> cellRects;
  final List<Rect> headerRects;
  final Color borderColor;
  final Color headerColor;

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()..color = headerColor;
    for (final rect in headerRects) {
      canvas.drawRect(rect, fill);
    }
    final border = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..isAntiAlias = false;
    for (final rect in cellRects) {
      canvas.drawRect(rect, border);
    }
  }

  @override
  bool shouldRepaint(_TableBorderPainter old) =>
      old.borderColor != borderColor ||
      old.headerColor != headerColor ||
      !listEquals(old.cellRects, cellRects) ||
      !listEquals(old.headerRects, headerRects);
}

class _AttachmentTile extends StatelessWidget {
  const _AttachmentTile({required this.attachment, required this.onTap});

  final NoticeAttachment attachment;
  final VoidCallback onTap;

  IconData get _icon {
    final name = attachment.name.toLowerCase();
    if (name.endsWith('.pdf')) return Icons.picture_as_pdf_outlined;
    if (name.endsWith('.xls') || name.endsWith('.xlsx')) {
      return Icons.table_view_outlined;
    }
    if (name.endsWith('.zip') ||
        name.endsWith('.rar') ||
        name.endsWith('.7z')) {
      return Icons.folder_zip_outlined;
    }
    if (name.endsWith('.jpg') || name.endsWith('.png')) {
      return Icons.image_outlined;
    }
    return Icons.description_outlined;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Icon(_icon, color: cs.primary),
                const SizedBox(width: 12),
                Expanded(child: Text(attachment.name)),
                const SizedBox(width: 8),
                Icon(Icons.download_outlined, color: cs.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
