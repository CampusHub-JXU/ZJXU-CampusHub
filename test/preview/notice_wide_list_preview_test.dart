import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/auth/cas_auth_broker.dart';
import 'package:jxu_campus_hub/core/notice/notice_fetch_service.dart';
import 'package:jxu_campus_hub/core/notice/notice_model.dart';
import 'package:jxu_campus_hub/core/notice/notice_sync_store.dart';
import 'package:jxu_campus_hub/core/theme/app_design_tokens.dart';
import 'package:jxu_campus_hub/core/theme/app_typography.dart';
import 'package:jxu_campus_hub/features/notification_center/notification_center_page.dart';
import 'package:jxu_campus_hub/features/notification_center/notice_group_section.dart';
import 'package:jxu_campus_hub/features/sjjx_notice/sjjx_notice_model.dart';
import 'package:jxu_campus_hub/shared/widgets/plain_list.dart';

import '../helpers/mock_http_client_adapter.dart';
import '../helpers/preview_support.dart';
import '../helpers/test_setup.dart';

/// Issue #63 专项：通知中心「无框宽幅列表」的几何回归 + 视觉预览。
///
/// 与 `test/preview/preview_render_test.dart` 分开：这里只保留 #63 的新契约。
///
/// 1. **几何回归（普通 `flutter test` 即运行）**：在 320/360/412 × 文字缩放
///    1.0/1.5/2.0 × 深/浅色下渲染真实 `NotificationCenterPage`，断言
///    分组标题与行标题首字对齐、只有一层页边距、长标题获得更宽的有效行宽、
///    整行点按区不低于 48dp、且不再出现 `PlainListGroup`。
///    另用一份**就地重建的 cdf8ecc 旧结构**（`PlainListGroup` + 双层 inset）
///    在同一视口量出旧标题宽度，给出「同宽下变宽」的明确像素差 —— 不靠肉眼。
/// 2. **视觉预览（仅 `JXU_PREVIEW_RENDER=1`，`tools/render_previews.ps1`）**：
///    浅/深色 + 搜索态 + 实践通知 Tab 的整页截图，写入 `preview/render/`
///    （该目录已被 gitignore，只用于本机人工核对，不提交）。
///
/// 说明（诚实边界）：本文件不引入真实校园数据 / 用户截图内容，标题全部是合成
/// 示例；几何断言是程序化测量，**不等同**于人工视觉评审。
/// 站内检索「零结果」合成页（结构照博达 VSB `sousuo.jsp`；非真实内容）。
const String _siteSearchEmptyPage = '''
<html><body>
<select id="orderSelect"><option value="1">时间排序：是</option></select>
<table class=listFrame cellspacing=1></table>
共有 0 条
</body></html>
''';

