import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/features/changxing_jiada/changxing_jiada_model.dart';
import 'package:jxu_campus_hub/features/changxing_jiada/changxing_jiada_page.dart';
import 'package:jxu_campus_hub/features/changxing_jiada/changxing_jiada_service.dart';
import 'package:jxu_campus_hub/features/changxing_jiada/changxing_jiada_widgets.dart';
import 'package:jxu_campus_hub/shared/widgets/app_status_tag.dart';
import 'package:jxu_campus_hub/shared/widgets/plain_list.dart';

import '../../helpers/test_setup.dart';

/// 畅行嘉大仪表盘版式回归（#57 / #58）：
///
/// * 仅覆盖视觉 / 信息层级：纯装饰性横竖分割线彻底移除、概览三项统计的
///   真实数据与主次层级、「最近申请」类型 / 状态 / 时间可扫读、个人资料
///   折叠可达性、空态、360dp + 2x 字号的排版稳健性；
/// * 不触碰任何认证 / 会话 / 生成号 / owner 逻辑——那部分仍由
///   `changxing_jiada_page_test.dart` 原样守护。

const _account = '20260001';
const _longName = '欧阳娜娜娜娜娜娜娜娜娜娜娜娜';

ChangxingUserProfile _profile({
  String name = '李明',
  String jobNo = '20260001',
  String phone = '13800000000',
  String emergencyContact = '家长',
  String emergencyPhone = '13900000000',
}) => ChangxingUserProfile(
  name: name,
  jobNo: jobNo,
  phone: phone,
  emergencyContact: emergencyContact,
  emergencyPhone: emergencyPhone,
);

ChangxingApplication _application({
  int id = 1,
  int type = 1,
  int status = 0,
  String userName = '王小明',
  String departmentName = '计算机261',
  DateTime? upTime,
}) => ChangxingApplication(
  id: id,
  type: type,
  status: status,
  userName: userName,
  departmentName: departmentName,
  userJobNo: '20260001',
  userPhone: '13800000000',
  descr: '临时请假',
  remark: '',
  trafficTool: '火车',
  backStatus: 0,
  notBackReason: '',
  emergencyContact: '家长',
  emergencyPhone: '13900000000',
  startTime: DateTime(2026, 9, 1, 8),
  endTime: DateTime(2026, 9, 2, 18),
  upTime: upTime ?? DateTime(2026, 9, 1, 9),
);

ChangxingDashboardSnapshot _snapshot({
  ChangxingUserProfile? profile,
  int unreadCount = 2,
  List<ChangxingApplication>? applications,
}) => (
  profile: profile ?? _profile(),
  unreadCount: unreadCount,
  applications: applications ?? [_application()],
);

