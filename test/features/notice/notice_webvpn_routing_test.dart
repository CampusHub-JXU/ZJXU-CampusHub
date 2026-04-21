import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/notice/notice_list_page.dart';

void main() {
  test('jwc detail should use unified auth protection', () {
    expect(
      shouldOpenNoticeViaUnifiedAuth(
        'https://jwc.zjxu.edu.cn/info/1024/1234.htm',
      ),
      isTrue,
    );
  });

  test('external detail should not use unified auth protection', () {
    expect(
      shouldOpenNoticeViaUnifiedAuth('https://example.com/news/1'),
      isFalse,
    );
  });
}
