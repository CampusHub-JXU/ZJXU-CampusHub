import 'dart:async';

import 'package:dio/dio.dart';
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
  const _TableView({required this.table, required this.onOpenOriginal});

  final NoticeTable table;
  final VoidCallback onOpenOriginal;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    if (table.hasMergedCells) {
      return Material(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Row(
            children: [
              Icon(Icons.table_chart_outlined, color: cs.onSurfaceVariant),
              const SizedBox(width: 12),
              const Expanded(child: Text('此处是含合并单元格的表格')),
              TextButton(onPressed: onOpenOriginal, child: const Text('查看原网页')),
            ],
          ),
        ),
      );
    }
    final border = BorderSide(color: cs.outlineVariant);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        defaultColumnWidth: const IntrinsicColumnWidth(),
        border: TableBorder(
          top: border,
          bottom: border,
          left: border,
          right: border,
          horizontalInside: border,
          verticalInside: border,
        ),
        children: [
          for (var i = 0; i < table.rows.length; i++)
            TableRow(
              decoration: i == 0
                  ? BoxDecoration(color: cs.surfaceContainerHighest)
                  : null,
              children: [
                for (final cell in table.rows[i])
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 220),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      child: Text(
                        cell,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: i == 0 ? FontWeight.w600 : null,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
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
