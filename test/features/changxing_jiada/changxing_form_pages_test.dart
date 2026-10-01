import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jxu_campus_hub/features/changxing_jiada/changxing_back_school_form_page.dart';
import 'package:jxu_campus_hub/features/changxing_jiada/changxing_jiada_model.dart';
import 'package:jxu_campus_hub/features/changxing_jiada/changxing_jiada_service.dart';
import 'package:jxu_campus_hub/features/changxing_jiada/changxing_leave_form_page.dart';
import 'package:jxu_campus_hub/features/changxing_jiada/changxing_overtime_form_page.dart';
import 'package:jxu_campus_hub/shared/widgets/app_feedback.dart';

/// 钉住三个畅行嘉大表单页的共有行为（加载失败回退、区域展示、附件上传、
/// 提交成功/失败反馈、校验文案），为抽取共享支撑代码兜底。

const _fullName = '浙江/杭州/西湖';

class _FakeService extends Fake implements ChangxingJiadaService {
  Future<ChangxingUserProfile> Function() profile = () async =>
      ChangxingUserProfile(
        name: '李明',
        jobNo: '20260001',
        phone: '13800000000',
        emergencyContact: '家长',
        emergencyPhone: '13900000000',
      );
  Future<ChangxingApplicationDetail> Function(int id) detail = (id) async =>
      throw StateError('detail 未配置');
  Future<List<ChangxingAreaNode>> Function(int areaId) parents =
      (areaId) async => const <ChangxingAreaNode>[
        // 服务端自下而上返回：区 → 市 → 省。
        ChangxingAreaNode(id: 330106, areaName: '西湖'),
        ChangxingAreaNode(id: 330100, areaName: '杭州'),
        ChangxingAreaNode(id: 330000, areaName: '浙江'),
      ];
  Future<ChangxingUploadResult> Function(String path, String name) upload = (
    path,
    name,
  ) async => const ChangxingUploadResult(md5: 'md5-uploaded', base64: '');
  Future<bool> Function() fanxiaoEnabled = () async => true;
  Future<void> Function() submitImpl = () async {};

  final List<String> calls = <String>[];
  final List<Map<String, Object?>> submitted = <Map<String, Object?>>[];

  @override
  Future<ChangxingUserProfile> fetchUserProfile() {
    calls.add('profile');
    return profile();
  }

  @override
  Future<ChangxingApplicationDetail> fetchApplicationDetail(int id) {
    calls.add('detail:$id');
    return detail(id);
  }

  @override
  Future<List<ChangxingAreaNode>> fetchAreaParents(int areaId) =>
      parents(areaId);

  @override
  Future<bool> fetchFanxiaoEnableFlag() => fanxiaoEnabled();

  @override
  Future<ChangxingUploadResult> uploadAttachment(
    String filePath,
    String fileName,
  ) {
    calls.add('upload:$fileName');
    return upload(filePath, fileName);
  }

  @override
  Future<void> submitLeaveRequest({
    int? id,
    required DateTime startTime,
    required DateTime endTime,
    required String descr,
    required int toAreaCode,
    required String toAddr,
    required String emergencyContact,
    required String emergencyPhone,
    required String userPhone,
    required List<String> trafficTools,
    String img = '',
    String annex = '',
  }) {
    submitted.add({
      'kind': 'leaveRequest',
      'id': id,
      'descr': descr,
      'toAreaCode': toAreaCode,
      'toAddr': toAddr,
      'traffic': trafficTools,
      'annex': annex,
    });
    return submitImpl();
  }

  @override
  Future<void> submitLeaveSchool({
    int? id,
    required DateTime startTime,
    required DateTime endTime,
    required String descr,
    required int toAreaCode,
    required String toAddr,
    required String emergencyContact,
    required String emergencyPhone,
    required String userPhone,
    required List<String> trafficTools,
  }) {
    submitted.add({'kind': 'leaveSchool', 'id': id, 'descr': descr});
    return submitImpl();
  }

