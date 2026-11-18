import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/shared/widgets/app_banner.dart';
import 'package:jxu_campus_hub/shared/widgets/app_filter_chips.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('AppBanner error 色调取 errorContainer，动作按钮可点', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _host(
        AppBanner(
          icon: Icons.lock_outline,
          tone: AppBannerTone.error,
          message: '统一认证已失效',
          actionLabel: '登录',
          onAction: () => taps++,
        ),
      ),
    );
    final cs = Theme.of(tester.element(find.text('统一认证已失效'))).colorScheme;
    final material = tester.widget<Material>(
      find
          .ancestor(of: find.text('统一认证已失效'), matching: find.byType(Material))
          .first,
    );
    expect(material.color, cs.errorContainer);
    expect(
      tester.widget<Text>(find.text('统一认证已失效')).style?.color,
      cs.onErrorContainer,
    );
    await tester.tap(find.text('登录'));
    expect(taps, 1);
  });

  testWidgets('AppBanner 没有动作时不渲染按钮', (tester) async {
    await tester.pumpWidget(_host(const AppBanner(message: '以下为缓存内容')));
    expect(find.byType(TextButton), findsNothing);
  });

  testWidgets('AppFilterChips 单选：点击回调选中值，选中项用 secondaryContainer', (
    tester,
  ) async {
    String? selected = 'a';
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) => AppFilterChips<String?>(
            options: const [
              AppFilterOption(null, '全部'),
              AppFilterOption('a', '教学'),
              AppFilterOption('b', '竞赛'),
            ],
            selected: selected,
            onSelected: (value) => setState(() => selected = value),
          ),
        ),
      ),
    );
    ChoiceChip chip(String label) => tester.widget<ChoiceChip>(
      find.ancestor(of: find.text(label), matching: find.byType(ChoiceChip)),
    );
    expect(chip('教学').selected, isTrue);
    expect(chip('全部').selected, isFalse);
    final cs = Theme.of(tester.element(find.text('教学'))).colorScheme;
    expect(chip('教学').selectedColor, cs.secondaryContainer);
    expect(chip('教学').showCheckmark, isFalse);

    await tester.tap(find.text('全部'));
    await tester.pump();
    expect(selected, isNull);
    expect(chip('全部').selected, isTrue);
  });

  testWidgets('AppFilterChips wrap 模式换行排列，不横向滚动', (tester) async {
    await tester.pumpWidget(
      _host(
        AppFilterChips<int>(
          wrap: true,
          options: const [AppFilterOption(0, '全部'), AppFilterOption(1, '学生部门')],
          selected: 0,
          onSelected: (_) {},
        ),
      ),
    );
    expect(find.byType(Wrap), findsOneWidget);
    expect(find.byType(SingleChildScrollView), findsNothing);
  });
}
