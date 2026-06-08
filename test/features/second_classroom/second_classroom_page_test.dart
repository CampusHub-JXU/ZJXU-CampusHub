import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/second_classroom/second_classroom_page.dart';

void main() {
  test('detects second classroom auth provider entry urls', () {
    expect(
      isSecondClassroomAuthProviderEntryUrl(
        '${SecondClassroomPage.authEntryUrl}test-code',
      ),
      isTrue,
    );
    expect(
      isSecondClassroomAuthProviderEntryUrl(SecondClassroomPage.initialUrl),
      isFalse,
    );
  });

  test('detects second classroom landing root urls', () {
    expect(
      isSecondClassroomLandingRootUrl('https://twdekt.zjxu.edu.cn/dekt/'),
      isTrue,
    );
    expect(
      isSecondClassroomLandingRootUrl('https://twdekt.zjxu.edu.cn/dekt'),
      isTrue,
    );
    expect(
      isSecondClassroomLandingRootUrl(SecondClassroomPage.initialUrl),
      isFalse,
    );
  });
}
