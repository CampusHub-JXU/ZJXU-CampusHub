import '../../core/auth/zhengfang_auth.dart';
import '../campus_card/campus_card_service.dart';
import '../dorm_electricity/dorm_electricity_service.dart';
import '../exam/exam_model.dart';
import '../exam/exam_service.dart';
import '../grades/grades_service.dart';
import '../schedule/schedule_cache_snapshot.dart';
import '../schedule/schedule_service.dart';

/// Home 首屏恢复数据（快照协调器的输出之一）。
class HomeRestoreData {
  const HomeRestoreData({
    required this.campusCardBalance,
    required this.dormElectricity,
    required this.nextExam,
    required this.scheduleSnapshot,
    required this.courseLoggedIn,
    required this.hasScheduleCache,
  });

  final String campusCardBalance;
  final String dormElectricity;
  final ExamEntry? nextExam;
  final ScheduleCacheSnapshot? scheduleSnapshot;
  final bool courseLoggedIn;
  final bool hasScheduleCache;
}

/// 课表刷新结果。
class ScheduleRefreshResult {
  const ScheduleRefreshResult({
    required this.snapshot,
    required this.courseLoggedIn,
    required this.hasScheduleCache,
  });

  final ScheduleCacheSnapshot? snapshot;
  final bool courseLoggedIn;
  final bool hasScheduleCache;
}

/// Home 跨 feature 聚合协调器（PRD 0.7.0 §10/§11 的 `CampusSnapshotCoordinator`
/// 对应物）。
///
/// **为何放在 feature 内而非 `lib/app/snapshot/`（D6）**：`import_layering_test`
/// 禁止 `feature → app`，而 [HomePage] 依赖 `const HomePage()` 直接读取全局单例
/// （`home_page_test` 通过 `debugSetSnapshot` 等注入数据）。把协调器放到 app 层需要
/// 全量改造 HomePage 为依赖注入，收益低于风险。此处把原先散落在 HomePage 的
/// 跨 feature 拉取集中到唯一文件，HomePage/Resolver 不再直接触碰业务 service。
class CampusSnapshotCoordinator {
  CampusSnapshotCoordinator._();

  static final CampusSnapshotCoordinator instance = CampusSnapshotCoordinator._();

  bool get isAcademicLoggedIn => ZhengfangAuth.instance.isLoggedIn;

  /// 本地缓存首屏（不发网络）。
  HomeRestoreData restore(DateTime now) {
    final scheduleSnapshot = ScheduleService.instance.preferredSnapshot(
      termContext: ScheduleService.instance.getCurrentTermContext(now),
    );
    final hasScheduleCache = scheduleSnapshot?.hasData ?? false;
    final dormService = DormElectricityService.instance;
    return HomeRestoreData(
      campusCardBalance: CampusCardService.instance.formatBalance(
        CampusCardService.instance.cachedBalance,
      ),
      dormElectricity: dormService.formatElectricity(
        dormService.cachedElectricity,
      ),
      nextExam: ExamService.instance.nextExam,
      scheduleSnapshot: scheduleSnapshot,
      courseLoggedIn: isAcademicLoggedIn || hasScheduleCache,
      hasScheduleCache: hasScheduleCache,
    );
  }

  bool courseLoggedInForCache(bool hasScheduleCache) =>
      isAcademicLoggedIn || hasScheduleCache;

  Future<ScheduleRefreshResult> refreshSchedule() async {
    final now = DateTime.now();
    final result = await ScheduleService.instance.loadScheduleSnapshot(
      termContext: ScheduleService.instance.getCurrentTermContext(now),
    );
    final hasScheduleCache = result.snapshot?.hasData ?? false;
    return ScheduleRefreshResult(
      snapshot: result.snapshot,
      courseLoggedIn: courseLoggedInForCache(hasScheduleCache),
      hasScheduleCache: hasScheduleCache,
    );
  }

  /// 有缓存时直接返回缓存文案；无缓存时发网络。
  String? cachedCampusCardBalanceText() {
    final cached = CampusCardService.instance.cachedBalance;
    if (cached == null) return null;
    return CampusCardService.instance.formatBalance(cached);
  }

  Future<String> fetchCampusCardBalanceText() async {
    final networkBalance = await CampusCardService.instance.fetchBalance();
    return CampusCardService.instance.formatBalance(networkBalance);
  }

  Future<bool> hasElectricityRoomConfig() =>
      DormElectricityService.instance.hasRoomConfig();

  Future<String> fetchElectricityText() async {
    final service = DormElectricityService.instance;
    final value = await service.fetchElectricity();
    return service.formatElectricity(value);
  }

  ExamEntry? get cachedNextExam => ExamService.instance.nextExam;

  Future<ExamEntry?> fetchNextExam() async {
    await ExamService.instance.fetchExams();
    return ExamService.instance.nextExam;
  }

  Future<void> warmGrades() async {
    final studentId = ZhengfangAuth.instance.currentStudentId ?? '';
    await GradesService.instance.fetchGrades(studentId);
  }
}
