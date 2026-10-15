import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/ai_export/export_controller.dart';
import 'package:jxu_campus_hub/features/ai_export/export_model.dart';

import '../../helpers/ai_export_fixtures.dart';

/// 可变的假身份：改它并 `notifyListeners()` 即模拟登录 / 登出 / 换号。
class _FakeIdentity extends ChangeNotifier {
  _FakeIdentity({this.academic, this.unified});

  String? academic;
  String? unified;
  int academicRevision = 0;
  int unifiedRevision = 0;

  ExportIdentity read() => ExportIdentity(
    academic: academic,
    unified: unified,
    academicRevision: academicRevision,
    unifiedRevision: unifiedRevision,
  );

  void set({String? academic, String? unified, bool keep = false}) {
    if (!keep) {
      this.academic = academic;
      this.unified = unified;
    }
    notifyListeners();
  }

  /// 同账号重登：账号不变，会话修订号推进。
  void reLogin({bool academicDomain = true, bool unifiedDomain = false}) {
    if (academicDomain) academicRevision++;
    if (unifiedDomain) unifiedRevision++;
    notifyListeners();
  }
}

class _Fake {
  _Fake(this.module, {this.local});

  final ExportModule module;
  ExportModuleData? local;
  Future<ExportFetchOutcome> Function()? outcome;
  int fetches = 0;
  int reads = 0;
  bool? lastForce;

  ExportModuleSource source({bool withLocal = true}) => ExportModuleSource(
    module: module,
    readLocal: withLocal
        ? () async {
            reads++;
            return local;
          }
        : null,
    fetch: ({required force}) async {
      fetches++;
      lastForce = force;
      return outcome!();
    },
  );
}

