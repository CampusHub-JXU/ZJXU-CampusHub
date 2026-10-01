import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/core/theme/app_typography.dart';
import 'package:jxu_campus_hub/shared/widgets/app_list_tile.dart';
import 'package:jxu_campus_hub/shared/widgets/app_status_tag.dart';

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

void main() {
  testWidgets('AppListTile 排出标题 / 元信息 / 明细 / 右侧值，标题用 rowTitle', (tester) async {
    await tester.pumpWidget(
      _host(
        const AppListTile(
          title: '高等数学',
          meta: '4 学分 · 考试',
          details: ['7/1 周三 14:00-16:00', '教学楼A301 本部'],
          trailing: Text('95'),
        ),
      ),
    );
    for (final text in ['高等数学', '4 学分 · 考试', '7/1 周三 14:00-16:00', '95']) {
      expect(find.text(text), findsOneWidget);
    }
    final context = tester.element(find.text('高等数学'));
    final title = tester.widget<Text>(find.text('高等数学'));
    expect(title.style?.fontSize, context.appText.rowTitle.fontSize);
    expect(title.style?.fontWeight, FontWeight.w600);
    // 平色底，不做背景模糊。
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('AppListTile dimmed 时标题降为次要色，可点击', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _host(AppListTile(title: '大学英语', dimmed: true, onTap: () => taps++)),
    );
    final context = tester.element(find.text('大学英语'));
    expect(
      tester.widget<Text>(find.text('大学英语')).style?.color,
      Theme.of(context).colorScheme.onSurfaceVariant,
    );
    await tester.tap(find.text('大学英语'));
    expect(taps, 1);
  });

  testWidgets('AppStatusTag 各色调只取 ColorScheme 角色', (tester) async {
    await tester.pumpWidget(
      _host(
        const Column(
          children: [
            AppStatusTag('中性'),
            AppStatusTag('正常', tone: AppStatusTone.positive),
            AppStatusTag('提醒', tone: AppStatusTone.attention),
            AppStatusTag('异常', tone: AppStatusTone.danger),
          ],
        ),
      ),
    );
    final cs = Theme.of(tester.element(find.text('中性'))).colorScheme;
    Color? fg(String label) =>
        tester.widget<Text>(find.text(label)).style?.color;
    expect(fg('中性'), cs.onSurfaceVariant);
    expect(fg('正常'), cs.onSecondaryContainer);
    expect(fg('提醒'), cs.onTertiaryContainer);
    expect(fg('异常'), cs.onErrorContainer);
    expect(tester.widget<Text>(find.text('正常')).style?.fontSize, 11);
  });
}
