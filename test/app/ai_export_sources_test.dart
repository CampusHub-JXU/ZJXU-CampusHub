import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/app/ai_export_sources.dart';
import 'package:jxu_campus_hub/core/auth/academic_auth_guard.dart';
import 'package:jxu_campus_hub/core/auth/cas_auth_broker.dart';
import 'package:jxu_campus_hub/features/ai_export/export_builder.dart';
import 'package:jxu_campus_hub/features/ai_export/export_controller.dart';
import 'package:jxu_campus_hub/features/ai_export/export_document.dart';
import 'package:jxu_campus_hub/features/ai_export/export_model.dart';
import 'package:jxu_campus_hub/features/exam/exam_service.dart';
import 'package:jxu_campus_hub/features/grades/grades_model.dart';
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
    test('成绩：逐字段映射，空串归一为 null，JSON 不含教务原始键', () {
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
      final keys = r.toJson().keys.toList();
      expect(keys, isNot(contains('kcmc')));
      expect(keys, isNot(contains('cj')));
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
      final m =
          (jsonDecode(ExportBuilder.jsonString(doc))['modules']
                  as Map)['secondClassroom']
              as Map;
      expect(m['creditsVerified'], false);
      expect((m['enrolled'] as List).single['nominalCreditHours'], 2);
    });
  });
}