void main() {
  final bool renderEnabled = Platform.environment['JXU_PREVIEW_RENDER'] == '1';

  const longTitle = '关于2026级学生合成测试通知的课程教学安排相关事项的说明与补充通知（示例）';
  const date = '2026-09-04';

  // ── 夹具 ────────────────────────────────────────────────────────────────

  /// 校内公告「更早」在线分页：注入一个返回空列表的假适配器，让 `_hasMore`
  /// 立刻收敛为 false（否则页脚会一直转圈，`pumpAndSettle` 永不结束）。
  void stubEmptyOlderPages() {
    final adapter = MockHttpClientAdapter();
    adapter.register(
      'GET',
      '/list.jsp',
      (_) async => ResponseBody.fromString('<ul id="ul1"></ul>', 200),
    );
    NoticeService.instance.debugReset();
    NoticeService.instance.debugSetDio(
      Dio(BaseOptions(responseType: ResponseType.bytes))
        ..httpClientAdapter = adapter,
    );
    addTearDown(NoticeService.instance.debugReset);
  }

  void seedInbox({int extra = 0}) {
    final notices = <Notice>[
      const Notice(
        title: longTitle,
        url: 'https://jwc.zjxu.edu.cn/info/1094/90001.htm?wbnewsid=90001',
        category: '通知公告',
        date: date,
      ),
      for (var i = 0; i < extra; i++)
        Notice(
          title: '合成通知示例 ${i.toString().padLeft(2, '0')}',
          url:
              'https://jwc.zjxu.edu.cn/info/1094/${91000 + i}.htm'
              '?wbnewsid=${91000 + i}',
          category: '通知公告',
          date: '2026-09-0${(i % 9) + 1}',
        ),
    ];
    NoticeSyncStore.instance
      ..debugReset()
      ..debugReloadNoop = true
      ..debugInjectState(
        NoticeSyncSnapshot(
          snapshotIds: const {},
          inbox: notices,
          unreadIds: {notices.first.id},
          pendingNotifyIds: const {},
          notifiedIds: const {},
          pendingBackfillPage: null,
          baselineBuilt: true,
        ),
      );
  }

  List<SjjxNotice> practiceNotices(int count) => [
    for (var i = 0; i < count; i++)
      SjjxNotice(
        title: i == 0
            ? '实践通知合成超长标题示例：关于组织参与各类学科竞赛与创新训练项目的通知（示例）'
            : '实践通知示例 ${i.toString().padLeft(4, '0')}',
        url: 'http://sjjx.zjxu.edu.cn/sjjx/detail.aspx?nid=$i',
        category: const ['学科竞赛', '毕业设计', '实验教学'][i % 3],
        date: '2026-01-${(i % 28 + 1).toString().padLeft(2, '0')}',
      ),
  ];

  // ── 旧结构（cdf8ecc）就地重建：仅用于在几何上量出「变宽了多少」 ──────────

  Widget legacyCampusList(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.listGutter,
        AppSpacing.listGroupGap / 2,
        AppSpacing.listGutter,
        AppSpacing.listGroupGap / 2,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const NoticeGroupHeader('未读', trailing: '1 条'),
          PlainListGroup(
            children: [
              InkWell(
                onTap: () {},
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    kPlainListRowInset - 4,
                    12,
                    kPlainListRowInset,
                    12,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Builder(
                              builder: (context) => Text(
                                title,
                                style: context.appText.rowTitle.copyWith(
                                  height: 1.4,
                                  fontWeight: FontWeight.w400,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Builder(
                              builder: (context) =>
                                  Text(date, style: context.appText.secondary),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── 1a. 同视口 before/after：新列表标题有效行宽明确更宽 ─────────────────

  testWidgets('几何：同视口下无框列表的标题有效宽度比旧分组卡片更宽', (tester) async {
    const width = 412.0;
    addTearDown(tester.view.reset);
    tester.view.physicalSize = const Size(width, 900);
    tester.view.devicePixelRatio = 1.0;

    // 旧结构（就地重建 cdf8ecc）。
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: legacyCampusList(longTitle))),
    );
    await tester.pump();
    final legacyWidth = tester.getSize(find.text(longTitle)).width;

    // 新结构（真实页面）。
    await resetTestEnvironment();
    seedInbox();
    stubEmptyOlderPages();
    addTearDown(NoticeSyncStore.instance.debugReset);
    await tester.pumpWidget(const MaterialApp(home: NotificationCenterPage()));
    await tester.pumpAndSettle();
    final newWidth = tester.getSize(find.text(longTitle)).width;

    expect(find.byType(PlainListGroup), findsNothing);
    // 旧：listGutter(24) + 行内 inset(12) + 圆点列(12) + 右 inset(16) + 右 gutter(24)。
    expect(legacyWidth, moreOrLessEquals(width - 88, epsilon: 1.0));
    // 新：只剩 pageMargin(16) + 圆点列(12) + 右 pageMargin(16)。
    expect(newWidth, moreOrLessEquals(width - 44, epsilon: 1.0));
    expect(
      newWidth - legacyWidth,
      greaterThanOrEqualTo(40),
      reason: '同宽下标题有效行宽应明显增加（旧 $legacyWidth → 新 $newWidth）',
    );
  });

  // ── 1b. 全宽度 / 缩放 / 深浅色：对齐、边距、行长、点按区 ────────────────

  testWidgets('几何：320/360/412 × 1.0/1.5/2.0 × 深/浅色下对齐且不溢出', (tester) async {
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    for (final width in [320.0, 360.0, 412.0]) {
      for (final scale in [1.0, 1.5, 2.0]) {
        for (final brightness in Brightness.values) {
          tester.view.physicalSize = Size(width, 900);
          tester.view.devicePixelRatio = 1.0;
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          tester.platformDispatcher.platformBrightnessTestValue = brightness;

          await resetTestEnvironment();
          seedInbox();
          stubEmptyOlderPages();
          addTearDown(NoticeSyncStore.instance.debugReset);
          await tester.pumpWidget(
            MaterialApp(
              home: NotificationCenterPage(
                key: ValueKey('$width-$scale-${brightness.name}'),
              ),
            ),
          );
          await tester.pumpAndSettle();

          final reason = 'width=$width scale=$scale brightness=$brightness';
          expect(tester.takeException(), isNull, reason: reason);
          expect(find.byType(PlainListGroup), findsNothing, reason: reason);

          final titleRect = tester.getRect(find.text(longTitle));
          final headerRect = tester.getRect(find.text('未读'));
          final rowRect = tester.getRect(
            find
                .ancestor(
                  of: find.text(longTitle),
                  matching: find.byType(InkWell),
                )
                .first,
          );

          // 分组标题与行标题首字对齐，都从 pageMargin + markerWidth 起排。
          const expectedLeft =
              NoticeListMetrics.pageMargin + NoticeListMetrics.markerWidth;
          expect(
            titleRect.left,
            moreOrLessEquals(expectedLeft, epsilon: 1.0),
            reason: reason,
          );
          expect(
            headerRect.left,
            moreOrLessEquals(expectedLeft, epsilon: 1.0),
            reason: reason,
          );
          // 右侧只剩一层 pageMargin。
          expect(
            titleRect.right,
            moreOrLessEquals(
              width - NoticeListMetrics.pageMargin,
              epsilon: 1.0,
            ),
            reason: reason,
          );
          // 整行点按区不低于 48dp。
          expect(
            rowRect.height,
            greaterThanOrEqualTo(48 - 0.5),
            reason: reason,
          );
        }
      }
    }
    NoticeSyncStore.instance.debugReset();
  });

  // ── 2. 视觉预览（仅 JXU_PREVIEW_RENDER=1） ──────────────────────────────

  void previewTest(String name, Future<void> Function(WidgetTester) body) {
    testWidgets('preview: $name', (tester) async {
      if (!renderEnabled) return;
      await resetTestEnvironment();
      await body(tester);
    }, skip: !renderEnabled);
  }

  previewTest('notice_wide_list_light', (tester) async {
    seedInbox(extra: 6);
    stubEmptyOlderPages();
    addTearDown(NoticeSyncStore.instance.debugReset);
    await pumpPreviewScene(
      tester,
      (_) => const NotificationCenterPage(),
      logicalSize: const Size(412, 904),
    );
    await expectPreviewGolden(tester, 'notice_wide_list_light');
  });

  previewTest('notice_wide_list_dark', (tester) async {
    seedInbox(extra: 6);
    stubEmptyOlderPages();
    addTearDown(NoticeSyncStore.instance.debugReset);
    await pumpPreviewScene(
      tester,
      (_) => const NotificationCenterPage(),
      brightness: Brightness.dark,
      logicalSize: const Size(412, 904),
    );
    await expectPreviewGolden(tester, 'notice_wide_list_dark');
  });

  previewTest('notice_wide_list_search_light', (tester) async {
    seedInbox(extra: 6);
    stubEmptyOlderPages();
    addTearDown(NoticeSyncStore.instance.debugReset);
    // 站内检索：预览环境本来就会屏蔽外网；这里注入一个合成的「零结果」页，
    // 让 golden 稳定落在「本地最近通知 + 无结果提示」两个无框分区上。
    CasAuthBroker.debugGetResourceOverride =
        (
          url, {
          dio,
          needsLogin,
          cancelToken,
          Duration? timeout,
          deadline,
        }) async => Response(
          data: utf8.encode(_siteSearchEmptyPage),
          requestOptions: RequestOptions(path: url),
          statusCode: 200,
        );
    addTearDown(() => CasAuthBroker.debugGetResourceOverride = null);
    await pumpPreviewScene(
      tester,
      (_) => const NotificationCenterPage(),
      logicalSize: const Size(412, 904),
    );
    await tester.tap(find.byIcon(Icons.search_rounded));
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, '合成');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    await expectPreviewGolden(tester, 'notice_wide_list_search_light');
  });

  previewTest('notice_wide_list_practice_light', (tester) async {
    seedInbox();
    stubEmptyOlderPages();
    addTearDown(NoticeSyncStore.instance.debugReset);
    await pumpPreviewScene(
      tester,
      (_) => NotificationCenterPage(
        practiceNoticeLoader: () async => practiceNotices(60),
      ),
      logicalSize: const Size(412, 904),
    );
    await tester.tap(find.text('实践通知'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    await expectPreviewGolden(tester, 'notice_wide_list_practice_light');
  });
}
