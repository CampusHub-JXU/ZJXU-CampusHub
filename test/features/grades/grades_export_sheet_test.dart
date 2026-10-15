import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/features/grades/export/grades_export_serializer.dart';
import 'package:jxu_campus_hub/features/grades/export/grades_export_sheet.dart';
import 'package:jxu_campus_hub/features/grades/grades_model.dart';

import '../../helpers/test_setup.dart';

GradeEntry _entry({
  String course = '高等数学A',
  String grade = '优',
  String year = '2025-2026',
  String semester = '第二学期',
}) => GradeEntry(
  courseName: course,
  grade: grade,
  percentageScore: '95',
  gpaPoints: 4.0,
  credits: 5.0,
  academicYear: year,
  semester: semester,
  examType: '考试',
  assessmentMethod: '闭卷',
  courseRequirement: '必修',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await resetTestEnvironment();
    ZhengfangAuth.instance.debugSetSession(active: true, studentId: '20250001');
  });

  GradesExportSnapshot snapshot({String? owner, int? revision}) {
    final auth = ZhengfangAuth.instance;
    return GradesExportSnapshot(
      owner: owner ?? auth.verifiedStudentId!,
      revision: revision ?? auth.sessionRevision,
      grades: [_entry()],
      scope: const GradesExportScope(
        label: '2025–26 春',
        academicYear: '2025-2026',
        semester: '第二学期',
      ),
      exportedAt: DateTime(2026, 10, 13, 10, 30),
      lastUpdatedAt: DateTime(2026, 10, 13, 9, 0),
      dataSource: null,
    );
  }

  Future<void> pumpSheet(WidgetTester tester, GradesExportSnapshot s) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: GradesExportSheet(snapshot: s)),
      ),
    );
    await tester.pump();
  }

  String previewText(WidgetTester tester) =>
      tester.widget<SelectableText>(find.byType(SelectableText)).data!;

  bool copyEnabled(WidgetTester tester) =>
      tester
          .widget<OutlinedButton>(
            find.ancestor(
              of: find.text('复制'),
              matching: find.byType(OutlinedButton),
            ),
          )
          .onPressed !=
      null;

  testWidgets('有效账号下展示范围 / 计数 / 未知来源与 Markdown 预览', (tester) async {
    await pumpSheet(tester, snapshot());

    expect(find.text('导出成绩'), findsOneWidget);
    expect(find.textContaining('仅导出当前已加载成绩'), findsOneWidget);
    expect(find.text('2025–26 春'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('5.0'), findsOneWidget);
    // 最后更新有值，数据来源无法确证显示「未知」。
    expect(find.text('未知'), findsOneWidget);
    expect(previewText(tester), contains('# 成绩导出'));
    expect(copyEnabled(tester), isTrue);
  });

  testWidgets('切换格式后预览随之更新', (tester) async {
    await pumpSheet(tester, snapshot());
    await tester.tap(find.text('CSV'));
    await tester.pump();
    expect(previewText(tester), contains('课程,成绩,百分制'));
    expect(previewText(tester).startsWith('\uFEFF'), isTrue);

    await tester.tap(find.text('JSON'));
    await tester.pump();
    expect(previewText(tester), contains('"schemaVersion": 1'));
  });

  testWidgets('复制会把所选格式写入剪贴板', (tester) async {
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

    await pumpSheet(tester, snapshot());
    await tester.tap(find.text('复制'));
    await tester.pump();

    final clip = calls.where((c) => c.method == 'Clipboard.setData').toList();
    expect(clip, hasLength(1));
    final text = (clip.single.arguments as Map)['text'] as String;
    expect(text, contains('# 成绩导出'));
    expect(find.text('已复制Markdown'), findsOneWidget);
  });

  testWidgets('保存调用文件保存器并提示成功路径', (tester) async {
    String? savedName;
    String? savedContent;
    gradesExportFileSaver = (name, extension, bytes) async {
      savedName = name;
      savedContent = utf8.decode(bytes);
      return '/tmp/$name';
    };
    addTearDown(() => gradesExportFileSaver = defaultGradesExportFileSaver);

    await pumpSheet(tester, snapshot());
    await tester.tap(find.text('保存到文件'));
    await tester.pump();

    expect(savedName, endsWith('.md'));
    expect(savedContent, contains('# 成绩导出'));
    expect(find.textContaining('已保存到 /tmp/'), findsOneWidget);
  });

  testWidgets('登出后弹层立即失效：隐藏预览、禁用复制与保存', (tester) async {
    await pumpSheet(tester, snapshot());
    expect(copyEnabled(tester), isTrue);

    await ZhengfangAuth.instance.markLoggedOut();
    await tester.pump();

    expect(find.textContaining('当前账号已变化或已登出'), findsOneWidget);
    expect(find.byType(SelectableText), findsNothing);
    expect(copyEnabled(tester), isFalse);
    expect(
      tester
          .widget<FilledButton>(
            find.ancestor(
              of: find.text('保存到文件'),
              matching: find.byType(FilledButton),
            ),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('切换账号后弹层失效，不会导出上一个账号', (tester) async {
    await pumpSheet(tester, snapshot());

    ZhengfangAuth.instance.debugSetSession(active: true, studentId: '20250002');
    await ZhengfangAuth.instance.markLoggedIn();
    await tester.pump();

    expect(find.textContaining('当前账号已变化或已登出'), findsOneWidget);
    expect(find.byType(SelectableText), findsNothing);
    expect(copyEnabled(tester), isFalse);
  });

  testWidgets('同账号重登（revision 推进）也会让弹层失效', (tester) async {
    await pumpSheet(tester, snapshot());

    // 同一学号、仅推进身份修订号。
    ZhengfangAuth.instance.debugSetSession(
      active: true,
      studentId: '20250001',
      forceRevision: true,
    );
    await ZhengfangAuth.instance.markLoggedIn();
    await tester.pump();

    expect(find.textContaining('当前账号已变化或已登出'), findsOneWidget);
    expect(copyEnabled(tester), isFalse);
  });
}
