import '../core/academic/academic_exceptions.dart';
import '../core/academic/schedule_cache_snapshot.dart';
import '../core/auth/academic_auth_guard.dart';
import '../core/auth/cas_auth_broker.dart';
import '../core/auth/zhengfang_auth.dart';
import '../core/notice/notice_fetch_service.dart';
import '../core/notice/notice_model.dart';
import '../core/notice/notice_sync_store.dart';
import '../core/semester/semester_calendar.dart';
import '../features/ai_export/export_controller.dart';
import '../features/ai_export/export_model.dart';
import '../features/exam/exam_service.dart';
import '../features/grades/grades_model.dart';
import '../features/grades/grades_service.dart';
import '../features/grades/progress/academic_progress_model.dart';
import '../features/grades/progress/academic_progress_service.dart';
import '../features/physical_test/physical_test_model.dart';
import '../features/physical_test/physical_test_service.dart';
import '../features/schedule/schedule_service.dart';
import '../features/second_classroom/second_classroom_model.dart';
import '../features/second_classroom/second_classroom_service.dart';

/// 「导出给 AI」各模块的取数来源（组合层）。
///
/// 导出功能（`features/ai_export`）不依赖任何业务 feature；这里把各 feature
/// 既有服务的**本地读取**与**联网获取**包装成统一契约，并把业务模型逐字段
/// 映射成白名单记录（学号 / 姓名 / 凭据从不进入导出）。
///
/// 获取一律走各模块**既有**的服务与鉴权守卫（`AcademicAuthGuard` /
/// `CasAuthBroker` 路径，与对应页面一致）。导出页自身不发起登录；服务内部
/// 对已有会话的静默续期与对应页面的刷新行为相同。
List<ExportModuleSource> buildAiExportSources({DateTime Function()? clock}) {
  final now = clock ?? DateTime.now;
  return [
    _progressSource(),
    _gradesSource(),
    _scheduleSource(now),
    _examsSource(),
    _secondClassroomSource(now),
    _noticesSource(now),
    _physicalTestSource(),
  ];
}

const String _cacheSource = '本地缓存';
const String _freshSource = '刚获取';

ExportModuleStatus _statusOf({required bool stale}) =>
    stale ? ExportModuleStatus.stale : ExportModuleStatus.available;

// ── 异常归一 ────────────────────────────────────────────────────────────────

/// 把服务异常归一成三种结果；任何分支都不触发登录。
Future<ExportFetchOutcome> guardExportFetch(
  Future<ExportFetchOutcome> Function() run,
) async {
  try {
    return await run();
  } on AcademicAuthRecoveryPendingException {
    return const ExportFetchFailed('正在恢复教务登录，请稍后再试');
  } on AcademicAuthExpiredException {
    return const ExportNeedsLogin();
  } on CasAuthExpiredException {
    return const ExportNeedsLogin();
  } on AcademicRequestException catch (e) {
    if (e is AcademicSessionExpired) return const ExportNeedsLogin();
    return ExportFetchFailed(e.message);
  } on SecondClassroomServiceException catch (e) {
    // 授权失效的文案由服务给出（HTML / 微信授权页）。
    if (e.message.contains('授权') || e.message.contains('登录态')) {
      return const ExportNeedsLogin('需在微信中授权第二课堂');
    }
    return ExportFetchFailed(e.message);
  } catch (_) {
    return const ExportFetchFailed('获取失败，请稍后重试');
  }
}

// ── 成绩 ────────────────────────────────────────────────────────────────────

GradesModuleData gradesModuleDataFromEntries(
  List<GradeEntry> entries, {
  required ExportModuleStatus status,
  DateTime? updatedAt,
  String? source,
}) => GradesModuleData(
  status: status,
  lastUpdatedAt: updatedAt,
  dataSource: source,
  // 条数触及抓取上限：不能把汇总（学分 / 绩点）当作全量。
  partialNote: GradesService.mayBeTruncated(entries.length)
      ? '仅前 ${entries.length} 条，可能不全'
      : null,
  records: [
    for (final e in entries)
      GradesExportRecord(
        courseName: e.courseName.trim(),
        grade: exportOptional(e.grade),
        percentageScore: exportOptional(e.percentageScore),
        gpaPoints: e.gpaPoints,
        credits: e.credits,
        academicYear: e.academicYear.trim(),
        semester: e.semester.trim(),
        examType: exportOptional(e.examType),
        assessmentMethod: exportOptional(e.assessmentMethod),
        courseRequirement: exportOptional(e.courseRequirement),
      ),
  ],
);

