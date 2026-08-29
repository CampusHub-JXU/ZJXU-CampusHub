import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'sjjx_notice_model.dart';
import 'sjjx_notice_service.dart';
import '../../shared/widgets/app_app_bar.dart';

class SjjxNoticeListPage extends StatefulWidget {
  const SjjxNoticeListPage({super.key});

  @override
  State<SjjxNoticeListPage> createState() => _SjjxNoticeListPageState();
}

class _SjjxNoticeListPageState extends State<SjjxNoticeListPage> {
  static const _pageSize = 20;

  final ScrollController _scrollController = ScrollController();
  List<SjjxNotice> _allNotices = [];
  List<SjjxNotice> _filteredNotices = [];
  List<SjjxNotice> _visibleNotices = [];
  List<String> _categories = [];
  String? _selectedCategory;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleScroll);
    _loadNotices();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadNotices() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final notices = await SjjxNoticeService.instance.fetchAllNotices();
      if (!mounted) return;
      final cats = _extractCategories(notices);
      setState(() {
        _allNotices = notices;
        _categories = cats;
        _filteredNotices = _selectedCategory == null
            ? notices
            : notices.where((n) => n.category == _selectedCategory).toList();
        _visibleNotices = _filteredNotices.take(_pageSize).toList();
        _loadingMore = false;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  List<String> _extractCategories(List<SjjxNotice> notices) {
    final seen = <String>{};
    final ordered = <String>[];
    for (final cat in SjjxNotice.categoryOrder) {
      if (notices.any((n) => n.category == cat)) {
        seen.add(cat);
        ordered.add(cat);
      }
    }
    for (final n in notices) {
      if (!seen.contains(n.category)) {
        seen.add(n.category);
        ordered.add(n.category);
      }
    }
    return ordered;
  }

  void _filterByCategory(String? category) {
    setState(() {
      if (_selectedCategory == category) {
        _selectedCategory = null;
        _filteredNotices = _allNotices;
      } else {
        _selectedCategory = category;
        _filteredNotices = category == null
            ? _allNotices
            : _allNotices.where((n) => n.category == category).toList();
      }
      _visibleNotices = _filteredNotices.take(_pageSize).toList();
      _loadingMore = false;
    });
  }

  void _handleScroll() {
    if (!_scrollController.hasClients || _loading || _loadingMore) return;
    final position = _scrollController.position;
    if (position.pixels < position.maxScrollExtent - 240) return;
    if (_visibleNotices.length >= _filteredNotices.length) return;

    setState(() {
      _loadingMore = true;
      final nextCount = (_visibleNotices.length + _pageSize).clamp(
        0,
        _filteredNotices.length,
      );
      _visibleNotices = _filteredNotices.take(nextCount).toList();
      _loadingMore = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppAppBar(
        title: const Text('实践通知'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadNotices),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.error_outline,
                    size: 64,
                    color: cs.onSurfaceVariant,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '加载失败',
                    style: TextStyle(fontSize: 16, color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '无法连接实践教学管理平台',
                    style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.tonal(
                    onPressed: _loadNotices,
                    child: const Text('重试'),
                  ),
                ],
              ),
            )
          : _allNotices.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.article_outlined,
                    size: 64,
                    color: cs.onSurfaceVariant,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '暂无通知',
                    style: TextStyle(fontSize: 16, color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            )
          : Column(
              children: [
                _buildCategoryFilter(cs),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: _loadNotices,
                    child: _filteredNotices.isEmpty
                        ? ListView(
                            controller: _scrollController,
                            children: [
                              SizedBox(
                                height:
                                    MediaQuery.of(context).size.height * 0.4,
                                child: Center(
                                  child: Text(
                                    '该分类下暂无通知',
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: cs.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          )
                        : ListView.builder(
                            controller: _scrollController,
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            itemCount:
                                _visibleNotices.length + (_loadingMore ? 1 : 0),
                            itemBuilder: (context, index) {
                              if (index >= _visibleNotices.length) {
                                return const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 16),
                                  child: Center(
                                    child: CircularProgressIndicator(),
                                  ),
                                );
                              }
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: _NoticeCard(
                                  notice: _visibleNotices[index],
                                  colorScheme: cs,
                                  onTap: () {
                                    context.pushNamed(
                                      'external-webview',
                                      extra: {
                                        'title': _visibleNotices[index].title,
                                        'url': _visibleNotices[index].url,
                                        'emulateDingTalkEnvironment': false,
                                      },
                                    );
                                  },
                                ),
                              );
                            },
                          ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildCategoryFilter(ColorScheme cs) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border(
          bottom: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5)),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _buildChip('全部', _selectedCategory == null, cs),
            const SizedBox(width: 8),
            ..._categories.map(
              (cat) => Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _buildChip(cat, _selectedCategory == cat, cs),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChip(String label, bool selected, ColorScheme cs) {
    final chipColor = _sjjxCategoryColor(label, cs);

    return FilterChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => _filterByCategory(selected ? null : label),
      showCheckmark: false,
      selectedColor: chipColor.withValues(alpha: 0.2),
      backgroundColor: cs.surfaceContainerLow,
      side: BorderSide(color: selected ? chipColor : cs.outlineVariant),
      labelStyle: TextStyle(
        color: selected ? chipColor : cs.onSurfaceVariant,
        fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
        fontSize: 13,
      ),
    );
  }
}

class _NoticeCard extends StatelessWidget {
  final SjjxNotice notice;
  final ColorScheme colorScheme;
  final VoidCallback onTap;

  const _NoticeCard({
    required this.notice,
    required this.colorScheme,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tagColor = _sjjxCategoryColor(notice.category, colorScheme);
    final tagForeground = _contrastOn(tagColor);
    final publishDate = (notice.date ?? '').trim();

    return Material(
      color: colorScheme.surfaceContainerLowest,
      borderRadius: BorderRadius.circular(12),
      elevation: 0.5,
      shadowColor: colorScheme.shadow.withValues(alpha: 0.12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: tagColor,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  notice.category,
                  style: TextStyle(
                    color: tagForeground,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      notice.title,
                      style: TextStyle(
                        fontSize: 15,
                        color: colorScheme.onSurface,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (publishDate.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        '发布日期：$publishDate',
                        style: TextStyle(
                          fontSize: 12,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.chevron_right,
                size: 20,
                color: colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Color _sjjxCategoryColor(String category, ColorScheme cs) {
  final index = SjjxNotice.categoryOrder.indexOf(category);
  final hueOffset = index < 0 ? category.hashCode.abs() % 360 : index * 38.0;
  final hsl = HSLColor.fromColor(cs.primary);
  final isDark = cs.brightness == Brightness.dark;
  return hsl
      .withHue((hsl.hue + hueOffset) % 360.0)
      .withSaturation((hsl.saturation * 0.86).clamp(0.42, 0.92))
      .withLightness(isDark ? 0.66 : 0.42)
      .toColor();
}

Color _contrastOn(Color background) {
  return background.computeLuminance() > 0.45 ? Colors.black : Colors.white;
}
