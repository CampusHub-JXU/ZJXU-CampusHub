import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/auth/cas_auth_broker.dart';
import 'package:jxu_campus_hub/features/home/models/home_presentation.dart';
import 'package:jxu_campus_hub/features/home/widgets/home_today_section.dart';
import 'package:jxu_campus_hub/features/notice/notice_detail_page.dart';

import '../helpers/preview_support.dart';
import '../helpers/test_setup.dart';

/// 装饰性分割线改造的专项视觉预览（Issues #56 / #59）。
///
/// 与 `preview_render_test.dart` 分开，避免与 #51 的预览文件互相踩踏。
/// `flutter test` 默认全部 skip；渲染方式与仓库既有预览一致：
///   $env:JXU_PREVIEW_RENDER='1';
///   flutter test --update-goldens test/preview/decorative_dividers_preview_test.dart
/// 产物落在 `preview/render/`（git 忽略，不入库）。
void main() {
  final bool renderEnabled = Platform.environment['JXU_PREVIEW_RENDER'] == '1';

  setUpAll(() async {
    if (!renderEnabled) return;
    await setUpPreviewEnvironment();
  });

  void previewTest(String name, Future<void> Function(WidgetTester) body) {
    testWidgets('preview: $name', (tester) async {
      if (!renderEnabled) return;
      await resetTestEnvironment();
      await body(tester);
    }, skip: !renderEnabled);
  }

  HomeTodayCourseRow row(String name, {bool ongoing = false}) =>
      HomeTodayCourseRow(
        timeText: '18:30',
        lessonText: '第 11-12 节',
        courseName: name,
        locationText: '梁林校区 外B-305',
        isOngoing: ongoing,
      );

  HomeTodayPresentation fullDay() => HomeTodayPresentation(
    title: '今天',
    isFullDay: true,
    courses: [
      row('高等数学 B', ongoing: true),
      row('大学英语'),
      row('数据结构'),
      row('线性代数'),
      row('中国近现代史纲要'),
      row('体育（篮球）'),
    ],
    exams: const [],
  );

  Widget todayScene({double textScale = 1.0}) => Builder(
    builder: (context) {
      final media = MediaQuery.of(context);
      return MediaQuery(
        data: media.copyWith(textScaler: TextScaler.linear(textScale)),
        child: Scaffold(
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: HomeTodaySection(today: fullDay(), onOpenSchedule: () {}),
            ),
          ),
        ),
      );
    },
  );

  // 通知正文：沿用既有测试 fixture（脱敏合成 HTML），只看页头与正文之间的
  // 分隔处理，不覆盖表格逻辑（#45 / PR69）。
  const noticeUrl =
      'https://jwc.zjxu.edu.cn/content.jsp?urltype=news.NewsContentUrl'
      '&wbtreeid=1046&wbnewsid=1';
  const noticeHtml = '''
<div class="newsDetail"><div class="title">关于测试事项的通知</div>
<div class="leftInfo"><span class="newsInfo">发表时间：26-09-18 10:26:49</span></div>
<div id="vsb_content"><div class="v_news_content">
<p style="text-indent: 2em;">请各学院<strong>按时</strong>报送材料，逾期不再受理。</p>
<p style="text-indent: 2em;">具体安排见附件。</p>
</div></div>
</div>
''';

  Widget noticeScene() {
    CasAuthBroker.debugGetResourceOverride =
        (
          url, {
          dio,
          needsLogin,
          cancelToken,
          Duration? timeout,
          deadline,
        }) async => Response(
          data: utf8.encode(noticeHtml),
          requestOptions: RequestOptions(path: url),
          statusCode: 200,
        );
    return const NoticeDetailPage(title: '关于测试事项的通知', url: noticeUrl);
  }

  previewTest('home_today_light', (tester) async {
    await pumpPreviewScene(tester, (_) => todayScene());
    await expectPreviewGolden(tester, 'divider_home_today_light');
  });

  previewTest('home_today_dark', (tester) async {
    await pumpPreviewScene(
      tester,
      (_) => todayScene(),
      brightness: Brightness.dark,
    );
    await expectPreviewGolden(tester, 'divider_home_today_dark');
  });

  previewTest('home_today_narrow_360', (tester) async {
    await pumpPreviewScene(
      tester,
      (_) => todayScene(),
      logicalSize: const Size(360, 780),
    );
    await expectPreviewGolden(tester, 'divider_home_today_narrow360');
  });

  previewTest('home_today_textscale2', (tester) async {
    await pumpPreviewScene(tester, (_) => todayScene(textScale: 2.0));
    await expectPreviewGolden(tester, 'divider_home_today_textscale2');
  });

  previewTest('notice_body_light', (tester) async {
    addTearDown(() => CasAuthBroker.debugGetResourceOverride = null);
    await pumpPreviewScene(tester, (_) => noticeScene());
    await expectPreviewGolden(tester, 'divider_notice_body_light');
  });

  previewTest('notice_body_dark', (tester) async {
    addTearDown(() => CasAuthBroker.debugGetResourceOverride = null);
    await pumpPreviewScene(
      tester,
      (_) => noticeScene(),
      brightness: Brightness.dark,
    );
    await expectPreviewGolden(tester, 'divider_notice_body_dark');
  });
}