  @override
  Future<void> submitBackSchool({
    int? id,
    required String userPhone,
    required DateTime startTime,
    required String trafficTool,
    required String trafficDetail,
    required String nativePlace,
    required int fromAreaCode,
    required String emergencyContact,
    required String emergencyPhone,
    required int backStatus,
    required String notBackReason,
    String img = '',
    String annex = '',
  }) {
    submitted.add({
      'kind': 'backSchool',
      'id': id,
      'fromAreaCode': fromAreaCode,
      'backStatus': backStatus,
      'annex': annex,
    });
    return submitImpl();
  }

  @override
  Future<void> submitOvertime({int? id, required String descr}) {
    submitted.add({'kind': 'overtime', 'id': id, 'descr': descr});
    return submitImpl();
  }
}

class _FakeFilePicker extends FilePicker {
  _FakeFilePicker(this.result);

  final FilePickerResult? result;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async => result;
}

ChangxingApplicationDetail _detail({
  int type = 1,
  String descr = '回家探亲',
  int toAreaCode = 330106,
  int fromAreaCode = 0,
  String annex = '',
  String nativePlace = '浙江杭州',
  int backStatus = 0,
  String notBackReason = '',
  String trafficTool = '火车',
}) => ChangxingApplicationDetail(
  id: 9,
  type: type,
  descr: descr,
  startTime: DateTime(2026, 9, 1, 8),
  endTime: DateTime(2026, 9, 2, 18),
  userPhone: '13800000000',
  emergencyContact: '家长',
  emergencyPhone: '13900000000',
  trafficTool: trafficTool,
  trafficDetail: 'G1234',
  toAreaCode: toAreaCode,
  toAddr: '西湖区某路 1 号',
  fromAreaCode: fromAreaCode,
  nativePlace: nativePlace,
  backStatus: backStatus,
  notBackReason: notBackReason,
  img: '',
  annex: annex,
);

ChangxingApplicationDetail _backDetail({
  int fromAreaCode = 330106,
  String notBackReason = '家中有事无法按时报到',
}) => _detail(
  type: 3,
  fromAreaCode: fromAreaCode,
  backStatus: 1,
  notBackReason: notBackReason,
);

/// 先落在 `/`，再 push 表单页，这样 `context.pop` 有地方可回。
/// 返回 push 的结果 future（页面 `pop(true)` 时完成）。
Future<Future<Object?>> _openForm(WidgetTester tester, Widget form) async {
  tester.view.physicalSize = const Size(900, 3200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => const Scaffold(body: Text('首页')),
      ),
      GoRoute(path: '/form', builder: (_, _) => form),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(MaterialApp.router(routerConfig: router));
  final result = router.push<Object?>('/form');
  await tester.pumpAndSettle();
  return result;
}

