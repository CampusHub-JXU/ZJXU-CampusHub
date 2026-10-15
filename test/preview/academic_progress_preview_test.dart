import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/features/grades/grades_page.dart';
import 'package:jxu_campus_hub/features/grades/progress/academic_progress_model.dart';

import '../helpers/preview_support.dart';
import '../helpers/test_setup.dart';

/// Issue 53 学业进度页面（主修 GPA + 培养方案 Graph）预览。
///
/// 单独成文件，避免与 `preview_render_test.dart`（#74 可能改动的场景集）
/// 产生编辑冲突。默认在普通 `flutter test` 中整体 skip；由
/// `JXU_PREVIEW_RENDER=1 flutter test --update-goldens <本文件>`
/// 渲染到 `preview/render/`（该目录已 gitignore）。
///
/// 全部为合成 fixture，无真实学号 / 课程 / 用户数据。
void main() {
  final bool renderEnabled = Platform.environment['JXU_PREVIEW_RENDER'] == '1';

  setUpAll(() async {
    if (!renderEnabled) return;
    await setUpPreviewEnvironment();
  });

  const report = AcademicProgressReport(
    summary: AcademicProgressSummary(
      gpa: '3.42',
      statTime: '2026-09-01',
      planTotal: 82,
      planPassed: 26,
      planFailed: 2,
      planNotTaken: 54,
      studying: 8,
    ),
    roots: [
      RequirementNode(
        id: 'root',
        name: '主修培养方案',
        children: [
          RequirementNode(
            id: 'must',
            name: '必修课合计',
            requiredCredits: 120,
            earnedCredits: 46,
            children: [
              RequirementNode(
                id: 'm1',
                name: '公共必修课',
                requiredCredits: 56,
                earnedCredits: 30,
                courseAttribute: '1',
                isLeaf: true,
                serverPassedCount: 9,
                courses: [
                  AcademicProgressCourse(
                    courseCode: 'c1',
                    courseName: '课程样例甲',
                    status: CourseStudyStatus.passed,
                    credits: 4,
                  ),
                  AcademicProgressCourse(
                    courseCode: 'c2',
                    courseName: '课程样例乙',
                    status: CourseStudyStatus.studying,
                    credits: 3,
                  ),
                ],
              ),
              RequirementNode(
                id: 'm2',
                name: '专业必修课',
                requiredCredits: 64,
                earnedCredits: 16,
                courseAttribute: '1',
                isLeaf: true,
                serverPassedCount: 4,
              ),
            ],
          ),
          RequirementNode(
            id: 'elect',
            name: '选修课合计',
            requiredCredits: 40,
            earnedCredits: 22,
            children: [
              RequirementNode(
                id: 'e1',
                name: '专业选修',
                requiredCredits: 20,
                earnedCredits: 14,
                isLeaf: true,
              ),
              RequirementNode(
                id: 'e2',
                name: '通识选修',
                requiredCredits: 20,
                earnedCredits: 8,
                isLeaf: true,
              ),
            ],
          ),
        ],
      ),
      RequirementNode(
        id: RequirementNode.innovationId,
        name: '创新创业情况',
        isLeaf: true,
      ),
    ],
  );

  Future<void> render(
    WidgetTester tester,
    String name, {
    Brightness brightness = Brightness.light,
  }) async {
    ZhengfangAuth.instance.debugSetSession(
      active: true,
      studentId: '2025000001',
    );
    await pumpPreviewScene(
      tester,
      (_) => GradesPage(
        initialView: GradesPageView.progress,
        fetchReport: ({bool forceRefresh = false}) async => report,
      ),
      brightness: brightness,
    );
    await expectPreviewGolden(tester, name);
  }

  for (final brightness in Brightness.values) {
    testWidgets('preview: page_academic_progress_${brightness.name}', (
      tester,
    ) async {
      if (!renderEnabled) return;
      await resetTestEnvironment();
      await render(
        tester,
        'page_academic_progress_${brightness.name}',
        brightness: brightness,
      );
    }, skip: !renderEnabled);
  }
}
