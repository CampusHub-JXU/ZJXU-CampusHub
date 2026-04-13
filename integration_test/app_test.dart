import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:jxu_campus_hub/app/app.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('app boots to shell and shows bottom tabs', (tester) async {
    await tester.pumpWidget(const JXUCampusHubApp());
    await tester.pumpAndSettle();

    expect(find.text('首页'), findsWidgets);
    expect(find.text('我的'), findsWidgets);
  });
}
