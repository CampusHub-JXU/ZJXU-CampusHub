import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:jxu_campus_hub/features/academic_progress/academic_progress_model.dart';
import 'package:jxu_campus_hub/features/academic_progress/academic_progress_parser.dart';
import 'package:jxu_campus_hub/features/academic_progress/academic_progress_service.dart';

// 结构取自 2026-10 抓包（docs/academic-progress-xsxyqk-api.md），姓名与数值为假数据。
const _alertBox = '''
<div role="alert" id="alertBox">
  <font size="2px" style="font-weight: bold">测试同学同学，您的课程修读情况：(统计时间2026-10-02 00:12:49之前有效)</font>
  <font size="2px">所有主修课程<a class="clj" name="showGpa">平均学分绩点</a>（GPA）：<font size="2px" style="color: red;">3.120</font></font>&nbsp;
  <font size="2px"> 计划总课程 80门      通过20门，<font size="2px" style="color: red;">未通过 2门</font>；未修48门；</font> <font size="2px" style="color: blue;"> 在读10门！</font>
  <font size="2px"> 计划外：      通过1门，</font><font size="2px" style="color: red;">未通过 0门</font>
</div>
<input type="hidden" id="cjlrxn" name="cjlrxn" value="2026"/>
<input type="hidden" id="cjlrxq" name="cjlrxq" value="3"/>
<input type="hidden" id="cjzt" name="cjzt" value=""/>
''';