Future<void> _tapSubmit(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _tapAttachment(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

FilePickerResult _picked(String name) =>
    FilePickerResult([PlatformFile(name: name, size: 1, path: '/t/$name')]);

void main() {
  late _FakeService service;

  setUp(() {
    AppFeedback.resetDedupe();
    service = _FakeService();
  });

  group('加载失败', () {
    final forms = <String, Widget Function(_FakeService)>{
      '请假': (s) => ChangxingLeaveFormPage(
        formType: ChangxingFormType.leaveRequest,
        applicationId: 9,
        service: s,
      ),
      '返校': (s) => ChangxingBackSchoolFormPage(applicationId: 9, service: s),
      '超时': (s) => ChangxingOvertimeFormPage(applicationId: 9, service: s),
    };
    for (final entry in forms.entries) {
      testWidgets('${entry.key}：toast 加载表单失败并退回上一页', (tester) async {
        service.detail = (_) async => throw Exception('boom');
        final result = await _openForm(tester, entry.value(service));
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.text('加载表单失败：Exception: boom'), findsOneWidget);
        expect(find.text('首页'), findsOneWidget);
        expect(await result, isNull);
      });
    }
  });

  group('请假页', () {
    Widget leave({int? id, ChangxingFormType? type}) => ChangxingLeaveFormPage(
      formType: type ?? ChangxingFormType.leaveRequest,
      applicationId: id,
      service: service,
    );

    testWidgets('新建：用档案预填联系方式，目的地显示占位', (tester) async {
      await _openForm(tester, leave());

      expect(service.calls, ['profile']);
      expect(find.text('13800000000'), findsOneWidget);
      expect(find.text('家长'), findsOneWidget);
      expect(find.text('13900000000'), findsOneWidget);
      expect(find.text('请选择'), findsNWidgets(3)); // 开始 / 结束时间 + 目的地
      expect(find.text('未上传'), findsOneWidget);
      expect(find.text('提交'), findsOneWidget);
    });

    testWidgets('编辑：区域按省/市/区链展示，附件显示已上传摘要', (tester) async {
      service.detail = (_) async => _detail(annex: 'abcdefgh12345678');
      await _openForm(tester, leave(id: 9));

      expect(find.text(_fullName), findsOneWidget);
      expect(find.text('已上传附件（abcdefgh...）'), findsOneWidget);
      expect(find.text('确认修改'), findsOneWidget);
      expect(find.text('编辑请假申请'), findsOneWidget);
    });

    testWidgets('编辑：区域父链为空时目的地回到占位', (tester) async {
      service.detail = (_) async => _detail();
      service.parents = (_) async => const <ChangxingAreaNode>[];
      await _openForm(tester, leave(id: 9));

      expect(find.text('请选择'), findsOneWidget);
    });

    testWidgets('离校登记不展示附件行', (tester) async {
      await _openForm(tester, leave(type: ChangxingFormType.leaveSchool));
      expect(find.text('附件'), findsNothing);
    });

    testWidgets('未选时间：提示请选择开始和结束时间', (tester) async {
      await _openForm(tester, leave());
      await _tapSubmit(tester, '提交');
      expect(find.text('请选择开始和结束时间'), findsOneWidget);
      expect(service.submitted, isEmpty);
    });

    testWidgets('起止时间相同：提示结束时间需大于开始时间', (tester) async {
      await _openForm(tester, leave());
      for (final row in ['开始时间', '结束时间']) {
        await tester.tap(find.text(row));
        await tester.pumpAndSettle();
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
      }
      await _tapSubmit(tester, '提交');
      expect(find.text('结束时间需大于开始时间'), findsOneWidget);
      expect(service.submitted, isEmpty);
    });

    testWidgets('理由为空：按请假文案提示', (tester) async {
      service.detail = (_) async => _detail(descr: '');
      await _openForm(tester, leave(id: 9));
      await _tapSubmit(tester, '确认修改');
      expect(find.text('请假理由为空'), findsOneWidget);
      expect(service.submitted, isEmpty);
    });

    testWidgets('离校登记理由为空：按离校文案提示', (tester) async {
      service.detail = (_) async => _detail(descr: '', type: 2);
      await _openForm(
        tester,
        leave(id: 9, type: ChangxingFormType.leaveSchool),
      );
      await _tapSubmit(tester, '确认修改');
      expect(find.text('离校事由为空'), findsOneWidget);
    });

    testWidgets('未选交通方式：提示请选择出行交通方式', (tester) async {
      service.detail = (_) async => _detail(trafficTool: '');
      await _openForm(tester, leave(id: 9));
      await _tapSubmit(tester, '确认修改');
      expect(find.text('请选择出行交通方式'), findsOneWidget);
    });

    testWidgets('未选目的地：提示请选择目的地', (tester) async {
      service.detail = (_) async => _detail(toAreaCode: 0);
      await _openForm(tester, leave(id: 9));
      await _tapSubmit(tester, '确认修改');
      expect(find.text('请选择目的地'), findsOneWidget);
    });

    testWidgets('编辑提交成功：toast 修改成功并带 true 退出', (tester) async {
      service.detail = (_) async => _detail(annex: 'abcdefgh12345678');
      final result = await _openForm(tester, leave(id: 9));
      await _tapSubmit(tester, '确认修改');

      expect(find.text('修改成功'), findsOneWidget);
      expect(find.text('首页'), findsOneWidget);
      expect(await result, true);
      expect(service.submitted.single, {
        'kind': 'leaveRequest',
        'id': 9,
        'descr': '回家探亲',
        'toAreaCode': 330106,
        'toAddr': '西湖区某路 1 号',
        'traffic': ['火车'],
        'annex': 'abcdefgh12345678',
      });
    });

    testWidgets('提交失败：toast 修改失败，留在页面且按钮恢复', (tester) async {
      service.detail = (_) async => _detail();
      service.submitImpl = () async => throw Exception('服务器繁忙');
      await _openForm(tester, leave(id: 9));
      await _tapSubmit(tester, '确认修改');

      expect(find.text('修改失败：Exception: 服务器繁忙'), findsOneWidget);
      expect(find.text('编辑请假申请'), findsOneWidget);
      expect(find.text('确认修改'), findsOneWidget);
      expect(find.text('提交中...'), findsNothing);
    });

    testWidgets('附件上传成功：回填文件名、toast，并随提交带上 md5', (tester) async {
      FilePicker.platform = _FakeFilePicker(_picked('证明.pdf'));
      service.detail = (_) async => _detail();
      await _openForm(tester, leave(id: 9));

      await _tapAttachment(tester, '附件');

      expect(service.calls, contains('upload:证明.pdf'));
      expect(find.text('证明.pdf'), findsOneWidget);
      expect(find.text('附件上传成功'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      await tester.pump(const Duration(seconds: 5));
      await _tapSubmit(tester, '确认修改');
      expect(service.submitted.single['annex'], 'md5-uploaded');
    });

    testWidgets('附件上传失败：toast 附件上传失败，保持未上传', (tester) async {
      FilePicker.platform = _FakeFilePicker(_picked('证明.pdf'));
      service.detail = (_) async => _detail();
      service.upload = (_, _) async => throw Exception('网络断开');
      await _openForm(tester, leave(id: 9));

      await _tapAttachment(tester, '附件');

      expect(find.text('附件上传失败：Exception: 网络断开'), findsOneWidget);
      expect(find.text('未上传'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('取消选择文件：不上传、不提示、spinner 复位', (tester) async {
      FilePicker.platform = _FakeFilePicker(null);
      service.detail = (_) async => _detail();
      await _openForm(tester, leave(id: 9));

      await _tapAttachment(tester, '附件');

      expect(service.calls.where((c) => c.startsWith('upload')), isEmpty);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.text('未上传'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });

  group('返校页', () {
    Widget back({int? id}) =>
        ChangxingBackSchoolFormPage(applicationId: id, service: service);

    testWidgets('编辑：生源地按省/市/区链展示', (tester) async {
      service.detail = (_) async => _backDetail();
      await _openForm(tester, back(id: 9));
      expect(find.text(_fullName), findsOneWidget);
      expect(find.text('编辑返校登记'), findsOneWidget);
    });

    testWidgets('新建未选报到状态：提示请选择报到状态，生源地显示占位', (tester) async {
      await _openForm(tester, back());
      expect(find.text('请选择'), findsOneWidget);
      await _tapSubmit(tester, '提交');
      expect(find.text('请选择报到状态'), findsOneWidget);
    });

    testWidgets('未选生源地：提示请选择生源所在地', (tester) async {
      service.detail = (_) async => _backDetail(fromAreaCode: 0);
      await _openForm(tester, back(id: 9));
      await _tapSubmit(tester, '确认修改');
      expect(find.text('请选择生源所在地'), findsOneWidget);
    });

    testWidgets('暂缓报到原因过短：提示不少于10个字', (tester) async {
      service.detail = (_) async => _backDetail(notBackReason: '太短');
      await _openForm(tester, back(id: 9));
      await _tapSubmit(tester, '确认修改');
      expect(find.text('请填写无法报到原因，并不少于10个字'), findsOneWidget);
    });

    testWidgets('报到登记未开放：提示并不提交', (tester) async {
      service.detail = (_) async => _backDetail();
      service.fanxiaoEnabled = () async => false;
      await _openForm(tester, back(id: 9));
      await _tapSubmit(tester, '确认修改');

      expect(find.text('报到登记暂未开放，请联系管理员'), findsOneWidget);
      expect(service.submitted, isEmpty);
      expect(find.text('确认修改'), findsOneWidget);
      expect(find.text('提交中...'), findsNothing);
    });

    testWidgets('编辑提交成功：toast 修改成功并带 true 退出', (tester) async {
      service.detail = (_) async => _backDetail();
      final result = await _openForm(tester, back(id: 9));
      await _tapSubmit(tester, '确认修改');

      expect(find.text('修改成功'), findsOneWidget);
      expect(await result, true);
      expect(service.submitted.single, {
        'kind': 'backSchool',
        'id': 9,
        'fromAreaCode': 330106,
        'backStatus': 1,
        'annex': '',
      });
    });

    testWidgets('提交失败：toast 修改失败并保持在页面', (tester) async {
      service.detail = (_) async => _backDetail();
      service.submitImpl = () async => throw Exception('拒绝');
      await _openForm(tester, back(id: 9));
      await _tapSubmit(tester, '确认修改');

      expect(find.text('修改失败：Exception: 拒绝'), findsOneWidget);
      expect(find.text('编辑返校登记'), findsOneWidget);
      expect(find.text('提交中...'), findsNothing);
    });

    testWidgets('附件上传成功后再失败：失败提示，保留上一次文件', (tester) async {
      FilePicker.platform = _FakeFilePicker(_picked('材料.docx'));
      await _openForm(tester, back());

      await _tapAttachment(tester, '附件');
      expect(find.text('材料.docx'), findsOneWidget);
      expect(find.text('附件上传成功'), findsOneWidget);

      await tester.pump(const Duration(seconds: 5));
      service.upload = (_, _) async => throw Exception('超时');
      await _tapAttachment(tester, '材料.docx');
      expect(find.text('附件上传失败：Exception: 超时'), findsOneWidget);
      expect(find.text('材料.docx'), findsOneWidget);
    });
  });

  group('超时页', () {
    Widget overtime({int? id}) =>
        ChangxingOvertimeFormPage(applicationId: id, service: service);

    testWidgets('编辑：回填事由', (tester) async {
      service.detail = (_) async => _detail(type: 4, descr: '实验超时');
      await _openForm(tester, overtime(id: 9));
      expect(find.text('实验超时'), findsOneWidget);
      expect(find.text('编辑超时登记'), findsOneWidget);
    });

    testWidgets('事由为空：提示超时事由为空', (tester) async {
      await _openForm(tester, overtime());
      await _tapSubmit(tester, '提交');
      expect(find.text('超时事由为空'), findsOneWidget);
      expect(service.submitted, isEmpty);
    });

    testWidgets('事由过长：提示最多200字', (tester) async {
      service.detail = (_) async => _detail(type: 4, descr: '长' * 201);
      await _openForm(tester, overtime(id: 9));
      await _tapSubmit(tester, '确认修改');
      expect(find.text('超时理由过长，最多200字'), findsOneWidget);
    });

    testWidgets('新建提交成功：toast 提交成功并带 true 退出', (tester) async {
      final result = await _openForm(tester, overtime());
      await tester.enterText(find.byType(TextField), '实验超时');
      await _tapSubmit(tester, '提交');

      expect(find.text('提交成功'), findsOneWidget);
      expect(await result, true);
      expect(service.submitted.single, {
        'kind': 'overtime',
        'id': null,
        'descr': '实验超时',
      });
    });

    testWidgets('提交失败：toast 提交失败并保持在页面', (tester) async {
      service.submitImpl = () async => throw Exception('服务器繁忙');
      await _openForm(tester, overtime());
      await tester.enterText(find.byType(TextField), '实验超时');
      await _tapSubmit(tester, '提交');

      expect(find.text('提交失败：Exception: 服务器繁忙'), findsOneWidget);
      expect(find.text('超时登记'), findsOneWidget);
      expect(find.text('提交中...'), findsNothing);
    });
  });
}
