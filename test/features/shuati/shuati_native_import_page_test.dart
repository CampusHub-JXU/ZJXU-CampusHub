import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:jxu_campus_hub/features/shuati/import/ai_convert_prompt.dart';
import 'package:jxu_campus_hub/features/shuati/ui/shuati_native_import_page.dart';

void main() {
  testWidgets(
    'shows AI convert prompt copy entry and copies exact prompt to clipboard',
    (tester) async {
      String? copiedText;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            final args = call.arguments as Map<Object?, Object?>;
            copiedText = args['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await tester.pumpWidget(
        const MaterialApp(home: ShuatiNativeImportPage()),
      );
      await tester.pump();

      expect(find.text('选择文件'), findsOneWidget);
      expect(find.text('外部 AI 题库转换'), findsOneWidget);
      final copyButton = find.text('一键复制提示词');
      expect(copyButton, findsOneWidget);
      expect(find.text('查看内容'), findsOneWidget);

      await tester.tap(copyButton);
      await tester.pump();

      expect(copiedText, isNotNull);
      expect(copiedText, isNotEmpty);
      expect(copiedText, kShuatiAiConvertPrompt);
      expect(copiedText, contains('# 技能：CampusHub 刷题助手题库转换器'));
      expect(copiedText, contains('严禁编造答案与解析'));
      expect(copiedText, contains('必须拆成单个大写字母数组'));
      expect(find.text('已复制 AI 转换提示词'), findsOneWidget);

      // 次级入口：打开查看内容弹层并从弹层内复制
      copiedText = null;
      await tester.tap(find.text('查看内容'));
      await tester.pumpAndSettle();

      expect(find.text('外部 AI 转换提示词'), findsOneWidget);
      expect(find.text('复制全部提示词'), findsOneWidget);

      await tester.tap(find.text('复制全部提示词'));
      await tester.pumpAndSettle();

      expect(copiedText, kShuatiAiConvertPrompt);
      expect(find.text('外部 AI 转换提示词'), findsNothing);
      expect(find.text('已复制 AI 转换提示词'), findsOneWidget);
    },
  );
}
