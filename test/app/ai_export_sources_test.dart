import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/app/ai_export_sources.dart';
import 'package:jxu_campus_hub/core/auth/academic_auth_guard.dart';
import 'package:jxu_campus_hub/core/auth/cas_auth_broker.dart';
import 'package:jxu_campus_hub/core/notice/notice_fetch_service.dart';
import 'package:jxu_campus_hub/core/notice/notice_model.dart';
import 'package:jxu_campus_hub/features/ai_export/export_builder.dart';
import 'package:jxu_campus_hub/features/ai_export/export_controller.dart';
import 'package:jxu_campus_hub/features/ai_export/export_document.dart';
import 'package:jxu_campus_hub/features/ai_export/export_model.dart';
import 'package:jxu_campus_hub/features/exam/exam_service.dart';
import 'package:jxu_campus_hub/features/grades/grades_model.dart';
import 'package:jxu_campus_hub/features/grades/grades_service.dart';
import 'package:jxu_campus_hub/features/grades/progress/academic_progress_model.dart';
import 'package:jxu_campus_hub/features/physical_test/physical_test_model.dart';
import 'package:jxu_campus_hub/features/physical_test/physical_test_service.dart';
import 'package:jxu_campus_hub/features/second_classroom/second_classroom_model.dart';
import 'package:jxu_campus_hub/features/second_classroom/second_classroom_service.dart';

import '../helpers/ai_export_fixtures.dart';
import '../helpers/test_setup.dart';