ExportModuleSource _gradesSource() {
  final service = GradesService.instance;
  return ExportModuleSource(
    module: ExportModule.grades,
    readLocal: () async {
      var cached = service.cachedGrades;
      if (cached == null && await service.restoreCache()) {
        cached = service.cachedGrades;
      }
      if (cached == null) return null;
      return gradesModuleDataFromEntries(
        cached,
        status: _statusOf(stale: !service.isCacheFresh),
        updatedAt: service.updatedAt,
        source: _cacheSource,
      );
    },
    fetch: ({required force}) => guardExportFetch(() async {
      final owner = ZhengfangAuth.instance.verifiedStudentId;
      if (owner == null || owner.isEmpty) return const ExportNeedsLogin();
      final grades = await service.fetchGrades(owner, forceRefresh: force);
      return ExportFetched(
        gradesModuleDataFromEntries(
          grades,
          status: ExportModuleStatus.available,
          updatedAt: service.updatedAt ?? DateTime.now(),
          source: _freshSource,
        ),
      );
    }),
  );
}

// ── 学业进度 ────────────────────────────────────────────────────────────────

ProgressNodeRecord _progressNode(RequirementNode n) => ProgressNodeRecord(
  id: n.id,
  name: n.name.trim(),
  requiredCredits: n.requiredCredits,
  earnedCredits: n.earnedCredits,
  missingCredits: n.missingCredits,
  requiredCount: n.requiredCount,
  metCount: n.metCount,
  relation: n.relation.label,
  creditStatus: n.creditStatus.name,
  children: [for (final c in n.children) _progressNode(c)],
  courses: [
    for (final c in n.courses)
      ProgressCourseRecord(
        courseCode: exportOptional(c.courseCode),
        courseName: c.courseName.trim(),
        status: c.status.label,
        credits: c.credits,
        nature: exportOptional(c.nature),
        category: exportOptional(c.category),
        inPlan: c.inPlan,
        scoreTerm: exportOptional(c.scoreTerm),
        score: exportOptional(c.displayScore),
        gradePoint: c.gradePoint,
        makeupScore: exportOptional(c.makeupScore),
        retakeScore: exportOptional(c.retakeScore),
        suggestedTerm: exportOptional(c.suggestedTerm),
      ),
  ],
);

ProgressModuleData progressModuleDataFromReport(
  AcademicProgressReport report, {
  required ExportModuleStatus status,
  DateTime? updatedAt,
  String? source,
}) {
  final s = report.summary;
  return ProgressModuleData(
    status: status,
    lastUpdatedAt: updatedAt,
    dataSource: source,
    summary: ProgressSummaryRecord(
      statTime: exportOptional(s.statTime),
      gpa: exportOptional(s.gpa),
      planTotal: s.planTotal,
      planPassed: s.planPassed,
      planFailed: s.planFailed,
      planNotTaken: s.planNotTaken,
      studying: s.studying,
      outsidePassed: s.outsidePassed,
      outsideFailed: s.outsideFailed,
    ),
    nodes: [for (final r in report.roots) _progressNode(r)],
  );
}

ExportModuleSource _progressSource() {
  final service = AcademicProgressService.instance;
  return ExportModuleSource(
    module: ExportModule.progress,
    readLocal: () async {
      var cached = service.cachedReport;
      if (cached == null && await service.restoreCache()) {
        cached = service.cachedReport;
      }
      if (cached == null) return null;
      return progressModuleDataFromReport(
        cached,
        status: _statusOf(stale: !service.isCacheFresh),
        updatedAt: service.updatedAt,
        source: _cacheSource,
      );
    },
    fetch: ({required force}) => guardExportFetch(() async {
      final report = await service.fetchReport(forceRefresh: force);
      return ExportFetched(
        progressModuleDataFromReport(
          report,
          status: ExportModuleStatus.available,
          updatedAt: service.updatedAt ?? DateTime.now(),
          source: _freshSource,
        ),
      );
    }),
  );
}

