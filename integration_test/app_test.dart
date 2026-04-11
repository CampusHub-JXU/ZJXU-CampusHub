import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:jiaxing_university_portal/app/app.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('app boots to shell and shows bottom tabs', (tester) async {
    await tester.pumpWidget(const JiaxingUniversityApp());
    await tester.pumpAndSettle();

    expect(find.text('首页'), findsWidgets);
    expect(find.text('我的'), findsWidgets);
  });
}