SecondClassroomActivity _activity({
  int id = 1,
  String title = '志愿服务日',
  bool registered = true,
  bool checkedIn = false,
  DateTime? start,
  DateTime? end,
  double hours = 2,
}) => SecondClassroomActivity.fromStoredJson({
  'id': id,
  'title': title,
  'categoryName': '志愿服务',
  'organizerName': '青协',
  'location': '广场',
  'creditHours': hours,
  'isRegistered': registered,
  'hasCheckedIn': checkedIn,
  'activityStartAt': start?.toIso8601String(),
  'activityEndAt': end?.toIso8601String(),
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await resetTestEnvironment();
  });

  test('七个模块的取数来源齐全，顺序与模块枚举一致', () {
    final sources = buildAiExportSources();
    expect(sources.map((s) => s.module).toList(), ExportModule.values);
    // 第二课堂没有可证明归属的本地缓存：不提供本地读取。
    expect(
      sources
          .firstWhere((s) => s.module == ExportModule.secondClassroom)
          .readLocal,
      isNull,
    );
    for (final s in sources.where(
      (s) => s.module != ExportModule.secondClassroom,
    )) {
      expect(s.readLocal, isNotNull, reason: s.module.key);
    }
  });

  test('未登录时各私有模块的本地读取返回 null，不抛异常', () async {
    for (final s in buildAiExportSources()) {
      if (s.module == ExportModule.secondClassroom ||
          s.module == ExportModule.notices) {
        continue; // 通知是公开内容且读取落盘文件，这里不触碰文件 IO。
      }
      expect(await s.readLocal!(), isNull, reason: s.module.key);
    }
  });

  group('guardExportFetch：只归一结果，从不触发登录', () {
    Future<ExportFetchOutcome> run(Object error) =>
        guardExportFetch(() async => throw error);

    test('会话失效的各种异常 → 需登录', () async {
      for (final e in <Object>[
        const AcademicAuthExpiredException(),
        const AcademicAuthExpiredException(automaticLoginPaused: true),
        const CasAuthExpiredException(),
        const ExamAuthExpiredException(),
        const SecondClassroomServiceException('第二课堂登录态失效，请在微信中重新授权'),
      ]) {
        expect(await run(e), isA<ExportNeedsLogin>(), reason: '$e');
      }
    });

    test('恢复中不是需登录，也不是成功', () async {
      final r = await run(const AcademicAuthRecoveryPendingException());
      expect(r, isA<ExportFetchFailed>());
      expect((r as ExportFetchFailed).message, contains('正在恢复'));
    });

    test('业务异常保留服务给出的文案；未知异常给通用文案', () async {
      final a = await run(const ExamRequestException('考试响应异常，保留上次成功数据'));
      expect((a as ExportFetchFailed).message, '考试响应异常，保留上次成功数据');
      final b = await run(
        const SecondClassroomServiceException('第二课堂连接失败，请稍后重试'),
      );
      expect((b as ExportFetchFailed).message, '第二课堂连接失败，请稍后重试');
      final c = await run(StateError('boom'));
      expect((c as ExportFetchFailed).message, '获取失败，请稍后重试');
    });

    test('成功原样返回', () async {
      final data = examsData();
      final r = await guardExportFetch(() async => ExportFetched(data));
      expect((r as ExportFetched).data, same(data));
    });
  });

  group('白名单映射', () {
    test('成绩：逐字段映射，空串归一为 null，Markdown 不含教务原始键', () {
      final data = gradesModuleDataFromEntries(
        const [
          GradeEntry(
            courseName: ' 高等数学A ',
            grade: '',
            percentageScore: '  ',
            gpaPoints: 4.0,
            credits: 5,
            academicYear: '2025-2026',
            semester: '第二学期',
            examType: '补考',
            assessmentMethod: '',
            courseRequirement: '必修',
          ),
        ],
        status: ExportModuleStatus.available,
        source: '本地缓存',
      );
      final r = data.records.single;
      expect(r.courseName, '高等数学A');
      expect(r.grade, isNull);
      expect(r.percentageScore, isNull);
      expect(r.assessmentMethod, isNull);
      expect(r.examType, '补考');
      final md = ExportBuilder.markdown(
        AiExportDocument(
          exportedAt: DateTime(2026, 10, 13, 10),
          environment: kExportEnvironment,
          modules: [data],
        ),
      );
      expect(md, isNot(contains('kcmc')));
      expect(md, isNot(contains('"cj"')));
    });

    test('学业进度：节点树、补考 / 重修成绩与学分缺口', () {
      final report = AcademicProgressReport(
        summary: const AcademicProgressSummary(
          statTime: '2026-10-13',
          gpa: '3.5',
        ),
        roots: [
          RequirementNode(
            id: 'root',
            name: '培养方案',
            requiredCredits: 100,
            earnedCredits: 40,
            children: [
              RequirementNode(
                id: 'leaf',
                name: '专业必修',
                requiredCredits: 20,
                earnedCredits: 25,
                isLeaf: true,
                courses: const [
                  AcademicProgressCourse(
                    courseCode: 'CS1',
                    courseName: '数据结构',
                    status: CourseStudyStatus.passed,
                    credits: 4,
                    nature: '必修',
                    score: '60',
                    makeupScore: '60',
                    retakeScore: '75',
                    gradePoint: 1.0,
                  ),
                ],
              ),
            ],
          ),
        ],
      );
      final data = progressModuleDataFromReport(
        report,
        status: ExportModuleStatus.available,
      );
      expect(data.summary!.gpa, '3.5');
      final root = data.nodes.single;
      expect(root.missingCredits, 60);
      expect(root.creditStatus, 'notMet');
      final leaf = root.children.single;
      expect(leaf.creditStatus, 'exceeded');
      final c = leaf.courses.single;
      expect(c.makeupScore, '60');
      expect(c.retakeScore, '75');
      expect(c.status, CourseStudyStatus.passed.label);
    });

    test('体测：学年合计与分项映射', () {
      final data = physicalTestModuleDataFromSnapshot(
        const PhysicalTestSnapshot(
          records: [
            PhysicalTestRecord(
              academicYear: '2025-2026',
              totalScore: '82.5',
              grade: '良好',
              items: [
                PhysicalTestItem(name: '50 米跑', result: '7.2 秒', score: '85'),
              ],
            ),
          ],
        ),
        status: ExportModuleStatus.available,
      );
      expect(data.records.single.items.single.level, isNull);
      expect(data.records.single.items.single.result, '7.2 秒');
    });

    test('体测：本地读取只在同一会话内可见', () {
      final service = PhysicalTestService.instance;
      expect(service.peekCachedSnapshot(), isNull);
    });
  });

  group('第二课堂：已报名 / 已签到 / 标称学时', () {
    final now = DateTime(2026, 10, 13, 10);

    test('只保留已报名且未结束的活动，按开始时间升序，缺失时间沉底', () {
      final data = secondClassroomModuleDataFromActivities(
        [
          _activity(
            id: 1,
            title: '未报名',
            registered: false,
            start: DateTime(2026, 10, 14),
          ),
          _activity(id: 2, title: '已结束', end: DateTime(2026, 10, 1)),
          _activity(
            id: 3,
            title: '晚的',
            start: DateTime(2026, 10, 20),
            end: DateTime(2026, 10, 20, 2),
          ),
          _activity(
            id: 4,
            title: '早的已签到',
            checkedIn: true,
            hours: 1.5,
            start: DateTime(2026, 10, 14),
            end: DateTime(2026, 10, 14, 2),
          ),
          _activity(id: 5, title: '时间待定'),
        ],
        now: now,
        status: ExportModuleStatus.available,
      );
      expect(data.enrolled.map((r) => r.title).toList(), [
        '早的已签到',
        '晚的',
        '时间待定',
      ]);
      expect(data.checkedInCount, 1);
      expect(data.checkedInNominalHours, 1.5);
    });

    test('导出里只有标称学时，明确不是认定学时', () {
      final data = secondClassroomModuleDataFromActivities(
        [_activity(checkedIn: true, hours: 2)],
        now: now,
        status: ExportModuleStatus.available,
      );
      final doc = AiExportDocument(
        exportedAt: now,
        environment: kExportEnvironment,
        modules: [data],
      );
      final md = ExportBuilder.markdown(doc);
      expect(md, contains('| 活动 | 类别 | 主办 | 开始 | 结束 | 地点 | 标称学时 | 已签到 |'));
      expect(md, contains('不是学校认定学时'));
    });
  });

  group('成绩：触及抓取上限时标注部分结果', () {
    List<GradeEntry> entries(int n) => [
      for (var i = 0; i < n; i++)
        GradeEntry(
          courseName: 'c$i',
          grade: '90',
          percentageScore: '90',
          gpaPoints: 4,
          credits: 1,
          academicYear: '2025-2026',
          semester: '1',
          examType: '',
          assessmentMethod: '',
          courseRequirement: '',
        ),
    ];

    test('未触及上限：完整结果，没有部分结果标记', () {
      final data = gradesModuleDataFromEntries(
        entries(GradesService.maxEntries - 1),
        status: ExportModuleStatus.available,
      );
      expect(data.isPartial, isFalse);
      expect(data.scopeLabel, '全部学期');
    });

    test('触及上限：写明「仅前 N 条，可能不全」，汇总不被当作全量', () {
      final data = gradesModuleDataFromEntries(
        entries(GradesService.maxEntries),
        status: ExportModuleStatus.available,
        source: '本地缓存',
      );
      expect(data.partialNote, '仅前 ${GradesService.maxEntries} 条，可能不全');
      final md = ExportBuilder.markdown(
        AiExportDocument(
          exportedAt: kExportNow,
          environment: kExportEnvironment,
          modules: [data],
        ),
      );
      expect(md, contains('仅前 ${GradesService.maxEntries} 条，可能不全'));
      expect(md, contains('不是全部成绩'));
    });
  });

  group('教务处通知：分页覆盖范围', () {
    final now = DateTime(2026, 10, 13, 10);

    Notice notice(String title, String date) => Notice(
      title: title,
      url: 'https://jwc.zjxu.edu.cn/info/$title.htm',
      category: '通知公告',
      date: date,
    );

    /// 按页号给出结果；缺省页（不在 [pages] 里）视为失败。
    Future<NoticeFetchResult> Function(int) pager(
      Map<int, NoticeFetchResult> pages,
      List<int> requested,
    ) => (page) async {
      requested.add(page);
      return pages[page] ?? const NoticeFetchResult.unavailable();
    };

    NoticesModuleData data(ExportFetchOutcome o) =>
        (o as ExportFetched).data as NoticesModuleData;

    test('混排：首页含窗口外的置顶旧通知，后续页的窗口内通知照样取到', () async {
      final requested = <int>[];
      final outcome = await fetchNoticesForExport(
        now: now,
        fetchPage: pager({
          1: NoticeFetchResult.ok([
            notice('pinned-old', '2025-01-01'),
            notice('p1-new', '2026-10-12'),
          ], totalPages: 3),
          2: NoticeFetchResult.ok([
            notice('p2-new', '2026-10-01'),
            notice('p2-old', '2026-08-01'),
          ], totalPages: 3),
          3: NoticeFetchResult.ok([
            notice('p3-new', '2026-09-20'),
          ], totalPages: 3),
        }, requested),
      );
      expect(requested, [1, 2, 3], reason: '不因窗口外日期提前停止');
      final d = data(outcome);
      expect(d.records.map((r) => r.title), ['p1-new', 'p2-new', 'p3-new']);
      expect(d.isPartial, isFalse, reason: '翻到了站点最后一页');
    });

    test('第 2 页起某页全部早于窗口：视为覆盖完整，不再翻页', () async {
      final requested = <int>[];
      final outcome = await fetchNoticesForExport(
        now: now,
        maxPages: 6,
        fetchPage: pager({
          1: NoticeFetchResult.ok([
            notice('pinned-old', '2025-01-01'),
            notice('p1-new', '2026-10-12'),
          ], totalPages: 20),
          2: NoticeFetchResult.ok([
            notice('p2-old', '2026-08-01'),
            notice('p2-older', '2026-07-20'),
          ], totalPages: 20),
        }, requested),
      );
      expect(requested, [1, 2]);
      final d = data(outcome);
      expect(d.isPartial, isFalse);
      expect(d.records.map((r) => r.title), ['p1-new']);
    });

    test('翻到最后一页：覆盖完整，没有部分结果标记', () async {
      final outcome = await fetchNoticesForExport(
        now: now,
        fetchPage: pager({
          1: NoticeFetchResult.ok([notice('a', '2026-10-12')], totalPages: 1),
        }, []),
      );
      expect(data(outcome).isPartial, isFalse);
    });

    test('页数预算用尽仍有后续页：部分结果，写明只取了前 N 页', () async {
      final requested = <int>[];
      final outcome = await fetchNoticesForExport(
        now: now,
        maxPages: 2,
        fetchPage: pager({
          1: NoticeFetchResult.ok([notice('a', '2026-10-12')], totalPages: 9),
          2: NoticeFetchResult.ok([notice('b', '2026-10-11')], totalPages: 9),
        }, requested),
      );
      expect(requested, [1, 2]);
      final d = data(outcome);
      expect(d.isPartial, isTrue);
      expect(d.partialNote, contains('仅获取了最新 2 页（站点共 9 页）'));
      expect(d.partialNote, contains('可能不全'));
      expect(d.records, hasLength(2));
    });

    test('总页数未知且预算用尽：同样是部分结果', () async {
      final outcome = await fetchNoticesForExport(
        now: now,
        maxPages: 1,
        fetchPage: pager({
          1: NoticeFetchResult.ok([notice('a', '2026-10-12')]),
        }, []),
      );
      expect(data(outcome).partialNote, contains('仅获取了最新 1 页'));
    });

    test('后续页失败：保留已取到的前几页，标注部分结果', () async {
      final outcome = await fetchNoticesForExport(
        now: now,
        fetchPage: pager({
          1: NoticeFetchResult.ok([notice('a', '2026-10-12')], totalPages: 5),
          // 第 2 页缺省 → unavailable
        }, []),
      );
      final d = data(outcome);
      expect(d.records.map((r) => r.title), ['a']);
      expect(d.partialNote, contains('第 2 页获取失败，仅含前 1 页'));
    });

    test('后续页登录失效：同样保留已取到的并标注，不丢数据', () async {
      final outcome = await fetchNoticesForExport(
        now: now,
        fetchPage: (page) async => page == 1
            ? NoticeFetchResult.ok([notice('a', '2026-10-12')], totalPages: 5)
            : const NoticeFetchResult.authRequired(),
      );
      final d = data(outcome);
      expect(d.records, hasLength(1));
      expect(d.partialNote, contains('第 2 页获取时登录已失效'));
    });

    test('第一页失败 / 需登录：没有任何数据，按失败 / 需登录返回', () async {
      expect(
        await fetchNoticesForExport(
          now: now,
          fetchPage: (_) async => const NoticeFetchResult.unavailable(),
        ),
        isA<ExportFetchFailed>(),
      );
      expect(
        await fetchNoticesForExport(
          now: now,
          fetchPage: (_) async => const NoticeFetchResult.authRequired(),
        ),
        isA<ExportNeedsLogin>(),
      );
    });

    test('部分结果且窗口内为空：Markdown 不断言「没有通知」', () async {
      final outcome = await fetchNoticesForExport(
        now: now,
        maxPages: 1,
        fetchPage: pager({
          1: NoticeFetchResult.ok([notice('old', '2025-01-01')], totalPages: 9),
        }, []),
      );
      final md = ExportBuilder.markdown(
        AiExportDocument(
          exportedAt: now,
          environment: kExportEnvironment,
          modules: [data(outcome)],
        ),
      );
      expect(md, isNot(contains('近 30 天内没有教务处通知。')));
      expect(md, contains('不能据此判断没有通知'));
    });

    test('本地收件箱读取路径如实说明覆盖范围有限', () {
      final d = NoticesModuleData.fromNotices(
        [notice('a', '2026-10-12')],
        exportedAt: now,
        status: ExportModuleStatus.available,
        dataSource: '本地缓存',
        partialNote: kNoticeInboxCoverageNote,
      );
      expect(d.isPartial, isTrue);
      expect(kNoticeInboxCoverageNote, contains('不保证覆盖'));
      expect(kNoticeInboxCoverageNote, contains('重新获取'));
    });
  });

  test('体测中长跑「分.秒」改写为明确的分秒，其余原样', () {
    expect(normalizePhysicalTestResult('3.56 分钟'), '3分56秒（原文 3.56 分钟）');
    expect(normalizePhysicalTestResult('4.11 分钟'), '4分11秒（原文 4.11 分钟）');
    expect(normalizePhysicalTestResult('3.75 分钟'), '3.75 分钟');
    expect(normalizePhysicalTestResult('8.3 秒'), '8.3 秒');
    expect(normalizePhysicalTestResult('218.0 厘米'), '218.0 厘米');
  });
}