// ── 课表 ────────────────────────────────────────────────────────────────────

ExportModuleSource _scheduleSource(DateTime Function() clock) {
  final service = ScheduleService.instance;
  ScheduleModuleData build(ScheduleCacheSnapshot snapshot, String source) {
    final now = clock();
    final calendar = SemesterCalendar.instance;
    return ScheduleModuleData.fromSnapshot(
      snapshot,
      now: now,
      currentWeek: calendar.weekForDate(now),
      beforeSemesterStart: calendar.isBeforeSemesterStart(now),
      afterSemesterEnd: calendar.isAfterSemesterEnd(now),
      dataSource: source,
    );
  }

  return ExportModuleSource(
    module: ExportModule.schedule,
    readLocal: () async {
      final snapshot = service.preferredSnapshot();
      if (snapshot == null || !snapshot.hasData) return null;
      return build(snapshot, _cacheSource);
    },
    fetch: ({required force}) => guardExportFetch(() async {
      final result = await service.loadScheduleSnapshot(forceRefresh: force);
      if (result.requiresLogin) return ExportNeedsLogin(result.message);
      final snapshot = result.snapshot;
      if (snapshot == null || !snapshot.hasData) {
        return ExportFetchFailed(result.message ?? '暂无课表数据');
      }
      return ExportFetched(
        build(snapshot, result.usedCache ? _cacheSource : _freshSource),
      );
    }),
  );
}

// ── 考试 ────────────────────────────────────────────────────────────────────

ExportModuleSource _examsSource() {
  final service = ExamService.instance;
  return ExportModuleSource(
    module: ExportModule.exams,
    readLocal: () async {
      var cached = service.cachedExams;
      if (cached == null && await service.restoreCache()) {
        cached = service.cachedExams;
      }
      if (cached == null) return null;
      return ExamsModuleData.fromEntries(
        cached,
        status: _statusOf(stale: !service.isCacheFresh),
        lastUpdatedAt: service.updatedAt,
        dataSource: _cacheSource,
      );
    },
    fetch: ({required force}) => guardExportFetch(() async {
      final exams = await service.fetchExams(forceRefresh: force);
      return ExportFetched(
        ExamsModuleData.fromEntries(
          exams,
          status: ExportModuleStatus.available,
          lastUpdatedAt: service.updatedAt ?? DateTime.now(),
          dataSource: _freshSource,
        ),
      );
    }),
  );
}

// ── 第二课堂 ────────────────────────────────────────────────────────────────

/// 活动列表最多翻的页数 × 每页条数；超出时如实标注「前 N 条活动」。
const int kSecondClassroomExportPages = 6;
const int kSecondClassroomExportPageSize = 50;

SecondClassroomModuleData secondClassroomModuleDataFromActivities(
  Iterable<SecondClassroomActivity> activities, {
  required DateTime now,
  required ExportModuleStatus status,
  DateTime? updatedAt,
  String? source,
}) {
  final enrolled = [
    for (final a in activities)
      if (a.isRegistered && !(a.activityEndAt?.isBefore(now) ?? false))
        SecondClassroomExportRecord(
          title: a.title.trim(),
          category: exportOptional(a.categoryName),
          organizer: exportOptional(a.organizerName),
          activityStart: a.activityStartAt,
          activityEnd: a.activityEndAt,
          location: exportOptional(a.location),
          creditHours: a.creditHours,
          checkedIn: a.hasCheckedIn,
        ),
  ];
  enrolled.sort((a, b) {
    final x = a.activityStart;
    final y = b.activityStart;
    if (x == null && y == null) return 0;
    if (x == null) return 1;
    if (y == null) return -1;
    return x.compareTo(y);
  });
  return SecondClassroomModuleData(
    status: status,
    lastUpdatedAt: updatedAt,
    dataSource: source,
    enrolled: enrolled,
  );
}

