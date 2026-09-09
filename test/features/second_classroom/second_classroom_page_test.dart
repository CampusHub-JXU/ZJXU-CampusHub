import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/features/second_classroom/second_classroom_model.dart';
import 'package:jxu_campus_hub/features/second_classroom/second_classroom_page.dart';
import 'package:jxu_campus_hub/features/second_classroom/second_classroom_service.dart';
import 'package:jxu_campus_hub/features/second_classroom/second_classroom_subscription_service.dart';
import 'package:jxu_campus_hub/shared/widgets/app_dropdown.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const wechatChannel = MethodChannel('edu.zjxu.jxucampushub/wechat');

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
          subscriptionService: _testSubscriptionService(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('第二课堂'), findsOneWidget);
    expect(find.text('榜样分享活动'), findsOneWidget);
    expect(find.text('招募中'), findsOneWidget);
    expect(find.byTooltip('在微信中打开'), findsOneWidget);
    expect(
      find.byWidgetPredicate((widget) => widget is AppDropdown),
      findsNWidgets(5),
    );
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
          subscriptionService: _testSubscriptionService(),
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
    expect(find.text('已打开微信，请在微信中完成第二课堂授权'), findsOneWidget);
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
          subscriptionService: _testSubscriptionService(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('在微信中打开'));
    await tester.pumpAndSettle();

    expect(find.text('未能打开页面，可复制链接后到微信中打开'), findsOneWidget);
    expect(find.textContaining('已安装微信'), findsNothing);

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
          subscriptionService: _testSubscriptionService(),
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
    expect(find.text('已打开微信，可直接查看该活动详情'), findsOneWidget);
    expect(find.widgetWithText(SnackBarAction, '复制链接'), findsOneWidget);
  });
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

  @override
  Future<SecondClassroomActivityPage> searchActivities(
    SecondClassroomActivityQuery query,
  ) async {
    return SecondClassroomActivityPage(
      items: [_activity],
      pageIndex: query.page,
      pageSize: query.limit,
      totalPages: 1,
      count: 1,
    );
  }

  @override
  Future<SecondClassroomActivityDetail> fetchActivityDetail(int id) async {
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