/// 注入固定快照直接渲染仪表盘（无网络、无 CAS）。
Future<void> _pumpDashboard(
  WidgetTester tester, {
  ChangxingDashboardSnapshot? snapshot,
  Size? size,
  double textScale = 1.0,
}) async {
  UnifiedAuthService.instance.debugSetSession(active: true, account: _account);
  if (size != null) {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
  }
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: ChangxingJiadaPage(
        sessionRestorer: () async => true,
        casLogin: () async => throw StateError('已有 token，不应再登录'),
        signOut: () async {},
        dashboardFetcher: () async => snapshot ?? _snapshot(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 任何 `Divider` / `VerticalDivider` / 「宽 1dp 的细条 Container」都算
/// 装饰性分割线——它们正是本次要清除的对象。
void _expectNoDecorativeLines(WidgetTester tester) {
  expect(find.byType(Divider), findsNothing);
  expect(find.byType(VerticalDivider), findsNothing);
  final hairlineContainers = tester
      .widgetList<Container>(find.byType(Container))
      .where(
        (c) =>
            c.constraints?.minWidth == 1 &&
            c.constraints?.maxWidth == 1 &&
            (c.constraints?.maxHeight ?? 0) > 1,
      );
  expect(hairlineContainers, isEmpty, reason: '页面上出现了宽 1dp 的装饰细线');
}

void main() {
  setUp(() async {
    await resetTestEnvironment();
    ChangxingJiadaService.instance.debugReset();
  });

  testWidgets('仪表盘不再有任何横竖装饰分割线', (tester) async {
    await _pumpDashboard(
      tester,
      snapshot: _snapshot(
        applications: [
          _application(id: 1, status: 4, upTime: DateTime(2026, 9, 6, 10)),
          _application(id: 2, status: 0),
        ],
      ),
    );
    _expectNoDecorativeLines(tester);
    // 顶部身份块与概览同时可见。
    expect(find.text('李明'), findsOneWidget);
    expect(find.text('概览'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('概览三项统计用真实数据，「办理中」强调、其余为次级', (tester) async {
    // 3 条申请：1 待审核(0) / 1 未通过(2) / 1 已返校(4) → 办理中 1、总数 3；
    // 未读 2。三个值互相区分，避免断言互相串台。
    await _pumpDashboard(
      tester,
      snapshot: _snapshot(
        unreadCount: 2,
        applications: [
          _application(id: 1, status: 0),
          _application(id: 2, status: 2),
          _application(id: 3, status: 4),
        ],
      ),
    );

    expect(find.text('办理中'), findsOneWidget);
    expect(find.text('未读消息'), findsOneWidget);
    expect(find.text('申请总数'), findsOneWidget);

    final metrics = tester
        .widgetList<ChangxingMetric>(find.byType(ChangxingMetric))
        .toList();
    expect(metrics.length, 3);
    final pending = metrics.firstWhere((m) => m.label == '办理中');
    expect(pending.value, 1);
    expect(pending.emphasized, isTrue);
    expect(
      metrics.where((m) => m.label != '办理中').every((m) => !m.emphasized),
      isTrue,
    );

    // 强调数字取主色（rowValue 档），次级数字取 onSurface 常规色。
    final cs = Theme.of(tester.element(find.byType(ChangxingMetric).first))
        .colorScheme;
    final pendingText = tester.widget<Text>(
      find.descendant(of: find.byWidget(pending), matching: find.text('1')),
    );
    expect(pendingText.style?.color, cs.primary);
    final unread = metrics.firstWhere((m) => m.label == '未读消息');
    final unreadText = tester.widget<Text>(
      find.descendant(of: find.byWidget(unread), matching: find.text('2')),
    );
    expect(unreadText.style?.color, cs.onSurface);
    expect(tester.takeException(), isNull);
  });

  testWidgets('最近申请用类型 + 语义状态标签 + 更新时间，不拼接无意义长串', (tester) async {
    await _pumpDashboard(
      tester,
      snapshot: _snapshot(
        applications: [
          _application(
            id: 9,
            type: 1,
            status: 4,
            upTime: DateTime(2026, 9, 6, 10, 30),
          ),
        ],
      ),
    );

    expect(find.text('最近申请'), findsOneWidget);
    // 类型标签与申请卡共用「请假」文案。
    expect(find.text('请假'), findsWidgets);
    final tags = tester
        .widgetList<AppStatusTag>(find.byType(AppStatusTag))
        .toList();
    final statusTag = tags.firstWhere((t) => t.label == '已返校');
    // status=4 → positive（沿用既有语义映射，不新造状态）。
    expect(statusTag.tone, AppStatusTone.positive);
    expect(find.textContaining('更新 2026/09/06'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('个人资料折叠：默认不露出学号 / 电话，一点可展开且紧急联系人可达', (tester) async {
    await _pumpDashboard(tester);

    expect(find.text('个人资料'), findsOneWidget);
    // 收起态：敏感字段不进首屏。
    expect(find.text('20260001'), findsNothing);
    expect(find.text('13800000000'), findsNothing);
    expect(find.text('紧急联系人'), findsNothing);

    await tester.tap(find.text('个人资料'));
    await tester.pumpAndSettle();

    expect(find.text('学号'), findsOneWidget);
    expect(find.text('20260001'), findsOneWidget);
    expect(find.text('联系电话'), findsOneWidget);
    expect(find.text('13800000000'), findsOneWidget);
    expect(find.text('紧急联系人'), findsOneWidget);
    expect(find.textContaining('家长'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('没有申请时不造假卡：无「最近申请」、概览为安静零值、展示空态', (tester) async {
    await _pumpDashboard(
      tester,
      snapshot: _snapshot(unreadCount: 0, applications: const []),
    );

    expect(find.text('最近申请'), findsNothing);

    final metrics = tester
        .widgetList<ChangxingMetric>(find.byType(ChangxingMetric))
        .toList();
    expect(metrics.every((m) => m.value == 0), isTrue);
    final cs = Theme.of(tester.element(find.byType(ChangxingMetric).first))
        .colorScheme;
    final zeroPending = tester.widget<Text>(
      find.descendant(
        of: find.byWidget(metrics.firstWhere((m) => m.label == '办理中')),
        matching: find.text('0'),
      ),
    );
    // 零值不再抢眼：转 onSurfaceVariant。
    expect(zeroPending.style?.color, cs.onSurfaceVariant);

    await tester.drag(find.byType(ListView), const Offset(0, -420));
    await tester.pumpAndSettle();
    expect(find.text('暂无申请记录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('四个快速办理入口保留且可点（命中高度 ≥ 52），左下无裸控件', (tester) async {
    await _pumpDashboard(tester);

    expect(find.text('请假申请'), findsOneWidget);
    expect(find.text('离校登记'), findsOneWidget);
    expect(find.text('返校登记'), findsOneWidget);
    expect(find.text('超时登记'), findsOneWidget);

    final rows = tester
        .widgetList<PlainListRow>(find.byType(PlainListRow))
        .toList();
    expect(rows.length, 4);
    expect(rows.every((r) => r.onTap != null), isTrue);
    for (var i = 0; i < rows.length; i++) {
      final height = tester.getSize(find.byType(PlainListRow).at(i)).height;
      expect(height, greaterThanOrEqualTo(52));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('可编辑申请保留「编辑申请」入口与明细，申请卡无装饰分割线', (tester) async {
    await _pumpDashboard(
      tester,
      snapshot: _snapshot(
        applications: [
          _application(id: 7, type: 1, status: 0, departmentName: '计算机261'),
        ],
      ),
    );

    await tester.drag(find.byType(ListView), const Offset(0, -420));
    await tester.pumpAndSettle();

    expect(find.text('编辑申请'), findsOneWidget);
    expect(find.text('班级'), findsWidgets);
    expect(find.text('计算机261'), findsWidgets);
    _expectNoDecorativeLines(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('360dp + 2x 字号 + 超长姓名 / 部门：不溢出、无字段串位', (tester) async {
    await _pumpDashboard(
      tester,
      size: const Size(360, 780),
      textScale: 2,
      snapshot: _snapshot(
        profile: _profile(name: _longName),
        unreadCount: 12,
        applications: [
          _application(
            id: 11,
            type: 3,
            status: 1,
            departmentName: '计算机科学与技术（卓越工程师计划）261 班',
            upTime: DateTime(2026, 12, 31, 23, 59),
          ),
        ],
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text(_longName), findsOneWidget);
    expect(find.text('办理中'), findsOneWidget);

    // 滚过整页，让概览 / 快速办理 / 最近申请 / 申请卡全部参与布局。
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('请假申请'), findsOneWidget);
  });

  testWidgets('版式几何：身份 → 概览（统计 + 最近申请）→ 快速办理 → 我的申请 自上而下', (tester) async {
    await _pumpDashboard(
      tester,
      size: const Size(412, 2000),
      snapshot: _snapshot(
        applications: [
          _application(id: 1, status: 1, upTime: DateTime(2026, 9, 6, 10, 30)),
        ],
      ),
    );

    double topOf(Finder f) => tester.getTopLeft(f).dy;
    final identity = topOf(find.text('李明'));
    final overviewHeader = topOf(find.text('概览'));
    final pendingLabel = topOf(find.text('办理中'));
    final recentLabel = topOf(find.text('最近申请'));
    final actionHeader = topOf(find.text('快速办理'));
    final applicationsHeader = topOf(find.textContaining('我的申请'));

    expect(identity, lessThan(overviewHeader));
    expect(overviewHeader, lessThan(pendingLabel));
    expect(pendingLabel, lessThan(recentLabel));
    expect(recentLabel, lessThan(actionHeader));
    expect(actionHeader, lessThan(applicationsHeader));

    // 三项统计自左向右：办理中 → 未读消息 → 申请总数（三列无竖线，靠间距分栏）。
    final xPending = tester.getTopLeft(find.text('办理中')).dx;
    final xUnread = tester.getTopLeft(find.text('未读消息')).dx;
    final xTotal = tester.getTopLeft(find.text('申请总数')).dx;
    expect(xPending, lessThan(xUnread));
    expect(xUnread, lessThan(xTotal));
    expect(tester.takeException(), isNull);
  });
}