/// 第二课堂没有可证明归属的本地缓存（活动缓存按查询存放、不含账号），
/// 因此不读缓存，只现取，结果只留在导出页内存里。
ExportModuleSource _secondClassroomSource(DateTime Function() clock) {
  final service = SecondClassroomService.instance;
  return ExportModuleSource(
    module: ExportModule.secondClassroom,
    fetch: ({required force}) => guardExportFetch(() async {
      final byId = <int, SecondClassroomActivity>{};
      var truncated = false;
      for (var page = 1; page <= kSecondClassroomExportPages; page++) {
        final result = await service.searchActivities(
          SecondClassroomActivityQuery(
            status: SecondClassroomActivityStatus.all,
            sort: SecondClassroomActivitySort.upcoming,
            page: page,
            limit: kSecondClassroomExportPageSize,
          ),
        );
        for (final a in result.items) {
          byId[a.id] = a;
        }
        if (!result.hasMore) break;
        truncated = page == kSecondClassroomExportPages;
      }
      final now = clock();
      return ExportFetched(
        secondClassroomModuleDataFromActivities(
          byId.values,
          now: now,
          status: ExportModuleStatus.available,
          updatedAt: now,
          source: truncated
              ? '$_freshSource（仅前 ${byId.length} 条活动，可能不全）'
              : _freshSource,
        ),
      );
    }),
  );
}

// ── 教务处通知 ──────────────────────────────────────────────────────────────

/// 本地通知收件箱超过该时长未成功同步即标记为过期。
const Duration kNoticeStaleAfter = Duration(days: 2);

/// 最多翻几页教务处通知列表。列表里置顶 / 补录混排，不能假设日期单调，
/// 因此不做提前停止：在页数预算内翻页，取回后再统一筛 30 天窗口。
const int kNoticeExportMaxPages = 6;

/// 本地收件箱只是后台同步积累的最新通知（有条数上限），无法证明覆盖了完整窗口。
const String kNoticeInboxCoverageNote =
    '本地收件箱只含应用同步到的最新通知（有条数上限），不保证覆盖近 '
    '$kNoticeWindowDays 天全部通知，可点「重新获取」联网补全';

/// 分页抓取教务处通知并给出覆盖范围结论（纯逻辑，便于测试）。
///
/// * 翻到站点最后一页（或遇到空页）才算覆盖完整；
/// * 中途某页失败 / 登录失效、或页数预算用尽仍有后续页 → 部分结果，说明原因；
/// * 首页就失败 / 需登录 → 没有任何数据，按失败 / 需登录返回。
Future<ExportFetchOutcome> fetchNoticesForExport({
  required Future<NoticeFetchResult> Function(int page) fetchPage,
  required DateTime now,
  int maxPages = kNoticeExportMaxPages,
}) async {
  final collected = <Notice>[];
  String? partialNote;
  var fetchedPages = 0;
  int? totalPages;
  for (var page = 1; page <= maxPages; page++) {
    final result = await fetchPage(page);
    switch (result.status) {
      case NoticeFetchStatus.authRequired:
        if (page == 1) return const ExportNeedsLogin();
        partialNote = '第 $page 页获取时登录已失效，仅含前 ${page - 1} 页';
      case NoticeFetchStatus.unavailable:
        if (page == 1) {
          return const ExportFetchFailed('教务处通知获取失败，请稍后重试');
        }
        partialNote = '第 $page 页获取失败，仅含前 ${page - 1} 页';
      case NoticeFetchStatus.ok:
        collected.addAll(result.notices);
        fetchedPages = page;
        totalPages = result.totalPages ?? totalPages;
    }
    if (partialNote != null) break;
    final total = totalPages;
    // 站点最后一页 / 空页：覆盖完整。
    if (result.notices.isEmpty || (total != null && page >= total)) break;
    // 置顶只出现在第 1 页；之后某页全部早于窗口（且都有日期）时，更后面的页
    // 只会更旧，视为窗口已覆盖完整。
    if (page >= 2 && _pageEntirelyBeforeWindow(result.notices, now)) break;
    if (page == maxPages) {
      partialNote = total == null
          ? '仅获取了最新 $fetchedPages 页，更早的通知未获取'
          : '仅获取了最新 $fetchedPages 页（站点共 $total 页），更早的通知未获取';
    }
  }
  return ExportFetched(
    NoticesModuleData.fromNotices(
      collected,
      exportedAt: now,
      status: ExportModuleStatus.available,
      lastUpdatedAt: now,
      dataSource: _freshSource,
      partialNote: partialNote == null
          ? null
          : '$partialNote，近 $kNoticeWindowDays 天内的通知可能不全',
    ),
  );
}