ExamsModuleData _examsFrom(String source) => ExamsModuleData.fromEntries(
  const [],
  status: ExportModuleStatus.available,
  dataSource: source,
);

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  late _FakeIdentity identity;
  late _Fake grades;
  late _Fake exams;
  late _Fake notices;
  late _Fake classroom;
  late AiExportController controller;

  AiExportController build({ExportPreset preset = ExportPreset.all}) {
    controller = AiExportController(
      sources: [
        grades.source(),
        exams.source(),
        notices.source(),
        classroom.source(withLocal: false),
      ],
      identity: identity.read,
      identityChanges: identity,
      clock: () => kExportNow,
      environment: (_) => kExportEnvironment,
      initialPreset: preset,
    );
    addTearDown(controller.dispose);
    return controller;
  }

  setUp(() {
    identity = _FakeIdentity(academic: '20250001', unified: 'cas-account');
    grades = _Fake(ExportModule.grades, local: gradesData());
    exams = _Fake(ExportModule.exams);
    notices = _Fake(ExportModule.notices);
    classroom = _Fake(ExportModule.secondClassroom);
  });

  group('选择', () {
    test('预设决定初始模块；只列出有取数来源的模块', () {
      build(preset: ExportPreset.planning);
      expect(controller.selected, {ExportModule.grades});
      expect(controller.preset, isNull, reason: '进度模块无来源，集合已不等于预设');
      expect(controller.availableModules, [
        ExportModule.grades,
        ExportModule.exams,
        ExportModule.secondClassroom,
        ExportModule.notices,
      ]);
    });

    test('切换预设 / 微调模块；至少保留一个', () {
      build();
      controller.selectPreset(ExportPreset.upcoming);
      expect(controller.selected, {
        ExportModule.exams,
        ExportModule.secondClassroom,
        ExportModule.notices,
      });
      controller.toggleModule(ExportModule.grades);
      expect(controller.selected, contains(ExportModule.grades));
      for (final m in [...controller.selected]) {
        controller.toggleModule(m);
      }
      expect(controller.selected, hasLength(1), reason: '最后一个不能取消');
    });
  });

  group('读取与获取', () {
    test('initialize 读取本机已有数据；没有的保持未获取，单个失败不影响其它', () async {
      build();
      await controller.initialize();
      expect(controller.rowKindOf(ExportModule.grades), ExportRowKind.ready);
      expect(controller.rowKindOf(ExportModule.exams), ExportRowKind.missing);
      expect(grades.reads, 1);
      expect(exams.fetches, 0, reason: '打开页面不会自动联网');

      final doc = controller.buildDocument();
      final byModule = {for (final m in doc.modules) m.module: m.status};
      expect(byModule[ExportModule.grades], ExportModuleStatus.available);
      expect(byModule[ExportModule.exams], ExportModuleStatus.missing);
    });

    test('获取成功后进入文档；失败只影响本模块', () async {
      exams.outcome = () async => ExportFetched(examsData());
      notices.outcome = () async => const ExportFetchFailed('教务处通知获取失败');
      build();
      await controller.initialize();

      await controller.fetch(ExportModule.exams);
      await controller.fetch(ExportModule.notices);

      expect(controller.rowKindOf(ExportModule.exams), ExportRowKind.ready);
      expect(controller.rowKindOf(ExportModule.notices), ExportRowKind.failed);
      expect(controller.slotOf(ExportModule.notices).message, '教务处通知获取失败');
      // 成绩不受影响。
      expect(controller.rowKindOf(ExportModule.grades), ExportRowKind.ready);
      expect(controller.hasExportableData, isTrue);
    });

    test('过期数据的获取走强制刷新', () async {
      grades.local = gradesData(status: ExportModuleStatus.stale);
      grades.outcome = () async => ExportFetched(gradesData());
      build();
      await controller.initialize();
      await controller.fetch(ExportModule.grades);
      expect(grades.lastForce, isTrue);
    });

    test('获取中忙碌：重复点按不重复发请求', () async {
      final gate = Completer<ExportFetchOutcome>();
      exams.outcome = () => gate.future;
      build();
      await controller.initialize();
      final first = controller.fetch(ExportModule.exams);
      await _settle();
      expect(controller.rowKindOf(ExportModule.exams), ExportRowKind.loading);
      await controller.fetch(ExportModule.exams);
      expect(exams.fetches, 1);
      gate.complete(ExportFetched(examsData()));
      await first;
      expect(controller.rowKindOf(ExportModule.exams), ExportRowKind.ready);
    });

    test('服务抛出的意外异常被收敛为失败，不外泄', () async {
      exams.outcome = () async => throw StateError('boom');
      build();
      await controller.initialize();
      await controller.fetch(ExportModule.exams);
      expect(controller.rowKindOf(ExportModule.exams), ExportRowKind.failed);
      expect(controller.slotOf(ExportModule.exams).message, '获取失败，请稍后重试');
    });
  });

  group('需登录：导出页永不触发登录', () {
    test('教务域未登录：不发请求，直接「需登录」', () async {
      identity.set(academic: null, unified: 'cas-account');
      exams.outcome = () async => ExportFetched(examsData());
      build();
      await controller.initialize();
      await controller.fetch(ExportModule.exams);
      expect(exams.fetches, 0);
      expect(
        controller.rowKindOf(ExportModule.exams),
        ExportRowKind.needsLogin,
      );
      // 统一认证域仍登录着：不受影响。
      notices.outcome = () async => ExportFetched(noticesData());
      await controller.fetch(ExportModule.notices);
      expect(notices.fetches, 1);
    });

    test('服务返回会话失效：进入「需登录」并保留已有数据', () async {
      grades.local = gradesData(status: ExportModuleStatus.stale);
      grades.outcome = () async => const ExportNeedsLogin();
      build();
      await controller.initialize();
      await controller.fetch(ExportModule.grades);
      expect(
        controller.rowKindOf(ExportModule.grades),
        ExportRowKind.needsLogin,
      );
      expect(controller.slotOf(ExportModule.grades).data, isNotNull);
      expect(controller.hasExportableData, isTrue);
    });

    test('未登录时不读取私有缓存的结果被丢弃之外，读取器仍自行校验归属', () async {
      identity.set(academic: null, unified: null);
      grades.local = null; // 读取器在未登录时返回 null
      build();
      await controller.initialize();
      expect(
        controller.rowKindOf(ExportModule.grades),
        ExportRowKind.needsLogin,
      );
      expect(controller.hasExportableData, isFalse);
    });
  });

  group('账号切换 / 登出', () {
    test('登出：该域数据立即清空，另一域不受影响', () async {
      notices.local = noticesData();
      build();
      await controller.initialize();
      expect(controller.hasExportableData, isTrue);

      identity.set(academic: null, unified: 'cas-account');

      expect(controller.slotOf(ExportModule.grades).data, isNull);
      expect(controller.slotOf(ExportModule.notices).data, isNotNull);
      expect(controller.identityReset, isTrue);
      expect(
        controller.rowKindOf(ExportModule.grades),
        ExportRowKind.needsLogin,
      );
      final doc = controller.buildDocument();
      expect(
        doc.modules.firstWhere((m) => m.module == ExportModule.grades).status,
        ExportModuleStatus.missing,
      );
    });

    test('换号：先清空上一个账号的数据，再只读新账号自己的缓存', () async {
      build();
      await controller.initialize();
      expect(controller.slotOf(ExportModule.grades).data, isNotNull);

      grades.local = null; // 新账号没有缓存
      identity.set(academic: '20259999', unified: 'cas-account');
      expect(controller.slotOf(ExportModule.grades).data, isNull);
      await _settle();
      expect(controller.slotOf(ExportModule.grades).data, isNull);
      expect(controller.rowKindOf(ExportModule.grades), ExportRowKind.missing);
      expect(controller.identityReset, isTrue);

      controller.acknowledgeIdentityReset();
      expect(controller.identityReset, isFalse);
    });

    test('在途获取遇到换号：旧结果被丢弃，不写入新账号的槽位', () async {
      final gate = Completer<ExportFetchOutcome>();
      exams.outcome = () => gate.future;
      build();
      await controller.initialize();
      final pending = controller.fetch(ExportModule.exams);
      await _settle();

      identity.set(academic: '20259999', unified: 'cas-account');
      gate.complete(ExportFetched(examsData()));
      await pending;

      expect(controller.slotOf(ExportModule.exams).data, isNull);
      expect(controller.rowKindOf(ExportModule.exams), ExportRowKind.missing);
    });

    test('同账号重登（会话修订号推进）：槽位清空并只重读本机缓存，不弹换号提示', () async {
      build();
      await controller.initialize();
      expect(controller.slotOf(ExportModule.grades).data, isNotNull);

      identity.reLogin();
      expect(controller.slotOf(ExportModule.grades).data, isNull);
      expect(controller.identityReset, isFalse, reason: '账号没变，不提示「账号已变化」');
      await _settle();
      expect(grades.reads, 2, reason: '重登后重读自带归属校验的本地缓存');
      expect(controller.slotOf(ExportModule.grades).data, isNotNull);
    });

    test('同账号重登只影响对应登录域', () async {
      notices.local = noticesData();
      build();
      await controller.initialize();

      identity.reLogin(); // 仅教务域
      expect(controller.slotOf(ExportModule.notices).data, isNotNull);

      identity.reLogin(academicDomain: false, unifiedDomain: true);
      expect(controller.slotOf(ExportModule.notices).data, isNull);
    });

    test('在途获取遇到同账号重登：迟到的旧结果被丢弃，用新会话重取一次', () async {
      var call = 0;
      final first = Completer<ExportFetchOutcome>();
      exams.outcome = () {
        call++;
        if (call == 1) return first.future;
        return Future.value(ExportFetched(_examsFrom('NEW')));
      };
      build();
      await controller.initialize();
      final pending = controller.fetch(ExportModule.exams);
      await _settle();

      identity.reLogin();
      // 旧会话的结果迟到：必须被丢弃，而不是落进槽位。
      first.complete(ExportFetched(_examsFrom('OLD')));
      await pending;

      expect(exams.fetches, 2, reason: '丢弃后用新会话重取一次');
      expect(
        controller.slotOf(ExportModule.exams).data?.dataSource,
        'NEW',
        reason: '槽位里是新会话的结果，不是迟到的旧结果',
      );
    });

    test('在途获取遇到同账号重登：重取最多一次，仍被打断则放弃', () async {
      final gates = [
        Completer<ExportFetchOutcome>(),
        Completer<ExportFetchOutcome>(),
      ];
      var call = 0;
      exams.outcome = () => gates[call++].future;
      build();
      await controller.initialize();
      final pending = controller.fetch(ExportModule.exams);
      await _settle();
      identity.reLogin();
      gates[0].complete(ExportFetched(examsData()));
      await _settle();
      identity.reLogin();
      gates[1].complete(ExportFetched(examsData()));
      await pending;

      expect(exams.fetches, 2);
      expect(controller.slotOf(ExportModule.exams).data, isNull);
    });

    test('第二课堂（无账号标识）：任一登录域变化都会清空', () async {
      classroom.outcome = () async => ExportFetched(secondClassroomData());
      build();
      await controller.initialize();
      await controller.fetch(ExportModule.secondClassroom);
      expect(controller.slotOf(ExportModule.secondClassroom).data, isNotNull);

      identity.set(academic: '20250001', unified: 'another-cas');
      expect(controller.slotOf(ExportModule.secondClassroom).data, isNull);
    });

    test('身份未变化的通知不会清数据', () async {
      build();
      await controller.initialize();
      identity.set(keep: true);
      expect(controller.slotOf(ExportModule.grades).data, isNotNull);
      expect(controller.identityReset, isFalse);
    });
  });

  group('文档', () {
    test('按固定顺序输出所选模块，未取到的以占位标注', () async {
      build();
      await controller.initialize();
      controller.selectPreset(ExportPreset.all);
      final doc = controller.buildDocument();
      expect(doc.exportedAt, kExportNow);
      expect(doc.environment, same(kExportEnvironment));
      expect(doc.modules.map((m) => m.module).toList(), [
        ExportModule.grades,
        ExportModule.exams,
        ExportModule.secondClassroom,
        ExportModule.notices,
      ]);
    });
  });
}
