import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/core/academic/schedule_cache_snapshot.dart';
import 'package:jxu_campus_hub/core/academic/schedule_model.dart';
import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/core/notice/notice_model.dart';
import 'package:jxu_campus_hub/core/notice/notice_sync_store.dart';
import 'package:jxu_campus_hub/core/semester/china_public_holidays.dart';
import 'package:jxu_campus_hub/core/semester/schedule_term_context.dart';
import 'package:jxu_campus_hub/core/semester/semester_calendar.dart';
import 'package:jxu_campus_hub/core/system_surface/campus_data_change_bus.dart';
import 'package:jxu_campus_hub/core/system_surface/campus_widget_bridge.dart';
import 'package:jxu_campus_hub/core/theme/app_theme_controller.dart';
import 'package:jxu_campus_hub/features/dorm_electricity/dorm_electricity_service.dart';
import 'package:jxu_campus_hub/features/home/widget/campus_widget_projection.dart';
import 'package:jxu_campus_hub/features/home/widget/campus_widget_sync.dart';
import 'package:jxu_campus_hub/features/schedule/schedule_service.dart';

import '../../helpers/test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final gateway = _FakeCampusWidgetGateway();
  final pushes = gateway.snapshots;

  setUp(() async {
    pushes.clear();
    await resetTestEnvironment();
    CampusWidgetBridge.instance.setGatewayForTesting(gateway);
    CampusWidgetSync.instance.start();
  });

  tearDown(() {
    AppThemeController.instance.updateSeedColor(
      AppThemeController.defaultCustomSeedColor,
    );
    NoticeSyncStore.instance.debugReset();
    debugChinaPublicHolidaysOverride = null;
    CampusWidgetBridge.instance.setGatewayForTesting(null);
    CampusWidgetSync.instance.debugReset();
    CampusDataChangeBus.instance.debugReset();
  });

  test('校园数据变化会触发一次去凭据的桌面投影推送', () async {
    CampusDataChangeBus.instance.notifyChanged();
    await pumpEventQueue();

    expect(pushes, hasLength(1));
    final snapshot = pushes.single;
    expect(snapshot.keys, contains('generatedAt'));
    expect(snapshot.keys, isNot(contains('cookie')));
    expect(snapshot.keys, isNot(contains('token')));
  });

  test('统一认证身份变化会重推桌面投影并清掉上一账号电费', () async {
    // A 的房间配置 / 余额缓存都带 A 的 owner 标记：无论 restoreCache 何时
    // 完成，投影都只会看到 A 自己的 3.2 度。
    SharedPreferences.setMockInitialValues({
      'dorm_epay_area_id': 'area',
      'dorm_epay_building_id': 'building',
      'dorm_epay_floor_id': 'floor',
      'dorm_epay_room_id': 'room',
      DormElectricityService.roomOwnerKey: 'casuserA',
      'dorm_cached_electricity': 3.2,
      'dorm_cached_electricity_updated_at':
          DateTime.now().millisecondsSinceEpoch,
    });
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: 'casuserA',
    );
    UnifiedAuthService.instance.notifyListeners();
    await pumpEventQueue();
    pushes.clear();

    // A 的电费内存缓存归属 A，投影可见（格式化保留两位小数）。
    DormElectricityService.instance.debugSetCachedElectricity(
      3.2,
      updatedAt: DateTime.now(),
    );
    await CampusWidgetSync.instance.syncNow();
    expect(pushes, hasLength(1));
    var snapshot = pushes.last;
    expect(snapshot['dormElectricity'], '3.20');
    expect(snapshot['hasElectricityData'], isTrue);

    // 换号到 B：身份变化必须触发重推，且投影只读 owner 归属校验后的缓存，
    // 不得残留上一账号的低电量。
    pushes.clear();
    UnifiedAuthService.instance.debugSetSession(
      active: true,
      account: 'casuserB',
    );
    UnifiedAuthService.instance.notifyListeners();
    await pumpEventQueue();

    expect(pushes, isNotEmpty);
    snapshot = pushes.last;
    expect(snapshot['dormElectricity'], '--');
    expect(snapshot['hasElectricityData'], isFalse);
  });
  test('主题色变化会立即重推快照，theme 强调色随之改变', () async {
    CampusWidgetSync.instance.debugSetDebounce(Duration.zero);
    await CampusWidgetSync.instance.syncNow();
    var theme = pushes.last['theme'] as Map;
    final before = theme['accentLight'];
    expect(before, '#8B1A2D');
    pushes.clear();

    AppThemeController.instance.updateSeedColor(const Color(0xFF1565C0));
    await pumpEventQueue();

    expect(pushes, isNotEmpty);
    theme = pushes.last['theme'] as Map;
    expect(theme['accentLight'], isNot(before));
    expect(theme['accentLight'], matches(RegExp(r'^#[0-9A-F]{6}$')));
    expect(theme['accentDark'], matches(RegExp(r'^#[0-9A-F]{6}$')));
  });

  test('未登录：emptyState=notLoggedIn，7 天全空课程，不含身份字段', () async {
    await CampusWidgetSync.instance.syncNow();
    final snapshot = pushes.last;
    expect(snapshot['schemaVersion'], 2);
    expect(snapshot['emptyState'], 'notLoggedIn');
    expect(snapshot['emptyStateText'], '登录教务后显示课表');
    final days = snapshot['days'] as List;
    expect(days, hasLength(7));
    expect(days.every((d) => (d as Map)['courses'].isEmpty as bool), isTrue);
    final encoded = jsonEncode(snapshot);
    expect(encoded.contains('"null"'), isFalse);
  });

  test('已验证 owner 的课表缓存输出课程；登出后立即回落且无课程', () async {
    debugChinaPublicHolidaysOverride = const [];
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    // 开学日取今天所在周的周一，保证窗口全在第 1 周内。
    await SemesterCalendar.instance.setSemesterStartDate(
      today.subtract(Duration(days: today.weekday - 1)),
    );
    const studentId = '2025000001';
    ZhengfangAuth.instance.debugSetSession(active: true, studentId: studentId);
    ScheduleService.instance.debugSetSnapshot(
      ScheduleCacheSnapshot(
        studentId: studentId,
        termContext: ScheduleTermContext.current(now),
        courses: [
          for (var weekday = 1; weekday <= 7; weekday++)
            CourseEntry(
              courseName: '高等数学',
              teacherName: '张老师',
              weekday: weekday,
              startLesson: 1,
              endLesson: 2,
              weekRange: '1-2周',
              classroom: '7-201',
              campus: '梁林校区',
              typeSymbol: '',
            ),
        ],
        scheduleUpdatedAt: now,
        changeRulesUpdatedAt: now,
      ),
    );

    await CampusWidgetSync.instance.syncNow();
    var snapshot = pushes.last;
    expect(snapshot['emptyState'], isNull);
    final days = (snapshot['days'] as List).cast<Map>();
    expect(days, hasLength(7));
    expect(days.first['date'], matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
    final firstCourses = (days.first['courses'] as List).cast<Map>();
    expect(firstCourses.single['courseName'], '高等数学');
    expect(firstCourses.single['timeText'], '08:00-09:25');
    // 窗口内只有教学周 1-2 的日子有课（第 3 周起无课）：至少今天有课。
    expect(days.expand((d) => d['courses'] as List), isNotEmpty);

    // 登出：owner 失效 → 不再输出任何课程，状态回落。
    pushes.clear();
    ZhengfangAuth.instance.debugReset();
    await CampusWidgetSync.instance.syncNow();
    snapshot = pushes.last;
    expect(snapshot['emptyState'], 'notLoggedIn');
    expect(
      (snapshot['days'] as List).expand((d) => (d as Map)['courses'] as List),
      isEmpty,
    );
    final encoded = jsonEncode(snapshot);
    expect(encoded.contains(studentId), isFalse);
  });

  test('通知：未读数与最新条目进入 notices，条目不超过 5', () async {
    NoticeSyncStore.instance.unreadSummary.value = NoticeUnreadSummary(
      count: 9,
      latest: [
        for (var i = 1; i <= 7; i++)
          Notice(
            title: '通知 $i',
            url: 'https://example.invalid/$i',
            category: '通知公告',
            date: '2026-10-0$i',
          ),
      ],
    );
    await pumpEventQueue();
    pushes.clear();
    await CampusWidgetSync.instance.syncNow();
    final notices = pushes.last['notices'] as Map;
    expect(notices['unreadCount'], 9);
    final items = (notices['items'] as List).cast<Map>();
    expect(items, hasLength(5));
    expect(items.first, {'title': '通知 1', 'publishedAt': '2026-10-01'});
    expect(pushes.last['unreadNoticeCount'], 9, reason: 'v1 兼容字段保留');
  });

  test('buildCampusWidgetProjection 的 toMap 可直接 JSON 编码', () {
    final map = buildCampusWidgetProjection(now: DateTime(2026, 10, 16, 7, 58))
        .toMap();
    expect(map['generatedAt'], '2026-10-16T07:58:00');
    expect(() => jsonEncode(map), returnsNormally);
  });
}

/// 记录式 CampusWidgetGateway 替身：只关心推送到原生的展示投影。
class _FakeCampusWidgetGateway implements CampusWidgetGateway {
  final snapshots = <Map<String, Object?>>[];

  @override
  Future<void> pushSnapshot(Map<String, Object?> projection) async {
    snapshots.add(projection);
  }

  @override
  Future<CampusWidgetPinResult> requestPin(CampusWidgetSize size) async =>
      CampusWidgetPinResult.unsupported;

  @override
  Future<CampusWidgetStatus> getStatus() async => CampusWidgetStatus.unknown;

  @override
  Future<Uint8List?> getPreview(
    CampusWidgetSize size, {
    required int widthPx,
  }) async => null;

  @override
  Future<bool> isSupported() async => false;
}
