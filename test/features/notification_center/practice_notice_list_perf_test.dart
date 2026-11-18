import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:charset/charset.dart';
import 'package:dio/dio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/notification_center/notice_group_section.dart';
import 'package:jxu_campus_hub/features/notification_center/practice_notice_list_view.dart';
import 'package:jxu_campus_hub/features/sjjx_notice/sjjx_notice_model.dart';
import 'package:jxu_campus_hub/features/sjjx_notice/sjjx_notice_service.dart';

/// Issue #64 的合成性能证据采集（不接触任何真实校园环境、不含个人信息）。
///
/// **每次运行产出独立、可追溯的 artifact**（不再写固定文件名，避免后续
/// `flutter test` 覆盖基线运行）：
/// - `output/issue-64/perf-run-<runID>.txt`：本次运行的明细（run id、被测
///   revision / 工作树身份、场景、行数 / element 数 / 宿主墙钟耗时）。
/// - `output/issue-64/perf-runs.jsonl`：本次运行追加一行摘要（所有历史运行
///   都保留在该文件里，便于对照独立运行之间的差异）。
///
/// 说明（诚实边界）：
/// - **counts 是硬指标**（同一套合成数据、同一行 widget，仅隔离列表结构），
///   在多次独立运行中稳定；**timings 是测试宿主机墙钟时间**（含 test binding
///   开销），独立运行之间差异很大，只作数量级参考，**不是真机帧时间**。
/// - 修复前的私有 `_NoticeTile` 已在实现中被替换，这里用**结构与行内容等价的
///   重建**还原旧路径（`ListView` 直接包住一个 `NoticeGroupSection`，把全部
///   1518 行放进 `PlainListGroup` 的 `Column`）——这正是旧代码的构造形态。
const int kTotal = 1518;
const int kPageSize = 20;

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

String _two(int v) => v.toString().padLeft(2, '0');

/// 运行标识：UTC 时间戳 + 进程号，保证独立运行不互相覆盖。
String _newRunId() {
  final now = DateTime.now().toUtc();
  final stamp =
      '${now.year}${_two(now.month)}${_two(now.day)}'
      'T${_two(now.hour)}${_two(now.minute)}${_two(now.second)}Z';
  return '$stamp-p$pid';
}

/// 被测 revision / 工作树身份：读真实 git，读不到则如实标 unknown，不编造 SHA。
String _revisionIdentity() {
  String run(List<String> args) {
    final r = Process.runSync(
      'git',
      args,
      workingDirectory: Directory.current.path,
    );
    if (r.exitCode != 0) return '';
    return (r.stdout as String).trim();
  }

  try {
    final sha = run(['rev-parse', '--short', 'HEAD']);
    if (sha.isEmpty) return 'unknown(git rev-parse 失败)';
    final dirty = run(['status', '--porcelain']).isNotEmpty;
    return dirty ? '$sha+working-tree-dirty' : sha;
  } catch (e) {
    return 'unknown($e)';
  }
}

final String _runId = _newRunId();
final String _revision = _revisionIdentity();
final List<String> _lines = <String>[];
final Map<String, Object?> _summary = <String, Object?>{
  'run_id': _runId,
  'tested_revision': _revision,
  'item_count': kTotal,
  'page_size': kPageSize,
};

String get _runFilePath =>
    '${_outDir().path}${Platform.pathSeparator}perf-run-$_runId.txt';

/// 记录一行并立即落盘：即使后续测试失败，已采集的数据仍在。
void _record(String line) {
  _lines.add(line);
  File(_runFilePath).writeAsStringSync('${_lines.join('\n')}\n');
}

