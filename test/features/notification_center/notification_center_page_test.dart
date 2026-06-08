import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/notification_center/notification_center_page.dart';

void main() {
  test('jwc notice urls are protected by unified auth', () {
    expect(
      shouldOpenCampusNoticeViaUnifiedAuth(
        'https://jwc.zjxu.edu.cn/content.jsp?id=1',
      ),
      isTrue,
    );
    expect(
      shouldOpenCampusNoticeViaUnifiedAuth(
        'https://www.zjxu.edu.cn/content.jsp?id=1',
      ),
      isFalse,
    );
    expect(shouldOpenCampusNoticeViaUnifiedAuth('not-a-url'), isFalse);
  });
}
