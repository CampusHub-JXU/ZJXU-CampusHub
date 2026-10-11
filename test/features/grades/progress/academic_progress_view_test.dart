import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/features/grades/grades_page.dart';
import 'package:jxu_campus_hub/features/grades/progress/academic_progress_model.dart';
import 'package:jxu_campus_hub/shared/widgets/app_filter_chips.dart';

import '../../../helpers/test_setup.dart';

/// 合成 fixture，全部为假数据；成绩 / 补考 / 重修用唯一 sentinel 字符串，
/// 便于断言叶节点明细不泄露成绩数字。
const _scoreSentinel = 'SCORE-SENTINEL-9931';
const _makeupSentinel = 'MAKEUP-SENTINEL-4471';
const _retakeSentinel = 'RETAKE-SENTINEL-7712';

const _report = AcademicProgressReport(
  summary: AcademicProgressSummary(
    gpa: '3.120',
    statTime: '2026-09-01',
    planTotal: 80,
    planPassed: 20,
    planFailed: 2,
    planNotTaken: 48,
    studying: 10,
  ),
  roots: [
    RequirementNode(
      id: 'root',
      name: '主修',
      children: [
        RequirementNode(
          id: 'must',
          name: '必修课合计',
          requiredCredits: 120,
          earnedCredits: 40,
          children: [
            RequirementNode(
              id: 'leaf1',
              name: '其他必修课',
              requiredCredits: 56,
              earnedCredits: 32,
              courseAttribute: '1',
              isLeaf: true,
              serverPassedCount: 1,
              courses: [
                AcademicProgressCourse(
                  courseCode: '1',
                  courseName: '高等数学C1',
                  status: CourseStudyStatus.failed,
                  credits: 4,
                  score: _scoreSentinel,
                  makeupScore: _makeupSentinel,
                  retakeScore: _retakeSentinel,
                  gradePoint: 4.99,
                ),
                AcademicProgressCourse(
                  courseCode: '2',
                  courseName: '体育3',
                  status: CourseStudyStatus.notTaken,
                  credits: 1,
                ),
                AcademicProgressCourse(
                  courseCode: '3',
                  courseName: '体育1',
                  status: CourseStudyStatus.passed,
                  credits: 1,
                  score: '70',
                ),
              ],
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await resetTestEnvironment();
    ZhengfangAuth.instance.debugSetSession(
      active: true,
      studentId: '2025000001',
    );
  });

  Future<void> pumpPage(
    WidgetTester tester, {
    AcademicProgressReport report = _report,
    Size size = const Size(800, 1400),
    TextScaler? textScaler,
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: brightness == Brightness.dark
            ? ThemeData(brightness: Brightness.dark)
            : null,
        builder: textScaler == null
            ? null
            : (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: textScaler),
                child: child!,
              ),
        home: GradesPage(
          initialView: GradesPageView.progress,
          fetchReport: ({bool forceRefresh = false}) async => report,
        ),
      ),
    );
    // 首帧 + fetch + 宿主 AppBar 的 chrome 回调（刷新按钮）。
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  Matrix4 transformOf(WidgetTester tester) => tester
      .widget<InteractiveViewer>(find.byType(InteractiveViewer))
      .transformationController!
      .value;

  testWidgets('默认只显示主修 GPA 与可交互培养方案 Graph', (tester) async {
    await pumpPage(tester);

    // GPA 读数：教务口径主修绩点 + 来源说明，不写「累计 / 所有课程 GPA」。
    expect(find.text('主修平均学分绩点'), findsOneWidget);
    expect(find.text('3.120'), findsOneWidget);
    expect(find.textContaining('教务培养方案统计口径'), findsOneWidget);
    expect(find.textContaining('统计截至 2026-09-01'), findsOneWidget);
    expect(find.text('累计 GPA'), findsNothing);
    expect(find.text('所有课程 GPA'), findsNothing);

    // Graph 默认可见，铺满剩余视口。
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.text('必修课合计'), findsOneWidget);
    expect(find.text('40/120 学分'), findsOneWidget);
    expect(find.text('其他必修课'), findsOneWidget);
    expect(find.text('32/56 学分'), findsOneWidget);
    expect(find.text('创新创业情况'), findsOneWidget);
    expect(find.text('尚无数据'), findsOneWidget);

    // 没有旧的平铺列表 / 状态筛选 / 四格瓦片 / 视图切换。
    expect(find.byType(AppFilterChips), findsNothing);
    expect(find.byTooltip('树状图'), findsNothing);
    expect(find.byTooltip('列表'), findsNothing);
    expect(find.text('按类别'), findsNothing);
    expect(find.text('未修 1'), findsNothing);
    expect(find.textContaining('全部课程'), findsNothing);
    // 课程明细不默认展开。
    expect(find.text('高等数学C1'), findsNothing);
  });

  testWidgets('AppBar 只保留刷新，不再有列表 / 树状图切换', (tester) async {
    await pumpPage(tester);
    expect(find.byTooltip('刷新'), findsOneWidget);
    expect(find.byTooltip('树状图'), findsNothing);
    expect(find.byTooltip('列表'), findsNothing);
  });

  testWidgets('GPA 缺失时占位显示 --，不猜算也不填 0', (tester) async {
    await pumpPage(
      tester,
      report: const AcademicProgressReport(
        summary: AcademicProgressSummary(),
        roots: [
          RequirementNode(
            id: 'root',
            name: '主修',
            children: [
              RequirementNode(
                id: 'leaf',
                name: '任意类别',
                requiredCredits: 10,
                earnedCredits: 0,
                isLeaf: true,
                courses: [
                  AcademicProgressCourse(
                    courseCode: '1',
                    courseName: '课程A',
                    status: CourseStudyStatus.notTaken,
                    credits: 2,
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );

    expect(find.text('--'), findsOneWidget);
    // 不把缺省值填成 0.x 之类的假读数。
    expect(find.text('0'), findsNothing);
    expect(find.textContaining('0.00'), findsNothing);
  });

  testWidgets('画布支持缩放与拖动（真实 transform 变化）', (tester) async {
    await pumpPage(tester, size: const Size(600, 900));

    final beforeScale = transformOf(tester).getMaxScaleOnAxis();

    // 双指捏合放大。
    final center = tester.getCenter(find.byType(InteractiveViewer));
    final g1 = await tester.startGesture(center - const Offset(30, 0));
    final g2 = await tester.startGesture(center + const Offset(30, 0));
    await tester.pump();
    await g1.moveBy(const Offset(-30, 0));
    await g2.moveBy(const Offset(30, 0));
    await tester.pump();
    await g1.up();
    await g2.up();
    await tester.pumpAndSettle();

    final zoomed = transformOf(tester);
    expect(
      zoomed.getMaxScaleOnAxis(),
      greaterThan(beforeScale),
      reason: '捏合手势应放大画布',
    );

    // 放大后单指拖动应平移画布。
    final beforePan = transformOf(tester).getTranslation();
    await tester.drag(find.byType(InteractiveViewer), const Offset(-80, 0));
    await tester.pumpAndSettle();
    final afterPan = transformOf(tester).getTranslation();
    expect(
      (afterPan.x - beforePan.x).abs() + (afterPan.y - beforePan.y).abs(),
      greaterThan(0.5),
      reason: '拖动应改变画布平移',
    );
  });

  testWidgets('点末节点弹出要求学分与修读状态，不含成绩数字', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.text('其他必修课'));
    await tester.pumpAndSettle();

    // 节点要求 / 已获学分 + 门次。
    expect(find.textContaining('要求 56 学分 · 已获 32 学分'), findsOneWidget);
    expect(find.textContaining('共 3 门 · 通过 1 门'), findsOneWidget);
    // 课程名称 + 修读状态。
    expect(find.text('高等数学C1'), findsOneWidget);
    expect(find.text('体育3'), findsOneWidget);
    expect(find.text('体育1'), findsOneWidget);
    expect(find.text('未过'), findsOneWidget);
    expect(find.text('未修'), findsOneWidget);
    expect(find.text('已修'), findsOneWidget);
    // 不复刻完整成绩页：成绩 / 补考 / 重修数字不得出现。
    expect(find.textContaining('SENTINEL'), findsNothing);
    expect(find.textContaining('补考'), findsNothing);
    expect(find.textContaining('重修'), findsNothing);
    expect(find.text('55'), findsNothing);
  });

  testWidgets('末节点无课程时给出安全提示', (tester) async {
    await pumpPage(
      tester,
      report: const AcademicProgressReport(
        summary: AcademicProgressSummary(gpa: '3.0'),
        roots: [
          RequirementNode(
            id: 'root',
            name: '主修',
            children: [
              RequirementNode(
                id: 'empty',
                name: '空类别',
                requiredCredits: 4,
                earnedCredits: 0,
                isLeaf: true,
              ),
            ],
          ),
        ],
      ),
    );

    await tester.tap(find.text('空类别'));
    await tester.pump();
    expect(find.text('该类别暂无课程'), findsOneWidget);
    // 推进 SnackBar 计时器。
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('刷新按钮重新请求学业数据', (tester) async {
    var calls = 0;
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: GradesPage(
          initialView: GradesPageView.progress,
          fetchReport: ({bool forceRefresh = false}) async {
            calls++;
            return _report;
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(calls, 1);

    await tester.tap(find.byTooltip('刷新'));
    await tester.pump();
    await tester.pump();
    expect(calls, 2);
    expect(find.text('3.120'), findsOneWidget);
  });

  testWidgets('360dp + 文字缩放 2.0 无溢出，画布仍有空间', (tester) async {
    await pumpPage(
      tester,
      size: const Size(360, 780),
      textScaler: const TextScaler.linear(2),
      report: const AcademicProgressReport(
        summary: AcademicProgressSummary(
          gpa: '3.123456',
          statTime: '2026-09-01 08:30 之前有效（教务端统计口径说明文字较长）',
        ),
        roots: [
          RequirementNode(
            id: 'root',
            name: '一个非常非常长的培养方案类别名称用于验证长文字不溢出',
            requiredCredits: 160,
            earnedCredits: 88,
            isLeaf: true,
            courses: [
              AcademicProgressCourse(
                courseCode: '1',
                courseName: '一门名字非常非常长的专业核心课程实验与实践',
                status: CourseStudyStatus.passed,
                credits: 4,
              ),
            ],
          ),
        ],
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.text('主修平均学分绩点'), findsOneWidget);
  });

  testWidgets('横屏窄高下无溢出', (tester) async {
    await pumpPage(tester, size: const Size(780, 360));

    expect(tester.takeException(), isNull);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.text('主修平均学分绩点'), findsOneWidget);
  });

  testWidgets('深色模式渲染正常', (tester) async {
    await pumpPage(tester, brightness: Brightness.dark);

    expect(tester.takeException(), isNull);
    expect(find.text('3.120'), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsOneWidget);
  });
}
