import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/features/grades/export/academic_export_builder.dart';
import 'package:jxu_campus_hub/features/grades/export/academic_export_capture.dart';
import 'package:jxu_campus_hub/features/grades/export/academic_export_sheet.dart';

import '../../helpers/academic_export_fixtures.dart';
import '../../helpers/test_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await resetTestEnvironment();
    ZhengfangAuth.instance.debugSetSession(active: true, studentId: '20250001');
  });

  tearDown(() {
    academicExportSharer = defaultAcademicExportSharer;
    academicExportFileSaver = defaultAcademicExportFileSaver;
  });

  AcademicExportSnapshot snapshot({AcademicExportInput? input}) {
    final auth = ZhengfangAuth.instance;
    return AcademicExportSnapshot(
      owner: auth.verifiedStudentId!,
      revision: auth.sessionRevision,
      input: input ?? fullExportInput(),
    );
  }

  Future<void> pumpSheet(WidgetTester tester, AcademicExportSnapshot s) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AcademicExportSheet(snapshot: s)),
      ),
    );
    await tester.pump();
  }

  Finder moduleChip(String label) => find.descendant(
    of: find.byKey(const Key('academic_export_modules')),
    matching: find.text(label),
  );

  String previewText(WidgetTester tester) =>
      tester.widget<SelectableText>(find.byType(SelectableText)).data!;

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

  AcademicExportInput gradesOnlyInput() => AcademicExportInput(
    exportedAt: DateTime(2026, 10, 13, 10, 30),
    allGrades: [gradeEntry()],
  );

  testWidgets('默认勾选本机已有数据的全部模块，预览为 Markdown', (tester) async {
    await pumpSheet(tester, snapshot());

    expect(find.text('导出学业数据'), findsOneWidget);
    expect(find.textContaining('仅导出本机已加载的数据'), findsOneWidget);
    final md = previewText(tester);
    expect(md, contains('# 学业数据导出'));
    expect(md, contains('## 成绩'));
    expect(md, contains('## 考试安排'));
    expect(md, contains('## 学业进度'));
    expect(actionEnabled(tester, '复制'), isTrue);
  });

  testWidgets('取消勾选模块后预览与复制内容都不含该模块', (tester) async {
    final clip = mockClipboard(tester);
    await pumpSheet(tester, snapshot());

    await tester.tap(moduleChip('成绩'));
    await tester.pump();
    await tester.tap(moduleChip('学业进度'));
    await tester.pump();

    final md = previewText(tester);
    expect(md, contains('## 考试安排'));
    expect(md, isNot(contains('## 成绩')));
    expect(md, isNot(contains('## 学业进度')));
    expect(md, isNot(contains('高等数学A')));

    await tester.tap(find.text('复制'));
    await tester.pump();
    final copied = clip.where((c) => c.method == 'Clipboard.setData').single;
    final text = (copied.arguments as Map)['text'] as String;
    expect(text, contains('线性代数'));
    expect(text, isNot(contains('高等数学A')));
    expect(text, isNot(contains('数据结构')));
    expect(find.text('已复制Markdown'), findsOneWidget);
  });

  testWidgets('至少保留一个模块：不能取消最后一个', (tester) async {
    await pumpSheet(tester, snapshot(input: gradesOnlyInput()));
    // 只有成绩有数据，默认仅勾选成绩；再点一次不应清空选择。
    await tester.tap(moduleChip('成绩'));
    await tester.pump();
    expect(previewText(tester), contains('## 成绩'));
  });

  testWidgets('未获取的模块被明确标注，且不阻止导出可用模块', (tester) async {
    await pumpSheet(tester, snapshot(input: gradesOnlyInput()));
    await tester.tap(moduleChip('考试安排'));
    await tester.pump();

    expect(find.textContaining('未获取（本机暂无数据'), findsOneWidget);
    final md = previewText(tester);
    expect(md, contains('| 考试安排 | 未获取 |'));
    expect(md, contains('未获取：本机暂无该模块已加载的数据'));
    expect(actionEnabled(tester, '复制'), isTrue);
  });

  testWidgets('没有任何可用数据时禁用复制 / 保存 / 分享', (tester) async {
    await pumpSheet(
      tester,
      snapshot(
        input: AcademicExportInput(exportedAt: DateTime(2026, 10, 13, 10, 30)),
      ),
    );
    expect(actionEnabled(tester, '复制'), isFalse);
    expect(actionEnabled(tester, '保存'), isFalse);
    expect(actionEnabled(tester, '分享'), isFalse);
  });

  testWidgets('CSV 每次只导出一个模块；JSON 带 schemaVersion', (tester) async {
    await pumpSheet(tester, snapshot());

    await tester.tap(find.text('CSV'));
    await tester.pump();
    final csv = previewText(tester);
    expect(csv.startsWith('\uFEFF'), isTrue);
    expect(csv, contains('课程,成绩,百分制'));
    expect(csv, isNot(contains('线性代数')));
    expect(find.textContaining('CSV 每次导出一个模块'), findsOneWidget);

    await tester.tap(find.text('JSON'));
    await tester.pump();
    expect(
      previewText(tester),
      contains('"schemaVersion": $kAcademicExportSchemaVersion'),
    );
  });

  testWidgets('选择学期范围只影响成绩模块', (tester) async {
    await pumpSheet(tester, snapshot());
    expect(previewText(tester), isNot(contains('大学英语')));

    await tester.tap(find.text('成绩：全部学期'));
    await tester.pump();
    expect(previewText(tester), contains('大学英语'));
  });

  testWidgets('保存调用文件保存器并提示成功路径', (tester) async {
    String? savedName;
    String? savedContent;
    academicExportFileSaver = (name, extension, bytes) async {
      savedName = name;
      savedContent = utf8.decode(bytes);
      return '/tmp/$name';
    };

    await pumpSheet(tester, snapshot());
    await tester.tap(find.text('保存'));
    await tester.pump();
    expect(savedName, endsWith('.md'));
    expect(savedContent, contains('# 学业数据导出'));
    expect(find.textContaining('已保存到 /tmp/'), findsOneWidget);
  });

  testWidgets('用户取消保存不显示成功提示', (tester) async {
    academicExportFileSaver = (name, extension, bytes) async => null;
    await pumpSheet(tester, snapshot());
    await tester.tap(find.text('保存'));
    await tester.pump();
    expect(find.textContaining('已保存'), findsNothing);
  });

  testWidgets('系统分享：选择目标应用才提示已交出；取消不算成功', (tester) async {
    AcademicSharePayload? payload;
    var outcome = AcademicShareOutcome.dismissed;
    academicExportSharer = (p) async {
      payload = p;
      return outcome;
    };

    await pumpSheet(tester, snapshot());
    await tester.tap(find.text('分享'));
    await tester.pump();
    expect(payload, isNotNull);
    expect(payload!.asText, isTrue);
    expect(payload!.text, contains('# 学业数据导出'));
    expect(find.textContaining('已交给所选应用'), findsNothing);

    outcome = AcademicShareOutcome.shared;
    await tester.tap(find.text('分享'));
    await tester.pump();
    expect(find.textContaining('已交给所选应用'), findsOneWidget);
  });

  testWidgets('分享 JSON 时以文件载荷交给系统', (tester) async {
    AcademicSharePayload? payload;
    academicExportSharer = (p) async {
      payload = p;
      return AcademicShareOutcome.dismissed;
    };
    await pumpSheet(tester, snapshot());
    await tester.tap(find.text('JSON'));
    await tester.pump();
    await tester.tap(find.text('分享'));
    await tester.pump();
    expect(payload!.asText, isFalse);
    expect(payload!.mimeType, 'application/json');
    expect(payload!.fileName, endsWith('.json'));
  });

  testWidgets('分享失败给出可理解的提示而不抛出', (tester) async {
    academicExportSharer = (p) async => throw PlatformException(code: 'x');
    await pumpSheet(tester, snapshot());
    await tester.tap(find.text('分享'));
    await tester.pump();
    expect(find.textContaining('无法打开系统分享'), findsOneWidget);
  });

  testWidgets('登出后弹层立即失效：隐藏预览、禁用全部操作', (tester) async {
    await pumpSheet(tester, snapshot());
    expect(actionEnabled(tester, '复制'), isTrue);

    await ZhengfangAuth.instance.markLoggedOut();
    await tester.pump();

    expect(find.textContaining('当前账号已变化或已登出'), findsOneWidget);
    expect(find.byType(SelectableText), findsNothing);
    expect(actionEnabled(tester, '复制'), isFalse);
    expect(actionEnabled(tester, '保存'), isFalse);
    expect(actionEnabled(tester, '分享'), isFalse);
  });

  testWidgets('切换账号后弹层失效，不会导出上一个账号', (tester) async {
    await pumpSheet(tester, snapshot());

    ZhengfangAuth.instance.debugSetSession(active: true, studentId: '20250002');
    await ZhengfangAuth.instance.markLoggedIn();
    await tester.pump();

    expect(find.textContaining('当前账号已变化或已登出'), findsOneWidget);
    expect(find.byType(SelectableText), findsNothing);
    expect(actionEnabled(tester, '复制'), isFalse);
  });

  testWidgets('同账号重登（revision 推进）也会让弹层失效', (tester) async {
    await pumpSheet(tester, snapshot());

    ZhengfangAuth.instance.debugSetSession(
      active: true,
      studentId: '20250001',
      forceRevision: true,
    );
    await ZhengfangAuth.instance.markLoggedIn();
    await tester.pump();

    expect(find.textContaining('当前账号已变化或已登出'), findsOneWidget);
    expect(actionEnabled(tester, '复制'), isFalse);
  });
}
