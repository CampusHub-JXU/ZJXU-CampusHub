import 'package:jxu_campus_hub/core/academic/exam_model.dart';
import 'package:jxu_campus_hub/core/academic/schedule_cache_snapshot.dart';
import 'package:jxu_campus_hub/core/academic/schedule_change_rule.dart';
import 'package:jxu_campus_hub/core/academic/schedule_model.dart';
import 'package:jxu_campus_hub/core/notice/notice_model.dart';
import 'package:jxu_campus_hub/core/semester/schedule_term_context.dart';
import 'package:jxu_campus_hub/features/ai_export/export_document.dart';
import 'package:jxu_campus_hub/features/ai_export/export_model.dart';

/// 固定的导出时刻（周二）。
final DateTime kExportNow = DateTime(2026, 10, 13, 10, 30);

const ExportEnvironment kExportEnvironment = ExportEnvironment(
  termLabel: '2026-2027 学年第一学期',
  academicYear: 2026,
  termCode: 3,
  termSource: '教务系统识别',
  week: 7,
);

GradesExportRecord gradeRecord({
  String course = '高等数学A',
  String? grade = '优秀',
  String? percentage,
  double gpa = 4.5,
  double credits = 5,
  String year = '2025-2026',
  String semester = '第二学期',
  String? examType = '正常考试',
  String? method = '闭卷',
  String? requirement = '必修',
}) => GradesExportRecord(
  courseName: course,
  grade: grade,
  percentageScore: percentage,
  gpaPoints: gpa,
  credits: credits,
  academicYear: year,
  semester: semester,
  examType: examType,
  assessmentMethod: method,
  courseRequirement: requirement,
);

/// 覆盖等级制 / 百分制 / 不计绩点 / 补考的成绩集。
List<GradesExportRecord> sampleGradeRecords() => [
  gradeRecord(), // 优秀 4.5 × 5
  gradeRecord(
    course: '大学英语',
    grade: '良好',
    gpa: 3.5,
    credits: 3,
    year: '2025-2026',
    semester: '第一学期',
  ),
  gradeRecord(
    course: '数据结构',
    grade: '88',
    percentage: '88',
    gpa: 3.8,
    credits: 4,
    year: '2025-2026',
    semester: '第一学期',
    requirement: '专业必修',
  ),
  gradeRecord(
    course: '军事理论',
    grade: '合格',
    gpa: 0,
    credits: 2,
    year: '2024-2025',
    semester: '第一学期',
    requirement: '公共选修',
  ),
  gradeRecord(
    course: '线性代数',
    grade: '65',
    percentage: '65',
    gpa: 1.5,
    credits: 3,
    year: '2024-2025',
    semester: '第二学期',
    examType: '补考',
  ),
];

GradesModuleData gradesData({
  List<GradesExportRecord>? records,
  ExportModuleStatus status = ExportModuleStatus.available,
}) => GradesModuleData(
  status: status,
  lastUpdatedAt: DateTime(2026, 10, 13, 9, 0),
  dataSource: '本地缓存',
  records: records ?? sampleGradeRecords(),
);

ProgressModuleData progressData({
  ExportModuleStatus status = ExportModuleStatus.available,
}) => ProgressModuleData(
  status: status,
  lastUpdatedAt: DateTime(2026, 10, 13, 9, 10),
  dataSource: '本地缓存',
  summary: const ProgressSummaryRecord(
    statTime: '2026-10-13 09:00:00',
    gpa: '3.52',
    planTotal: 60,
    planPassed: 30,
    planFailed: 1,
    planNotTaken: 25,
    studying: 4,
  ),
  nodes: const [
    ProgressNodeRecord(
      id: 'root',
      name: '培养方案',
      requiredCredits: 160,
      earnedCredits: 90,
      missingCredits: 70,
      relation: '并且',
      creditStatus: 'notMet',
      children: [
        ProgressNodeRecord(
          id: 'leaf1',
          name: '专业必修',
          requiredCredits: 40,
          earnedCredits: 30,
          missingCredits: 10,
          requiredCount: 10,
          metCount: 7,
          relation: '并且',
          creditStatus: 'notMet',
          courses: [
            ProgressCourseRecord(
              courseCode: 'CS201',
              courseName: '数据结构',
              status: '已修',
              credits: 4,
              nature: '必修',
              inPlan: true,
              scoreTerm: '2025-2026 第1学期',
              score: '88',
              gradePoint: 3.8,
              makeupScore: '60',
            ),
            ProgressCourseRecord(
              courseCode: 'CS301',
              courseName: '操作系统',
              status: '未修',
              credits: 3,
              inPlan: true,
              suggestedTerm: '2026-2027 第1学期',
            ),
          ],
        ),
      ],
    ),
  ],
);

const _term = ScheduleTermContext(academicYear: 2026, term: 3);

