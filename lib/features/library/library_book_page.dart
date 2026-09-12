import 'package:flutter/material.dart';

import '../../core/theme/app_design_tokens.dart';
import '../../shared/widgets/app_app_bar.dart';
import '../../shared/widgets/app_card.dart';
import '../../shared/widgets/app_empty_view.dart';
import '../../shared/widgets/app_error_view.dart';
import 'library_models.dart';
import 'library_service.dart';

/// 原生馆藏详情页（PRD 0.7.0 §34）。
///
/// 打开时机：图书馆 WebView 拦截到书目详情跳转（
/// `.../Book/Index/bookDetail/id/<id>/b_id/<bid>`）后由本页接管。
/// 数据走汇图公开接口，**无需登录**，展示索书号、馆藏位置、可借册数与条码。
class LibraryBookPage extends StatefulWidget {
  const LibraryBookPage({super.key, required this.bid, this.title});

  /// 书目号（可带前导零；接口侧会补齐到 10 位）。
  final String bid;

  /// 书名，WebView 侧能拿到时传入用于标题。
  final String? title;

  @override
  State<LibraryBookPage> createState() => _LibraryBookPageState();
}

class _LibraryBookPageState extends State<LibraryBookPage> {
  late Future<LibraryBookDetail> _future = _load();

  Future<LibraryBookDetail> _load() =>
      LibraryService.instance.fetchBookDetail(widget.bid);

  void _retry() {
    setState(() {
      _future = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.title?.trim() ?? '';
    return Scaffold(
      appBar: AppAppBar(title: Text(title.isEmpty ? '馆藏详情' : title)),
      body: FutureBuilder<LibraryBookDetail>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final detail = snapshot.data;
          if (detail == null) {
            final error = snapshot.error;
            return AppErrorView(
              title: '馆藏信息加载失败',
              message: error is LibraryApiException
                  ? error.message
                  : '请检查网络后重试',
              onRetry: _retry,
            );
          }
          if (detail.libraries.isEmpty) {
            return const AppEmptyView(
              title: '暂无馆藏信息',
              message: '该书目暂时没有可显示的分馆藏记录',
              icon: Icons.local_library_outlined,
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.pageMargin,
              AppSpacing.md,
              AppSpacing.pageMargin,
              AppSpacing.xl,
            ),
            children: <Widget>[
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    _DetailLine(
                      label: '可借 / 馆藏',
                      value: '${detail.count} / ${detail.total}',
                      emphasized: detail.hasAvailable,
                    ),
                    const SizedBox(height: 6),
                    _DetailLine(label: '索书号', value: detail.callNo),
                    const SizedBox(height: 6),
                    _DetailLine(label: '书目号', value: detail.bid),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              for (final holding in detail.libraries)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: AppCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          holding.locationName.isEmpty
                              ? holding.groupName
                              : holding.locationName,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 6),
                        _DetailLine(label: '分馆', value: holding.groupName),
                        const SizedBox(height: 4),
                        _DetailLine(
                          label: '可借 / 馆藏',
                          value: '${holding.count} / ${holding.total}',
                          emphasized: holding.hasAvailable,
                        ),
                        if (holding.shelfNo.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 4),
                          _DetailLine(label: '架位号', value: holding.shelfNo),
                        ],
                        if (holding.cids.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 4),
                          _DetailLine(
                            label: '条码号',
                            value: holding.cids.join('、'),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _DetailLine extends StatelessWidget {
  const _DetailLine({
    required this.label,
    required this.value,
    this.emphasized = false,
  });

  final String label;
  final String value;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 84,
          child: Text(
            label,
            style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: emphasized ? FontWeight.w700 : FontWeight.w500,
              color: emphasized ? cs.primary : cs.onSurface,
            ),
          ),
        ),
      ],
    );
  }
}
