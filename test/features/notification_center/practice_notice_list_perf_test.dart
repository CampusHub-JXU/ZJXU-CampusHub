import 'dart:io';
import 'dart:ui' as ui;

import 'package:charset/charset.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/notification_center/notice_group_section.dart';
import 'package:jxu_campus_hub/features/notification_center/practice_notice_list_view.dart';
import 'package:jxu_campus_hub/features/sjjx_notice/sjjx_notice_model.dart';
import 'package:jxu_campus_hub/features/sjjx_notice/sjjx_notice_service.dart';

/// Issue #64 的合成性能证据采集（不接触任何真实校园环境、不含个人信息）。
///
/// 产出写入已忽略的 `output/issue-64/`：
/// - `perf-metrics.txt`：修复前（eager 分组卡片内联全部行）与修复后
///   （[PracticeNoticeListView] 惰性窗口）的**行 widget 数 / 总 element 数 /
///   构建耗时**，以及 GBK 解码 / DOM 解析 / Dart 过滤的分阶段耗时。
/// - `preview-practice-first-screen.png`：首屏布局结构的合成截图（测试字体把
///   字形画成方块，只用于确认「表头 + 有界行窗口」的布局，不是视觉评审）。
///
/// 说明（诚实边界）：
/// - 修复前的私有 `_NoticeTile` 已在实现中被替换，这里用**结构与行内容等价的
///   重建**还原旧路径（`ListView` 直接包住一个 `NoticeGroupSection`，把全部
///   1518 行放进 `PlainListGroup` 的 `Column`）——这正是旧代码的构造形态。
///   两条路径使用同一个行 widget，隔离出「列表结构」这一个变量。
/// - Widget 测试里的 `Stopwatch` 是测试宿主机的墙钟时间（含 test binding 开销），
///   不等于真机帧时间；行数 / element 数是可复现的硬指标，时间只作数量级参考。
const int kTotal = 1518;

List<SjjxNotice> syntheticNotices(int count) => [
  for (var i = 0; i < count; i++)
    SjjxNotice(
      title: '实践通知 ${i.toString().padLeft(4, '0')}',
      url: 'http://sjjx.zjxu.edu.cn/sjjx/detail.aspx?nid=$i',
      category: const ['学科竞赛', '毕业设计', '实验教学', '实践平台', '创新训练'][i % 5],
      date: '2026-01-${(i % 28 + 1).toString().padLeft(2, '0')}',
    ),
];

PracticeNoticeRow row(SjjxNotice n) => PracticeNoticeRow(
  title: n.title,
  date: n.date,
  tag: n.category,
  onTap: () {},
);

/// 合成 1518 条 `.List_R02` 的实践通知列表 HTML（含中文，用于真实 GBK 解码）。
String syntheticListHtml(int count) {
  final b = StringBuffer(
    '<html><head><title>实践教学平台 - 公告</title></head><body><div>',
  );
  for (var i = 0; i < count; i++) {
    b.write(
      '<div class="List_R02">'
      '<div class="List_R02_L">'
      '<a href="detail.aspx?nid=$i" title="实践通知标题 $i">'
      '[学科竞赛] 实践通知标题 $i</a></div>'
      '<div class="List_R02_R">2026-01-${(i % 28 + 1).toString().padLeft(2, '0')}</div>'
      '</div>',
    );
  }
  b.write('</div></body></html>');
  return b.toString();
}

Directory _outDir() {
  final dir = Directory('output/issue-64');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return dir;
}

void _append(String name, String text) {
  final file = _outDir().childFile(name);
  file.writeAsStringSync(text, mode: FileMode.append);
}

void _resetMetrics() {
  final file = _outDir().childFile('perf-metrics.txt');
  if (file.existsSync()) file.deleteSync();
}

extension on Directory {
  File childFile(String name) => File('$path${Platform.pathSeparator}$name');
}

