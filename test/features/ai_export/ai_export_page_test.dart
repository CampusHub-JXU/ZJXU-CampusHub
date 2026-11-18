import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/auth/unified_auth.dart';
import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/features/ai_export/ai_export_page.dart';
import 'package:jxu_campus_hub/features/ai_export/export_controller.dart';
import 'package:jxu_campus_hub/features/ai_export/export_model.dart';
import 'package:jxu_campus_hub/features/ai_export/export_output.dart';

import '../../helpers/ai_export_fixtures.dart';
import '../../helpers/test_setup.dart';

class _FakeIdentity extends ChangeNotifier {
  _FakeIdentity({this.academic, this.unified});

  String? academic;
  String? unified;

  ExportIdentity read() => ExportIdentity(academic: academic, unified: unified);

  void change({String? academic, String? unified}) {
    this.academic = academic;
    this.unified = unified;
    notifyListeners();
  }
}

class _Fake {
  _Fake(this.module, {this.local});

  final ExportModule module;
  ExportModuleData? local;
  Future<ExportFetchOutcome> Function()? outcome;
  int fetches = 0;

  ExportModuleSource source() => ExportModuleSource(
    module: module,
    readLocal: () async => local,
    fetch: ({required force}) async {
      fetches++;
      return outcome!();
    },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeIdentity identity;
  late Map<ExportModule, _Fake> fakes;

  setUp(() async {
    await resetTestEnvironment();
    identity = _FakeIdentity(academic: '20250001', unified: 'cas-account');
    fakes = {
      ExportModule.progress: _Fake(
        ExportModule.progress,
        local: progressData(),
      ),
      ExportModule.grades: _Fake(ExportModule.grades, local: gradesData()),
      for (final m in [
        ExportModule.schedule,
        ExportModule.exams,
        ExportModule.secondClassroom,
        ExportModule.notices,
        ExportModule.physicalTest,
      ])
        m: _Fake(m),
    };
  });

  tearDown(() {
    exportSharer = defaultExportSharer;
    exportFileSaver = defaultExportFileSaver;
  });

  AiExportController newController() {
    final controller = AiExportController(
      sources: [for (final f in fakes.values) f.source()],
      identity: identity.read,
      identityChanges: identity,
      clock: () => kExportNow,
      environment: (_) => kExportEnvironment,
    );
    addTearDown(controller.dispose);
    return controller;
  }

  Future<void> pumpPage(
    WidgetTester tester, {
    AiExportController? controller,
    ExportLoginHandler? loginHandler,
  }) async {
    tester.view.physicalSize = const Size(900, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: AiExportPage(
          controller: controller ?? newController(),
          loginHandler: loginHandler,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Finder preset(String label) => find.descendant(
    of: find.byKey(const Key('ai_export_presets')),
    matching: find.text(label),
  );

  // 预览是真·Markdown 渲染（flutter_markdown_plus）。注意包用的是
  // package:flutter/material.dart 的 SelectableText，而本页 import 的
  // package:material_ui 是同名不同类——不能 `is SelectableText` 断言。
  // 它的每个文本块内部是 EditableText（controller 即纯文本），
  // 列表符号 / 表格单元格等不可选块则是 Text / RichText，按树序收集。
  String previewText(WidgetTester tester) {
    final widgets = tester.widgetList(
      find.descendant(
        of: find.byKey(const Key('ai_export_preview')),
        matching: find.byWidgetPredicate(
          (w) => w is EditableText || w is Text || w is RichText,
        ),
      ),
    );
    return [
      for (final w in widgets)
        switch (w) {
          EditableText e => e.controller.text,
          Text t => t.data ?? t.textSpan?.toPlainText() ?? '',
          RichText r => r.text.toPlainText(),
          _ => '',
        },
    ].join('\n');
  }

  String status(WidgetTester tester, ExportModule m) =>
      tester.widget<Text>(find.byKey(Key('ai_export_status_${m.key}'))).data!;

  Finder checkbox(ExportModule m) =>
      find.byKey(Key('ai_export_check_${m.key}'));

  bool isChecked(WidgetTester tester, ExportModule m) =>
      tester.widget<Checkbox>(checkbox(m)).value!;

  Future<void> setChecked(
    WidgetTester tester,
    ExportModule m, {
    required bool to,
  }) async {
    if (isChecked(tester, m) == to) return;
    await tester.tap(checkbox(m));
    await tester.pump();
  }

  Finder action(ExportModule m) => find.byKey(Key('ai_export_action_${m.key}'));

  bool actionEnabled(WidgetTester tester, String label) {
    final button = find.ancestor(
      of: find.text(label),
      matching: find.bySubtype<ButtonStyleButton>(),
    );
    return tester.widget<ButtonStyleButton>(button).onPressed != null;
  }

  List<MethodCall> mockClipboard(WidgetTester tester) {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    return calls;
  }

  group('勾选清单', () {
    testWidgets('默认全勾：所有模块行都有勾选框，预览渲染成富文本', (tester) async {
      await pumpPage(tester);

      expect(find.text('导出给 AI'), findsOneWidget);
      for (final m in ExportModule.values) {
        expect(
          find.byKey(Key('ai_export_row_${m.key}')),
          findsOneWidget,
          reason: m.key,
        );
        expect(isChecked(tester, m), isTrue, reason: '${m.key} 默认勾选');
      }
      expect(status(tester, ExportModule.grades), '已获取 · 5 条');

      // 渲染态不再出现 Markdown 标记，标题段落以样式呈现。
      final md = previewText(tester);
      expect(md, isNot(contains('## ')));
      expect(md, contains('学业数据导出'));
      expect(md, contains('给 AI 的背景说明'));
      expect(md, contains('高等数学A'));
      expect(actionEnabled(tester, '复制'), isTrue);
    });

    testWidgets('预览卡右上角放大按钮打开全屏只读预览并可返回', (tester) async {
      await pumpPage(tester);

      await tester.scrollUntilVisible(
        find.byKey(const Key('ai_export_preview_expand')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const Key('ai_export_preview_expand')));
      await tester.pump();
      await tester.pump();

      expect(
        find.byKey(const Key('ai_export_preview_fullscreen')),
        findsOneWidget,
      );
      expect(find.text('学业数据导出'), findsWidgets);
      expect(find.text('高等数学A'), findsWidgets);

      await tester.pageBack();
      await tester.pump();
      await tester.pump();
      expect(
        find.byKey(const Key('ai_export_preview_fullscreen')),
        findsNothing,
      );
    });

    testWidgets('取消勾选即从导出剔除，预览实时联动', (tester) async {
      await pumpPage(tester);
      await tester.tap(preset('近期安排'));
      await tester.pump();

      for (final m in ExportPreset.upcoming.modules) {
        expect(isChecked(tester, m), isTrue, reason: m.key);
      }
      expect(isChecked(tester, ExportModule.grades), isFalse);
      expect(isChecked(tester, ExportModule.physicalTest), isFalse);

      // 取消勾选的模块不再写进导出文档。
      fakes[ExportModule.exams]!.outcome = () async =>
          ExportFetched(examsData());
      await setChecked(tester, ExportModule.exams, to: true);
      await tester.tap(action(ExportModule.exams));
      await tester.pump();
      await tester.pump();
      expect(previewText(tester), contains('线性代数'));

      await setChecked(tester, ExportModule.exams, to: false);
      expect(previewText(tester), isNot(contains('线性代数')));
    });

    testWidgets('取消勾选某模块后预设变为自定义；至少保留一项', (tester) async {
      await pumpPage(tester);
      await setChecked(tester, ExportModule.grades, to: false);

      final segmented = tester.widget<SegmentedButton<ExportPreset>>(
        find.byKey(const Key('ai_export_presets')),
      );
      expect(segmented.selected, isEmpty, reason: '手动微调后不再属于任何预设');

      // 取消到只剩一项后，最后一项的勾选框禁用、行不可点。
      for (final m in ExportModule.values) {
        if (m == ExportModule.progress) continue;
        await setChecked(tester, m, to: false);
      }
      expect(isChecked(tester, ExportModule.progress), isTrue);
      expect(
        tester.widget<Checkbox>(checkbox(ExportModule.progress)).onChanged,
        isNull,
        reason: '最后一个不能取消',
      );
      await tester.tap(find.byKey(const Key('ai_export_row_progress')));
      await tester.pump();
      expect(isChecked(tester, ExportModule.progress), isTrue);
    });
  });

  testWidgets('360x640 + 1.5 倍字号下无溢出（全部勾选 + 预览）', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
          child: AiExportPage(controller: newController()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.scrollUntilVisible(
      find.byKey(const Key('ai_export_preview')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  group('按需获取', () {
    testWidgets('未获取的模块显示「获取」，点按调用注入的获取器', (tester) async {
      fakes[ExportModule.exams]!.outcome = () async =>
          ExportFetched(examsData());
      await pumpPage(tester);
      await tester.tap(preset('近期安排'));
      await tester.pump();

      expect(status(tester, ExportModule.exams), '未获取');
      expect(action(ExportModule.exams), findsOneWidget);
      expect(
        find.descendant(
          of: action(ExportModule.exams),
          matching: find.text('获取'),
        ),
        findsOneWidget,
      );
      expect(previewText(tester), contains('未获取：本机暂无该模块数据'));

      await tester.tap(action(ExportModule.exams));
      await tester.pump();
      await tester.pump();

      expect(fakes[ExportModule.exams]!.fetches, 1);
      expect(status(tester, ExportModule.exams), '已获取 · 1 条');
      expect(action(ExportModule.exams), findsNothing);
      expect(previewText(tester), contains('线性代数'));
    });

    testWidgets('部分结果：显示「可能不全」并保留「重新获取」，预览写明原因', (tester) async {
      fakes[ExportModule.notices]!.outcome = () async => ExportFetched(
        NoticesModuleData.fromNotices(
          const [],
          exportedAt: kExportNow,
          status: ExportModuleStatus.available,
          lastUpdatedAt: kExportNow,
          dataSource: '刚获取',
          partialNote: '第 2 页获取失败，仅含前 1 页',
        ),
      );
      await pumpPage(tester);
      await tester.tap(preset('近期安排'));
      await tester.pump();
      await tester.tap(action(ExportModule.notices));
      await tester.pump();
      await tester.pump();

      expect(status(tester, ExportModule.notices), '已获取 · 0 条 · 可能不全');
      expect(
        find.descendant(
          of: action(ExportModule.notices),
          matching: find.text('重新获取'),
        ),
        findsOneWidget,
      );
      expect(previewText(tester), contains('部分结果：第 2 页获取失败'));
      expect(previewText(tester), contains('不能据此判断没有通知'));
    });

    testWidgets('获取失败只影响本模块，其它模块数据保留，可重试', (tester) async {
      fakes[ExportModule.exams]!.outcome = () async =>
          const ExportFetchFailed('考试获取失败');
      await pumpPage(tester);
      await tester.tap(preset('全部'));
      await tester.pump();

      await tester.tap(action(ExportModule.exams));
      await tester.pump();
      await tester.pump();

      expect(status(tester, ExportModule.exams), '考试获取失败');
      expect(status(tester, ExportModule.grades), '已获取 · 5 条');
      expect(
        find.descendant(
          of: action(ExportModule.exams),
          matching: find.text('重试'),
        ),
        findsOneWidget,
      );
      expect(previewText(tester), contains('高等数学A'));
    });

    testWidgets('获取中显示进度，不可重复点按', (tester) async {
      fakes[ExportModule.exams]!.outcome = () => Future.delayed(
        const Duration(seconds: 1),
        () => ExportFetched(examsData()),
      );
      await pumpPage(tester);
      await tester.tap(preset('近期安排'));
      await tester.pump();

      await tester.tap(action(ExportModule.exams));
      await tester.pump();
      expect(status(tester, ExportModule.exams), '获取中…');
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(action(ExportModule.exams), findsNothing);

      await tester.pump(const Duration(seconds: 2));
      expect(status(tester, ExportModule.exams), '已获取 · 1 条');
    });
  });

  group('需登录', () {
    testWidgets('教务未登录：不发请求，显示「需登录」；去登录走注入的登录入口', (tester) async {
      identity.change(academic: null, unified: 'cas-account');
      fakes[ExportModule.grades]!.local = null;
      fakes[ExportModule.progress]!.local = null;
      fakes[ExportModule.grades]!.outcome = () async =>
          ExportFetched(gradesData());
      ExportAuthDomain? asked;
      await pumpPage(
        tester,
        loginHandler: (context, domain) async {
          asked = domain;
          // 模拟登录成功：身份恢复。
          identity.change(academic: '20250001', unified: 'cas-account');
          return true;
        },
      );

      expect(status(tester, ExportModule.grades), '需登录');
      expect(status(tester, ExportModule.progress), '需登录');
      expect(fakes[ExportModule.grades]!.fetches, 0);
      expect(
        find.descendant(
          of: action(ExportModule.grades),
          matching: find.text('去登录'),
        ),
        findsOneWidget,
      );
      expect(actionEnabled(tester, '复制'), isFalse);

      await tester.tap(action(ExportModule.grades));
      await tester.pump();
      await tester.pump();

      expect(asked, ExportAuthDomain.academic);
      // 用户亲自登录成功后才获取，且只获取触发登录的这个模块。
      expect(fakes[ExportModule.grades]!.fetches, 1);
      expect(fakes[ExportModule.progress]!.fetches, 0);
      expect(status(tester, ExportModule.grades), '已获取 · 5 条');
    });

    testWidgets('获取时服务返回会话失效：显示「需登录」，不自动重试', (tester) async {
      fakes[ExportModule.exams]!.outcome = () async => const ExportNeedsLogin();
      await pumpPage(tester);
      await tester.tap(preset('近期安排'));
      await tester.pump();

      await tester.tap(action(ExportModule.exams));
      await tester.pump();
      await tester.pump();

      expect(status(tester, ExportModule.exams), '需登录');
      expect(fakes[ExportModule.exams]!.fetches, 1);
    });
  });

  group('复制 / 保存 / 分享', () {
    testWidgets('复制把预览内容（含背景说明）写入剪贴板', (tester) async {
      final clip = mockClipboard(tester);
      await pumpPage(tester);

      await tester.tap(find.text('复制'));
      await tester.pump();

      final copied = clip.where((c) => c.method == 'Clipboard.setData').single;
      final text = (copied.arguments as Map)['text'] as String;
      expect(text, contains('## 给 AI 的背景说明'));
      expect(text, contains('高等数学A'));
      expect(text, isNot(contains('20250001')));
      expect(find.text('已复制Markdown'), findsOneWidget);
    });

    testWidgets('页面没有格式选择与 CSV 模块选择，预览就是 Markdown', (tester) async {
      await pumpPage(tester);
      expect(find.byKey(const Key('ai_export_format')), findsNothing);
      expect(find.byKey(const Key('ai_export_csv_module')), findsNothing);
      expect(find.text('JSON'), findsNothing);
      expect(find.text('CSV'), findsNothing);
      expect(previewText(tester), startsWith('学业数据导出'));
    });

    testWidgets('保存调用文件保存器；用户取消不提示成功', (tester) async {
      String? savedName;
      exportFileSaver = (name, extension, bytes) async {
        savedName = name;
        return '/tmp/$name';
      };
      await pumpPage(tester);
      await tester.tap(find.text('保存'));
      await tester.pump();
      expect(savedName, startsWith('学业数据导出_'));
      expect(savedName, endsWith('.md'));
      expect(find.textContaining('已保存到 /tmp/'), findsOneWidget);

      exportFileSaver = (name, extension, bytes) async => null;
      ScaffoldMessenger.of(tester.element(find.byType(Scaffold)))
          .clearSnackBars();
      await tester.pump();
      await tester.tap(find.text('保存'));
      await tester.pump();
      expect(find.textContaining('已保存'), findsNothing);
    });

    testWidgets('系统分享：选择目标应用才提示已交出；取消不算成功', (tester) async {
      ExportSharePayload? payload;
      var outcome = ExportShareOutcome.dismissed;
      exportSharer = (p) async {
        payload = p;
        return outcome;
      };
      await pumpPage(tester);

      await tester.tap(find.text('分享'));
      await tester.pump();
      expect(payload!.mimeType, 'text/markdown');
      expect(payload!.fileName, endsWith('.md'));
      expect(payload!.text, contains('## 给 AI 的背景说明'));
      expect(find.textContaining('已交给所选应用'), findsNothing);

      outcome = ExportShareOutcome.shared;
      await tester.tap(find.text('分享'));
      await tester.pump();
      expect(find.textContaining('已交给所选应用'), findsOneWidget);
    });

    testWidgets('分享失败给出可理解提示', (tester) async {
      await pumpPage(tester);

      exportSharer = (p) async => throw PlatformException(code: 'x');
      await tester.tap(find.text('分享'));
      await tester.pump();
      expect(find.textContaining('无法打开系统分享'), findsOneWidget);
    });

    testWidgets('没有任何数据时禁用复制 / 保存 / 分享', (tester) async {
      fakes[ExportModule.grades]!.local = null;
      fakes[ExportModule.progress]!.local = null;
      await pumpPage(tester);
      expect(actionEnabled(tester, '复制'), isFalse);
      expect(actionEnabled(tester, '保存'), isFalse);
      expect(actionEnabled(tester, '分享'), isFalse);
    });
  });

  group('账号切换（真实教务身份）', () {
    testWidgets('换号 / 登出后清除上一账号的数据并提示，操作随之禁用', (tester) async {
      ZhengfangAuth.instance.debugSetSession(
        active: true,
        studentId: '20250001',
      );
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: 'cas-1',
      );
      final sources = [
        for (final m in [ExportModule.grades, ExportModule.progress])
          ExportModuleSource(
            module: m,
            // 读取器自带归属校验：只有 20250001 才读得到。
            readLocal: () async =>
                ZhengfangAuth.instance.verifiedStudentId == '20250001'
                ? (m == ExportModule.grades ? gradesData() : progressData())
                : null,
            fetch: ({required force}) async => const ExportNeedsLogin(),
          ),
      ];
      tester.view.physicalSize = const Size(900, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(home: AiExportPage(sources: sources)),
      );
      await tester.pump();
      await tester.pump();

      expect(previewText(tester), contains('高等数学A'));
      expect(actionEnabled(tester, '复制'), isTrue);

      ZhengfangAuth.instance.debugSetSession(
        active: true,
        studentId: '20259999',
      );
      await ZhengfangAuth.instance.markLoggedIn();
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('账号已变化或已登出'), findsOneWidget);
      expect(previewText(tester), isNot(contains('高等数学A')));
      expect(actionEnabled(tester, '复制'), isFalse);

      await tester.tap(find.text('知道了'));
      await tester.pump();
      expect(find.textContaining('账号已变化或已登出'), findsNothing);

      await ZhengfangAuth.instance.markLoggedOut();
      await tester.pump();
      expect(status(tester, ExportModule.grades), '需登录');
    });

    testWidgets('同账号重登（会话修订号推进）：清空旧会话数据后重读本机缓存', (tester) async {
      ZhengfangAuth.instance.debugSetSession(
        active: true,
        studentId: '20250001',
      );
      UnifiedAuthService.instance.debugSetSession(
        active: true,
        account: 'cas-1',
      );
      var reads = 0;
      final sources = [
        ExportModuleSource(
          module: ExportModule.grades,
          readLocal: () async {
            reads++;
            return gradesData();
          },
          fetch: ({required force}) async => const ExportNeedsLogin(),
        ),
      ];
      tester.view.physicalSize = const Size(900, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(home: AiExportPage(sources: sources)),
      );
      await tester.pump();
      await tester.pump();
      expect(reads, 1);

      final before = ZhengfangAuth.instance.sessionRevision;
      ZhengfangAuth.instance.debugSetSession(
        active: true,
        studentId: '20250001',
        forceRevision: true,
      );
      expect(ZhengfangAuth.instance.sessionRevision, before + 1);
      await ZhengfangAuth.instance.markLoggedIn();
      await tester.pump();
      await tester.pump();

      expect(reads, 2, reason: '同账号重登也会作废旧槽位并重读');
      expect(
        find.textContaining('账号已变化或已登出'),
        findsNothing,
        reason: '账号没变，不提示换号',
      );
      expect(previewText(tester), contains('高等数学A'));
    });
  });
}