bool _pageEntirelyBeforeWindow(List<Notice> notices, DateTime now) {
  final cutoff = DateTime(
    now.year,
    now.month,
    now.day,
  ).subtract(const Duration(days: kNoticeWindowDays));
  return notices.every((n) {
    final d = n.parsedDate;
    return d != null && d.isBefore(cutoff);
  });
}

ExportModuleSource _noticesSource(DateTime Function() clock) {
  return ExportModuleSource(
    module: ExportModule.notices,
    readLocal: () async {
      final store = NoticeSyncStore.instance;
      final state = await store.reload();
      final syncedAt = state.lastSuccessfulSyncAt;
      if (!state.baselineBuilt && state.inbox.isEmpty) return null;
      final now = clock();
      return NoticesModuleData.fromNotices(
        state.inbox,
        exportedAt: now,
        status: _statusOf(
          stale:
              syncedAt == null || now.difference(syncedAt) > kNoticeStaleAfter,
        ),
        lastUpdatedAt: syncedAt,
        dataSource: _cacheSource,
        partialNote: kNoticeInboxCoverageNote,
      );
    },
    fetch: ({required force}) => guardExportFetch(
      () => fetchNoticesForExport(
        fetchPage: (page) => NoticeService.instance.fetchNoticesRaw(page: page),
        now: clock(),
      ),
    ),
  );
}

// ── 体测 ────────────────────────────────────────────────────────────────────

PhysicalTestModuleData physicalTestModuleDataFromSnapshot(
  PhysicalTestSnapshot snapshot, {
  required ExportModuleStatus status,
  String? source,
}) => PhysicalTestModuleData(
  status: status,
  lastUpdatedAt: snapshot.updatedAt,
  dataSource: source,
  records: [
    for (final r in snapshot.records)
      PhysicalTestYearRecord(
        academicYear: r.academicYear.trim(),
        totalScore: exportOptional(r.totalScore),
        grade: exportOptional(r.grade),
        items: [
          for (final i in r.items)
            PhysicalTestItemRecord(
              name: i.name.trim(),
              result: exportOptional(normalizePhysicalTestResult(i.result)),
              score: exportOptional(i.score),
              level: exportOptional(i.level),
            ),
        ],
      ),
  ],
);

ExportModuleSource _physicalTestSource() {
  final service = PhysicalTestService.instance;
  return ExportModuleSource(
    module: ExportModule.physicalTest,
    readLocal: () async {
      final cached = service.peekCachedSnapshot();
      if (cached == null) return null;
      final updatedAt = cached.updatedAt;
      final stale =
          updatedAt == null ||
          DateTime.now().difference(updatedAt) >= PhysicalTestService.cacheTtl;
      return physicalTestModuleDataFromSnapshot(
        cached,
        status: _statusOf(stale: stale),
        source: _cacheSource,
      );
    },
    fetch: ({required force}) => guardExportFetch(() async {
      final snapshot = await service.fetchSnapshot(forceRefresh: force);
      return ExportFetched(
        physicalTestModuleDataFromSnapshot(
          snapshot,
          status: ExportModuleStatus.available,
          source: _freshSource,
        ),
      );
    }),
  );
}

/// 体测平台把中长跑成绩写成「分.秒」（如 `3.56 分钟` = 3 分 56 秒），
/// 直接交给 AI 会被当成小数分钟。秒位 < 60 时改写为「3分56秒（原文 3.56 分钟）」，
/// 其它形态保持原文。
String normalizePhysicalTestResult(String raw) {
  final m = RegExp(r'^(\d+)\.(\d{2})\s*分钟?$').firstMatch(raw.trim());
  if (m == null) return raw;
  final seconds = int.parse(m.group(2)!);
  if (seconds >= 60) return raw;
  return '${m.group(1)}分${m.group(2)}秒（原文 ${raw.trim()}）';
}
