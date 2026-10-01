part of 'schedule_service.dart';

int? _weekdayToInt(String text) {
  return switch (text) {
    '一' => 1,
    '二' => 2,
    '三' => 3,
    '四' => 4,
    '五' => 5,
    '六' => 6,
    '日' || '天' => 7,
    _ => null,
  };
}

String _decodeHtmlEntities(String value) {
  return value
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&');
}

bool _looksLikeLoginExpired(String text) {
  final value = text.toLowerCase();
  return value.contains('登录') ||
      value.contains('登陆') ||
      value.contains('session') ||
      value.contains('expired') ||
      value.contains('请先登录') ||
      value.contains('重新登录');
}