void main() {
  setUpAll(_resetMetrics);

  testWidgets('修复前 eager 路径 vs 修复后惰性路径：行数 / element 数 / 耗时', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(412, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final data = syntheticNotices(kTotal);

    // --- BEFORE：旧路径形态（单分组卡片内联全部 1518 行 + 外层 ListView） ---
    final eager = MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [
            NoticeGroupSection(
              title: '全部',
              trailing: '$kTotal 条',
              children: [for (final n in data) row(n)],
            ),
          ],
        ),
      ),
    );
    final eagerWatch = Stopwatch()..start();
    await tester.pumpWidget(eager);
    await tester.pump();
    eagerWatch.stop();
    final eagerRows = find.byType(PracticeNoticeRow).evaluate().length;
    final eagerElements = tester.allElements.length;

    // --- AFTER：真实修复后的惰性列表 ---
    var lazyBuilderCalls = 0;
    final lazy = MaterialApp(
      home: Scaffold(
        body: PracticeNoticeListView(
          itemCount: kTotal,
          headerTitle: '全部',
          headerTrailing: '$kTotal 条',
          onRefresh: () async {},
          onItemBuilt: (_) => lazyBuilderCalls++,
          itemBuilder: (context, index) => row(data[index]),
        ),
      ),
    );
    final lazyWatch = Stopwatch()..start();
    await tester.pumpWidget(lazy);
    await tester.pump();
    lazyWatch.stop();
    final lazyRows = find.byType(PracticeNoticeRow).evaluate().length;
    final lazyElements = tester.allElements.length;
    final lazyWindow = tester
        .state<PracticeNoticeListViewState>(find.byType(PracticeNoticeListView))
        .debugWindowSize;

    _append(
      'perf-metrics.txt',
      'Issue #64 synthetic perf metrics (host wall time, test harness)\n'
      'total synthetic rows: $kTotal\n'
      '\n[BEFORE eager: ListView -> NoticeGroupSection -> PlainListGroup(Column of all rows)]\n'
      'rows built (PracticeNoticeRow elements): $eagerRows\n'
      'total elements in tree: $eagerElements\n'
      'pumpWidget wall time: ${eagerWatch.elapsedMicroseconds / 1000} ms\n'
      '\n[AFTER lazy: PracticeNoticeListView -> CustomScrollView + SliverList.builder, pageSize=20]\n'
      'rows built (PracticeNoticeRow elements): $lazyRows\n'
      'total elements in tree: $lazyElements\n'
      'itemBuilder invocations (first frame): $lazyBuilderCalls\n'
      'window size: $lazyWindow\n'
      'pumpWidget wall time: ${lazyWatch.elapsedMicroseconds / 1000} ms\n'
      '\n[ratio] rows after/before = ${lazyRows == 0 ? 'n/a' : (eagerRows / lazyRows).toStringAsFixed(1)}x fewer rows built on first screen\n',
    );

    // 首屏：旧路径把 1518 行一次性放进 Column 全部实例化；新路径只构建窗口。
    expect(eagerRows, kTotal);
    expect(eagerElements, greaterThan(lazyElements));
    expect(lazyRows, greaterThan(0));
    expect(lazyRows, lessThanOrEqualTo(30));
    expect(lazyBuilderCalls, lessThanOrEqualTo(30));
    expect(lazyWindow, 20);
  });

  test('HTML GBK 解码 / DOM 解析 / Dart 过滤 分阶段耗时（1518 条合成 HTML）', () {
    final html = syntheticListHtml(kTotal);
    final bytes = gbk.encode(html);
    final resp = Response<List<int>>(
      requestOptions: RequestOptions(path: '/sjjx/morenews.aspx'),
      data: bytes,
      statusCode: 200,
      headers: Headers.fromMap({
        Headers.contentTypeHeader: ['text/html; charset=gbk'],
      }),
    );

    // 预热一次，避免首次 JIT / 表初始化污染计时。
    decodeSjjxNoticeHtml(resp);
    looksLikeSjjxNoticeListHtml(decodeSjjxNoticeHtml(resp));
    parseSjjxNoticeListHtml(decodeSjjxNoticeHtml(resp));

    const runs = 5;
    int best(void Function() f) {
      var min = 1 << 62;
      for (var i = 0; i < runs; i++) {
        final w = Stopwatch()..start();
        f();
        w.stop();
        if (w.elapsedMicroseconds < min) min = w.elapsedMicroseconds;
      }
      return min;
    }

    final decodeUs = best(() => decodeSjjxNoticeHtml(resp));
    final sniffUs = best(
      () => looksLikeSjjxNoticeListHtml(decodeSjjxNoticeHtml(resp)),
    );
    final parseUs = best(() => parseSjjxNoticeListHtml(decodeSjjxNoticeHtml(resp)));
    final parsed = parseSjjxNoticeListHtml(decodeSjjxNoticeHtml(resp));
    final filterUs = best(
      () => parsed
          .where((n) => n.title.toLowerCase().contains('1517'))
          .toList(),
    );

    _append(
      'perf-metrics.txt',
      'Issue #64 stage timing (min of $runs runs, host wall time, GBK source)\n'
      'source HTML bytes (GBK): ${bytes.length}\n'
      'decodeSjjxNoticeHtml (GBK decode): ${decodeUs / 1000} ms\n'
      'looksLikeSjjxNoticeListHtml (decode + DOM sniff): ${sniffUs / 1000} ms\n'
      'parseSjjxNoticeListHtml (decode + DOM parse to ${parsed.length} items): ${parseUs / 1000} ms\n'
      'dart filter (1518 -> full match, one query): ${filterUs / 1000} ms\n',
    );

    expect(parsed.length, kTotal);
    expect(bytes.length, greaterThan(html.length ~/ 3));
  });

  testWidgets('合成首屏布局预览（测试字体，仅确认结构）', (tester) async {
    tester.view.physicalSize = const Size(412, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final key = GlobalKey();
    final data = syntheticNotices(kTotal);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RepaintBoundary(
            key: key,
            child: PracticeNoticeListView(
              itemCount: kTotal,
              headerTitle: '全部',
              headerTrailing: '$kTotal 条',
              onRefresh: () async {},
              itemBuilder: (context, index) => row(data[index]),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1.0);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      _outDir()
          .childFile('preview-practice-first-screen.png')
          .writeAsBytesSync(png!.buffer.asUint8List());
    });

    expect(
      _outDir().childFile('preview-practice-first-screen.png').existsSync(),
      isTrue,
    );
  });
}
