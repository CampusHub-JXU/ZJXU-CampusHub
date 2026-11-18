import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/shared/widgets/app_icon_badge.dart';

import '../../helpers/pump_app.dart';

void main() {
  ColorScheme schemeOf(WidgetTester tester) {
    return Theme.of(tester.element(find.byType(AppIconBadge))).colorScheme;
  }

  Color iconColorOf(WidgetTester tester) {
    return tester.widget<Icon>(find.byType(Icon)).color!;
  }

  testWidgets('普通徽标使用主题色而非 accent', (tester) async {
    const accent = Color(0xFF7B61FF);
    await pumpApp(
      tester,
      const AppIconBadge(icon: Icons.school_outlined, accentColor: accent),
    );

    expect(iconColorOf(tester), schemeOf(tester).primary);
    expect(iconColorOf(tester), isNot(accent));
  });

  testWidgets('semantic 徽标保留调用方状态色', (tester) async {
    const semantic = Color(0xFFB3261E);
    await pumpApp(
      tester,
      const AppIconBadge(
        icon: Icons.error_outline,
        accentColor: semantic,
        semantic: true,
      ),
    );

    expect(iconColorOf(tester), semantic);
    expect(iconColorOf(tester), isNot(schemeOf(tester).primary));
  });
}
