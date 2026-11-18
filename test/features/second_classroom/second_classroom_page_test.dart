import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/features/second_classroom/second_classroom_auth.dart';
import 'package:jxu_campus_hub/features/second_classroom/second_classroom_cache_store.dart';
import 'package:jxu_campus_hub/features/second_classroom/second_classroom_model.dart';
import 'package:jxu_campus_hub/features/second_classroom/second_classroom_page.dart';
import 'package:jxu_campus_hub/features/second_classroom/second_classroom_service.dart';
import 'package:jxu_campus_hub/features/second_classroom/second_classroom_subscription_service.dart';
import 'package:jxu_campus_hub/shared/widgets/app_status_tag.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const wechatChannel = MethodChannel('edu.zjxu.jxucampushub/wechat');

  setUp(() {
    // 订阅弹层的通知渠道行要查询真实权限状态，需注册插件实现才走可 mock 的方法通道。
    AndroidFlutterLocalNotificationsPlugin.registerWith();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(wechatChannel, null);
  });

  test('detects second classroom auth provider entry urls', () {
    expect(
      isSecondClassroomAuthProviderEntryUrl(
        '${SecondClassroomPage.authEntryUrl}test-code',
      ),
      isTrue,
    );
    expect(
      isSecondClassroomAuthProviderEntryUrl(SecondClassroomPage.initialUrl),
      isFalse,
    );
  });

  test('detects second classroom landing root urls', () {
    expect(
      isSecondClassroomLandingRootUrl('https://twdekt.zjxu.edu.cn/dekt/'),
      isTrue,
    );
    expect(
      isSecondClassroomLandingRootUrl('https://twdekt.zjxu.edu.cn/dekt'),
      isTrue,
    );
    expect(
      isSecondClassroomLandingRootUrl(SecondClassroomPage.initialUrl),
      isFalse,
    );
  });

  test('detects WeChat OAuth urls', () {
    expect(
      isSecondClassroomWeChatAuthUri(
        Uri.parse(
          'https://open.weixin.qq.com/connect/oauth2/authorize?appid=wx123',
        ),
      ),
      isTrue,
    );
    expect(
      isSecondClassroomWeChatAuthUri(
        Uri.parse('https://twdekt.zjxu.edu.cn/dekt/wx/index?_WXFTL=0'),
      ),
      isFalse,
    );
  });

  test('detects anonymous second classroom state', () {
    expect(isSecondClassroomAnonymousState({'hasAnonymous': true}), isTrue);
    expect(isSecondClassroomAnonymousState({'hasGuest': true}), isTrue);
    expect(isSecondClassroomAnonymousState({'hasMyPage': true}), isFalse);
  });

  testWidgets('renders native second classroom activity list', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SecondClassroomPage(
          service: _FakeSecondClassroomService(),
          authEnsurer: _testAuth,
          subscriptionService: _testSubscriptionService(),
          cacheStore: _MemoryCacheStore(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('第二课堂'), findsOneWidget);
    expect(find.text('榜样分享活动'), findsOneWidget);
    expect(find.text('招募中'), findsOneWidget);
    expect(find.byTooltip('在微信中打开'), findsOneWidget);
    // 状态 chip 行 + 排序 + 筛选入口，不再横排多个下拉（ui-unification-plan §4.5）。
    expect(find.widgetWithText(ChoiceChip, '全部'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, '正在招募'), findsOneWidget);
    expect(find.text('即将开始'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '筛选'), findsOneWidget);
    expect(find.text('共 1 个活动'), findsOneWidget);
    // 招募状态走主题 container 色调，不写死颜色。
    final tag = tester.widget<AppStatusTag>(
      find.ancestor(of: find.text('招募中'), matching: find.byType(AppStatusTag)),
    );
    expect(tag.tone, AppStatusTone.positive);
  });

  testWidgets('shows the CAS login entry when the session needs login', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SecondClassroomPage(
          service: _FakeSecondClassroomService(),
          authEnsurer: _needsLoginAuth,
          subscriptionService: _testSubscriptionService(),
          cacheStore: _MemoryCacheStore(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('登录后查看报名状态'), findsOneWidget);
    expect(find.text('登录统一认证'), findsOneWidget);
  });

  testWidgets('status chip and filter sheet update the query', (tester) async {
    final service = _FakeSecondClassroomService();
    await tester.pumpWidget(
      MaterialApp(
        home: SecondClassroomPage(
          service: service,
          authEnsurer: _testAuth,
          subscriptionService: _testSubscriptionService(),
          cacheStore: _MemoryCacheStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ChoiceChip, '正在招募'));
    await tester.pumpAndSettle();
    expect(
      service.queries.last.status,
      SecondClassroomActivityStatus.recruiting,
    );

    await tester.tap(find.widgetWithText(TextButton, '筛选'));
    await tester.pumpAndSettle();
    expect(find.text('组织类型'), findsOneWidget);
    expect(find.text('所属学院'), findsOneWidget);
    expect(find.text('全部活动（含未开放）'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, '建筑工程学院'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '完成'));
    await tester.pumpAndSettle();

    final last = service.queries.last;
    expect(last.departmentId, '51');
    expect(last.status, SecondClassroomActivityStatus.recruiting);
    expect(find.widgetWithText(TextButton, '筛选 · 1'), findsOneWidget);
  });

  testWidgets('opens second classroom in WeChat from app bar', (tester) async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(wechatChannel, (call) async {
          calls.add(call);
          return true;
        });

    await tester.pumpWidget(
      MaterialApp(
        home: SecondClassroomPage(
          service: _FakeSecondClassroomService(),
          authEnsurer: _testAuth,
          subscriptionService: _testSubscriptionService(),
          cacheStore: _MemoryCacheStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('在微信中打开'));
    await tester.pumpAndSettle();

    expect(calls.map((call) => call.method), contains('openUrlInWeChat'));
    expect(
      (calls.last.arguments as Map<Object?, Object?>)['url'],
      SecondClassroomPage.initialUrl,
    );
    expect(find.text('已请求打开微信，若未直达请复制链接后在微信中完成第二课堂授权'), findsOneWidget);
    expect(find.widgetWithText(SnackBarAction, '复制链接'), findsOneWidget);
  });

  testWidgets('app bar wechat failure offers copy of exact page url', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(wechatChannel, (call) async => false);
    final clipboard = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard.add((call.arguments as Map)['text'] as String);
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: SecondClassroomPage(
          service: _FakeSecondClassroomService(),
          authEnsurer: _testAuth,
          subscriptionService: _testSubscriptionService(),
          cacheStore: _MemoryCacheStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('在微信中打开'));
    await tester.pumpAndSettle();

    expect(find.text('无法拉起微信，请复制链接后到微信中打开'), findsOneWidget);
    expect(find.textContaining('已安装微信'), findsNothing);
    expect(find.textContaining('已打开微信'), findsNothing);

    await tester.tap(find.widgetWithText(SnackBarAction, '复制链接'));
    await tester.pumpAndSettle();

    expect(clipboard, [SecondClassroomPage.initialUrl]);
    expect(find.text('链接已复制'), findsOneWidget);
  });

  testWidgets('opens activity detail page in WeChat from detail sheet', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(wechatChannel, (call) async {
          calls.add(call);
          return true;
        });

    await tester.pumpWidget(
      MaterialApp(
        home: SecondClassroomPage(
          service: _FakeSecondClassroomService(),
          authEnsurer: _testAuth,
          subscriptionService: _testSubscriptionService(),
          cacheStore: _MemoryCacheStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('榜样分享活动'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.byTooltip('微信版'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(calls.map((call) => call.method), contains('openUrlInWeChat'));
    expect(
      (calls.last.arguments as Map<Object?, Object?>)['url'],
      'https://twdekt.zjxu.edu.cn/dekt/wx/index?_WXFTL=0#/hd-detail?hdId=2485',
    );
    expect(find.text('已请求打开微信，若未直达请复制链接后在微信中查看该活动详情'), findsOneWidget);
    expect(find.widgetWithText(SnackBarAction, '复制链接'), findsOneWidget);
  });

  testWidgets('订阅弹层提供直达第二课堂通知渠道并如实说明限制', (tester) async {
    const systemSettingsChannel = MethodChannel(
      'edu.zjxu.jxucampushub/system_settings',
    );
    const notificationsChannel = MethodChannel(
      'dexterous.com/flutter/local_notifications',
    );
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(systemSettingsChannel, (call) async {
      calls.add(call);
      return 'target';
    });
    messenger.setMockMethodCallHandler(notificationsChannel, (call) async {
      if (call.method == 'areNotificationsEnabled') return true;
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(systemSettingsChannel, null);
      messenger.setMockMethodCallHandler(notificationsChannel, null);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: SecondClassroomPage(
          service: _FakeSecondClassroomService(),
          authEnsurer: _testAuth,
          subscriptionService: _testSubscriptionService(),
          cacheStore: _MemoryCacheStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('已订阅活动名'));
    await tester.pumpAndSettle();

    expect(find.text('开招提醒'), findsOneWidget);
    expect(find.text('通知横幅设置'), findsOneWidget);
    // 如实说明：不承诺横幅、不承诺开招瞬间提醒。
    expect(find.textContaining('无法代为开启'), findsOneWidget);
    expect(find.textContaining('不保证在活动刚开招的瞬间提醒'), findsOneWidget);

    await tester.tap(find.text('通知横幅设置'));
    await tester.pumpAndSettle();

    expect(calls, hasLength(1));
    expect(calls.single.method, 'open');
    expect(calls.single.arguments, <String, Object?>{
      'target': 'notificationChannel',
      'channelId': 'second_classroom_activity_reminder',
    });
    // 命中渠道页不弹提示：打开设置页不代表横幅已开启。
    expect(find.byType(SnackBar), findsNothing);
  });
  for (final status in ['denied', 'unknown', 'unsupported']) {
    testWidgets('订阅弹层区分权限拒绝与未知或不支持：$status', (tester) async {
      const channel = MethodChannel(
        'dexterous.com/flutter/local_notifications',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      if (status == 'unsupported') {
        // 当前目标仍是 Android，但没有对应的平台实现。
        IOSFlutterLocalNotificationsPlugin.registerWith();
      }
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'areNotificationsEnabled' && status == 'denied') {
          return false;
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(
        MaterialApp(
          home: SecondClassroomPage(
            service: _FakeSecondClassroomService(),
            authEnsurer: _testAuth,
            subscriptionService: _testSubscriptionService(),
            cacheStore: _MemoryCacheStore(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('已订阅活动名'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('系统通知权限未开启'),
        status == 'denied' ? findsOneWidget : findsNothing,
      );
      expect(
        find.textContaining('通知状态未知'),
        status == 'denied' ? findsNothing : findsOneWidget,
      );
    });
  }
}

SecondClassroomSubscriptionService _testSubscriptionService() {
  return SecondClassroomSubscriptionService(
    notifyRecruitingActivity: ({
      required id,
      required title,
      required body,
      required payload,
    }) async {},
  );
}

class _FakeSecondClassroomService extends SecondClassroomService {
  @override
  Future<SecondClassroomCatalog> fetchCatalog() async {
    return const SecondClassroomCatalog(
      categories: [SecondClassroomFilterOption(value: '1', text: '思想成长')],
      departments: [SecondClassroomFilterOption(value: '51', text: '建筑工程学院')],
      organizationTypes: [
        SecondClassroomFilterOption(value: '2', text: '学生部门'),
      ],
    );
  }

  final queries = <SecondClassroomActivityQuery>[];

  @override
  Future<SecondClassroomActivityPage> searchActivities(
    SecondClassroomActivityQuery query,
  ) async {
    queries.add(query);
    return SecondClassroomActivityPage(
      items: [_activity],
      pageIndex: query.page,
      pageSize: query.limit,
      totalPages: 1,
      count: 1,
    );
  }

  @override
  Future<SecondClassroomActivityDetail> fetchActivityDetail(
    int id, {
    bool authenticated = false,
  }) async {
    return SecondClassroomActivityDetail(
      activity: _activity,
      signUpMode: '报名无需审核，人满即止',
      limitedCollege: '不限',
      limitedGrade: '不限',
      hasCredit: false,
      isFavorite: false,
      isInRegistrationTime: true,
    );
  }

  @override
  String imageUrl(String imageId) => '';
}

final _activity = SecondClassroomActivity(
  id: 2485,
  title: '榜样分享活动',
  coverId: '',
  iconId: '',
  registrationStartAt: DateTime(2026, 6, 8),
  registrationEndAt: DateTime.now().add(const Duration(days: 2)),
  activityStartAt: DateTime.now().add(const Duration(days: 3)),
  activityEndAt: DateTime.now().add(const Duration(days: 3, hours: 2)),
  creditHours: 0,
  location: '兴德楼北楼201',
  summary: '报名成功后加群',
  contactName: '张展健',
  contactPhone: '18536419261',
  categoryName: '思想成长',
  organizerName: '建工学院团委学生会',
  capacity: 90,
  enrolledCount: 31,
  isRegistered: false,
  hasCheckedIn: false,
  hasRetaken: false,
);

Future<SecondClassroomAuthState> _testAuth({bool force = false}) async =>
    SecondClassroomAuthState.authenticated;

Future<SecondClassroomAuthState> _needsLoginAuth({bool force = false}) async =>
    SecondClassroomAuthState.needsLogin;

/// 内存缓存替身：widget 测试跑在 FakeAsync 区，真实 [JsonCacheStore] 文件 I/O
/// 不会完成，pumpAndSettle 会超时。
class _MemoryCacheStore implements SecondClassroomCacheStore {
  SecondClassroomCatalog? _catalog;
  final _activities = <String, SecondClassroomActivityCacheSnapshot>{};

  String _key(SecondClassroomActivityQuery query) =>
      '${query.categoryId}|${query.status.value}|${query.departmentId}|'
      '${query.sort.value}|${query.organizationType.value}|${query.keyword}';

  @override
  Future<SecondClassroomCatalog?> loadCatalog() async => _catalog;

  @override
  Future<void> saveCatalog(SecondClassroomCatalog catalog) async {
    _catalog = catalog;
  }

  @override
  Future<SecondClassroomActivityCacheSnapshot?> loadActivities(
    SecondClassroomActivityQuery query,
  ) async => _activities[_key(query)];

  @override
  Future<void> saveActivities(
    SecondClassroomActivityQuery query,
    List<SecondClassroomActivity> activities,
  ) async {
    _activities[_key(query)] = SecondClassroomActivityCacheSnapshot(
      activities: activities,
      updatedAt: DateTime.now(),
    );
  }

  @override
  Future<void> debugClear() async {
    _catalog = null;
    _activities.clear();
  }
}