void main() {
  setUpAll(() {
    _record('Issue #64 synthetic perf run');
    _record('run_id: $_runId');
    _record('tested_revision: $_revision');
    _record('item_count: $kTotal');
    _record('page_size: $kPageSize');
    _record(
      'note: timings are host wall time (test binding overhead included), '
      'NOT device frame time; full `flutter test` also runs this file and '
      'produces its own run — see output/issue-64/perf-runs.jsonl',
    );
    _record('');
  });

  tearDownAll(() {
    File('${_outDir().path}${Platform.pathSeparator}perf-runs.jsonl')
        .writeAsStringSync('${jsonEncode(_summary)}\n', mode: FileMode.append);
  });

  testWidgets('修复前 eager 路径 vs 修复后惰性路径：行数 / element 数 / 耗时', (tester) async {
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

    final eagerMs = eagerWatch.elapsedMicroseconds / 1000;
    final lazyMs = lazyWatch.elapsedMicroseconds / 1000;

    _summary
      ..['eager_rows'] = eagerRows
      ..['lazy_rows'] = lazyRows
      ..['eager_elements'] = eagerElements
      ..['lazy_elements'] = lazyElements
      ..['item_builder_calls'] = lazyBuilderCalls
      ..['window'] = lazyWindow
      ..['eager_ms'] = eagerMs
      ..['lazy_ms'] = lazyMs;

    _record(
      '[BEFORE eager: ListView -> NoticeGroupSection -> PlainListGroup(Column of all rows)]',
    );
    _record('rows built (PracticeNoticeRow elements): $eagerRows');
    _record('total elements in tree: $eagerElements');
    _record('pumpWidget wall time: $eagerMs ms');
    _record('');
    _record(
      '[AFTER lazy: PracticeNoticeListView -> CustomScrollView + SliverList.builder, pageSize=$kPageSize]',
    );
    _record('rows built (PracticeNoticeRow elements): $lazyRows');
    _record('total elements in tree: $lazyElements');
    _record('itemBuilder invocations (first frame): $lazyBuilderCalls');
    _record('window size: $lazyWindow');
    _record('pumpWidget wall time: $lazyMs ms');
    _record('');

    // 只对可复现的 counts 断言；timings 不做阈值（避免 flaky）。
    expect(eagerRows, kTotal);
    expect(eagerElements, greaterThan(lazyElements));
    expect(lazyRows, greaterThan(0));
    expect(lazyRows, lessThanOrEqualTo(30));
    expect(lazyBuilderCalls, lessThanOrEqualTo(30));
    expect(lazyWindow, kPageSize);
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
    final parseUs = best(
      () => parseSjjxNoticeListHtml(decodeSjjxNoticeHtml(resp)),
    );
    final parsed = parseSjjxNoticeListHtml(decodeSjjxNoticeHtml(resp));
    final filterUs = best(
      () =>
          parsed.where((n) => n.title.toLowerCase().contains('1517')).toList(),
    );

    _summary
      ..['html_bytes'] = bytes.length
      ..['decode_ms'] = decodeUs / 1000
      ..['sniff_ms'] = sniffUs / 1000
      ..['parse_ms'] = parseUs / 1000
      ..['filter_ms'] = filterUs / 1000;

    _record(
      'Issue #64 stage timing (min of $runs runs, host wall time, GBK source)',
    );
    _record('source HTML bytes (GBK): ${bytes.length}');
    _record('decodeSjjxNoticeHtml (GBK decode): ${decodeUs / 1000} ms');
    _record(
      'looksLikeSjjxNoticeListHtml (decode + DOM sniff): ${sniffUs / 1000} ms',
    );
    _record(
      'parseSjjxNoticeListHtml (decode + DOM parse to ${parsed.length} items): ${parseUs / 1000} ms',
    );
    _record(
      'dart filter (1518 -> full match, one query): ${filterUs / 1000} ms',
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
    const previewName = 'preview-practice-first-screen.png';
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1.0);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File('${_outDir().path}${Platform.pathSeparator}$previewName')
          .writeAsBytesSync(png!.buffer.asUint8List());
    });

    // 预览文件固定名（每次运行重生成，仅作结构参考，非视觉评审）。
    _summary['preview_png'] = previewName;
    _record('');
    _record('preview: $previewName (test font; layout structure only)');

    expect(
      File('${_outDir().path}${Platform.pathSeparator}$previewName')
          .existsSync(),
      isTrue,
    );
  });
}