ScheduleCacheSnapshot scheduleSnapshot() => ScheduleCacheSnapshot(
  studentId: 'SHOULD-NOT-LEAK',
  termContext: _term,
  courses: const [
    CourseEntry(
      courseName: '高等数学A',
      teacherName: '王老师',
      weekday: 1,
      startLesson: 1,
      endLesson: 2,
      weekRange: '1-16周',
      classroom: '教学楼A101',
      campus: '南湖校区',
      typeSymbol: '◆',
    ),
    CourseEntry(
      courseName: '大学英语',
      teacherName: '李老师',
      weekday: 3,
      startLesson: 3,
      endLesson: 4,
      weekRange: '1-16周',
      classroom: '教学楼B202',
      campus: '南湖校区',
      typeSymbol: '◆',
      hasScheduleChange: true,
    ),
  ],
  changeRules: [
    // 第 7 周周一 1-2 节的高等数学停课。
    CourseChangeRule(
      type: CourseChangeType.cancel,
      originalLesson: const CourseLessonSlot(
        week: 7,
        weekday: 1,
        startLesson: 1,
        endLesson: 2,
      ),
      courseName: '高等数学A',
      termContext: _term,
    ),
  ],
  scheduleUpdatedAt: DateTime(2026, 10, 12, 8, 0),
  changeRulesUpdatedAt: DateTime(2026, 10, 13, 8, 0),
);

ScheduleModuleData scheduleData({int currentWeek = 7}) =>
    ScheduleModuleData.fromSnapshot(
      scheduleSnapshot(),
      now: kExportNow,
      currentWeek: currentWeek,
      beforeSemesterStart: false,
      afterSemesterEnd: false,
      dataSource: '本地缓存',
    );

ExamEntry examEntry({String course = '线性代数'}) => ExamEntry.fromJson({
  'kcmc': course,
  'kch': 'MATH102',
  'kssj': '第20周 周六(2027-01-10) 09:00-11:00',
  'cdmc': '教学楼A101',
  'cdxqmc': '南湖校区',
  'zwh': '23',
  'ksmc': '期末考试',
  'kkxy': '数学学院',
  'cxbj': '',
  'xnmc': '2026-2027',
  'xqmmc': '1',
});

ExamsModuleData examsData() => ExamsModuleData.fromEntries(
  [examEntry()],
  status: ExportModuleStatus.available,
  lastUpdatedAt: DateTime(2026, 10, 13, 9, 5),
  dataSource: '本地缓存',
);

SecondClassroomModuleData secondClassroomData() => SecondClassroomModuleData(
  status: ExportModuleStatus.available,
  lastUpdatedAt: kExportNow,
  dataSource: '刚获取',
  enrolled: [
    SecondClassroomExportRecord(
      title: '志愿服务日',
      category: '志愿服务',
      organizer: '青年志愿者协会',
      activityStart: DateTime(2026, 10, 20, 14),
      activityEnd: DateTime(2026, 10, 20, 17),
      location: '图书馆前广场',
      creditHours: 2,
      checkedIn: false,
    ),
    SecondClassroomExportRecord(
      title: '学术讲座',
      category: '学术科技',
      activityStart: DateTime(2026, 10, 14, 19),
      activityEnd: DateTime(2026, 10, 14, 21),
      creditHours: 1.5,
      checkedIn: true,
    ),
  ],
);

NoticesModuleData noticesData() => NoticesModuleData.fromNotices(
  const [
    Notice(
      title: '关于期末考试安排的通知',
      url: 'https://jwc.zjxu.edu.cn/info/1046/1001.htm',
      category: '通知公告',
      date: '2026-10-10',
    ),
    Notice(
      title: '选课通知',
      url: 'https://jwc.zjxu.edu.cn/info/1046/1002.htm',
      category: '通知公告',
      date: '2026-09-20',
    ),
    // 窗口外（超过 30 天）。
    Notice(
      title: '去年的旧通知',
      url: 'https://jwc.zjxu.edu.cn/info/1046/0001.htm',
      category: '通知公告',
      date: '2025-01-01',
    ),
    // 日期缺失：无法判断是否在窗口内。
    Notice(
      title: '无日期通知',
      url: 'https://jwc.zjxu.edu.cn/info/1046/0002.htm',
      category: '通知公告',
    ),
  ],
  exportedAt: kExportNow,
  status: ExportModuleStatus.available,
  lastUpdatedAt: kExportNow,
  dataSource: '本地缓存',
);

PhysicalTestModuleData physicalTestData() => PhysicalTestModuleData(
  status: ExportModuleStatus.available,
  lastUpdatedAt: kExportNow,
  dataSource: '本地缓存',
  records: const [
    PhysicalTestYearRecord(
      academicYear: '2025-2026',
      totalScore: '82.5',
      grade: '良好',
      items: [
        PhysicalTestItemRecord(
          name: '50 米跑',
          result: '7.2 秒',
          score: '85',
          level: '良好',
        ),
      ],
    ),
  ],
);

/// 七个模块都已获取的文档（按 [modules] 过滤，固定顺序）。
AiExportDocument fullDocument({
  Set<ExportModule>? modules,
  Map<ExportModule, ExportModuleData>? overrides,
  ExportEnvironment environment = kExportEnvironment,
}) {
  final all = <ExportModule, ExportModuleData>{
    ExportModule.progress: progressData(),
    ExportModule.grades: gradesData(),
    ExportModule.schedule: scheduleData(),
    ExportModule.exams: examsData(),
    ExportModule.secondClassroom: secondClassroomData(),
    ExportModule.notices: noticesData(),
    ExportModule.physicalTest: physicalTestData(),
    ...?overrides,
  };
  final selected = modules ?? ExportModule.values.toSet();
  return AiExportDocument(
    exportedAt: kExportNow,
    environment: environment,
    modules: [
      for (final m in ExportModule.values)
        if (selected.contains(m)) all[m]!,
    ],
  );
}