void main() {
  group('parseAcademicProgressSummary', () {
    test('解析 GPA、门数与计划外', () {
      final summary = parseAcademicProgressSummary(
        html_parser.parse(_alertBox),
      );
      expect(summary.statTime, '2026-10-02 00:12:49');
      expect(summary.gpa, '3.120');
      expect(summary.planTotal, 80);
      expect(summary.planPassed, 20);
      expect(summary.planFailed, 2);
      expect(summary.planNotTaken, 48);
      expect(summary.studying, 10);
      expect(summary.outsidePassed, 1);
      expect(summary.outsideFailed, 0);
      // 姓名不进入结果。
      expect(summary.toJson().toString(), isNot(contains('测试同学')));
    });

    test('没有 #alertBox 时返回空摘要', () {
      final summary = parseAcademicProgressSummary(html_parser.parse('<p/>'));
      expect(summary.isEmpty, isTrue);
    });
  });

  group('AcademicProgressCourse.fromJson', () {
    test('兼容 KCZT number/string、XF string、JD number', () {
      final a = AcademicProgressCourse.fromJson({
        'KCH': '11182',
        'KCMC': '体育1',
        'XDZT': '4',
        'KCZT': 1,
        'XF': '1.0',
        'XNMC': '2025-2026',
        'XQMMC': '1',
        'CJ': '70',
        'JD': 2.0,
      });
      expect(a.status, CourseStudyStatus.passed);
      expect(a.countsInPlan, isTrue);
      expect(a.credits, 1.0);
      expect(a.gradePoint, 2.0);
      expect(a.scoreTerm, '2025-2026 第1学期');

      final b = AcademicProgressCourse.fromJson({
        'KCMC': '课程组课',
        'XDZT': '3',
        'KCZT': '0',
        'XF': '2',
        'JYXDXNMC': '2026-2027',
        'JYXDXQMC': '2',
      });
      expect(b.status, CourseStudyStatus.notTaken);
      expect(b.countsInPlan, isFalse);
      expect(b.gradePoint, isNull);
      expect(b.suggestedTerm, '2026-2027 第2学期');
    });

    test('计划外重修课没有 CJ 时展示 MAXCJ', () {
      final c = AcademicProgressCourse.fromJson({
        'KCMC': '高等数学CⅠ',
        'XDZT': '4',
        'XF': '4.0',
        'SFJHKC': '否',
        'MAXCJ': '70',
        'MCXCJ': '70',
        'JD': 2,
      });
      expect(c.inPlan, isFalse);
      expect(c.countsInPlan, isTrue);
      expect(c.displayScore, '70');
      expect(c.retakeScore, '70');
    });

    test('缓存往返保留学期文案', () {
      final c = AcademicProgressCourse.fromJson({
        'KCMC': 'x',
        'XDZT': '2',
        'XF': '3',
        'XNMC': '2025-2026',
        'XQMMC': '2',
        'CJ': '50',
        'MBKCJ': '58',
        'JD': 0,
      });
      final back = AcademicProgressCourse.fromCacheJson(c.toJson());
      expect(back.scoreTerm, c.scoreTerm);
      expect(back.makeupScore, '58');
      expect(back.gradePoint, 0);
      expect(back.status, CourseStudyStatus.failed);
    });
  });

  group('RequirementNode', () {
    test('学分状态与门数统计', () {
      const courses = [
        AcademicProgressCourse(
          courseCode: '1',
          courseName: 'a',
          status: CourseStudyStatus.passed,
          credits: 2,
        ),
        AcademicProgressCourse(
          courseCode: '2',
          courseName: 'b',
          status: CourseStudyStatus.notTaken,
          credits: 2,
          countsInPlan: false,
        ),
      ];
      const plan = RequirementNode(
        id: 'x',
        name: '其他必修课',
        requiredCredits: 4,
        earnedCredits: 2,
        courseAttribute: '1',
        isLeaf: true,
        serverPassedCount: 1,
        courses: courses,
      );
      expect(plan.creditStatus, CreditStatus.notMet);
      expect(plan.missingCredits, 2);
      expect(plan.courseTotal, 1);
      expect(plan.passedTotal, 1);
      expect(plan.usesGroupEndpoint, isFalse);

      const group = RequirementNode(
        id: 'y',
        name: '自然科学类',
        requiredCredits: 2,
        earnedCredits: 2,
        courseAttribute: '4',
        isLeaf: true,
        serverPassedCount: 0,
        courses: courses,
      );
      expect(group.creditStatus, CreditStatus.met);
      expect(group.usesGroupEndpoint, isTrue);
      expect(group.courseTotal, 2);
      expect(group.passedTotal, 1);

      const other = RequirementNode(
        id: RequirementNode.otherCoursesId,
        name: '其他课程',
        courseAttribute: '1',
        isLeaf: true,
      );
      expect(other.usesGroupEndpoint, isFalse);
      expect(other.creditStatus, CreditStatus.none);
      const innovation = RequirementNode(
        id: RequirementNode.innovationId,
        name: '创新创业情况',
        isLeaf: true,
      );
      expect(innovation.needsCourses, isFalse);
    });

    test('报告 JSON 往返', () {
      const report = AcademicProgressReport(
        summary: AcademicProgressSummary(gpa: '3.0', planTotal: 10),
        roots: [
          RequirementNode(
            id: 'root',
            name: '主修',
            children: [
              RequirementNode(
                id: 'leaf',
                name: '实践环节',
                parentId: 'root',
                requiredCredits: 22,
                earnedCredits: 3,
                relation: RequirementRelation.any,
                courseAttribute: '1',
                isLeaf: true,
                courses: [
                  AcademicProgressCourse(
                    courseCode: 'c',
                    courseName: '实习',
                    status: CourseStudyStatus.studying,
                    credits: 3,
                  ),
                ],
              ),
            ],
          ),
        ],
      );
      final back = AcademicProgressReport.fromJson(report.toJson());
      expect(back.summary.gpa, '3.0');
      final leaf = back.roots.single.children.single;
      expect(leaf.relation, RequirementRelation.any);
      expect(leaf.courses.single.status, CourseStudyStatus.studying);
      expect(back.allCourses.length, 1);
    });
  });

  test('课程明细表单体：节点 ID + 隐藏参数，不含学号与 csrftoken', () {
    final body = buildCourseQueryBody('2F7F', {
      'cjlrxn': '2026',
      'cjlrxq': '3',
      'bkcjlrxn': '2026',
      'bkcjlrxq': '3',
      'xscjcxkz': '0',
      'cjcxkzzt': '0',
      'cjztkz': '0',
    });
    expect(
      body,
      'xfyqjd_id=2F7F&cjlrxn=2026&cjlrxq=3&bkcjlrxn=2026&bkcjlrxq=3'
      '&xscjcxkz=0&cjcxkzzt=0&cjztkz=0&cjzt=',
    );
  });
}
