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

bool _looksLikeLoginExpired(String text) => looksLikeLoginExpiredMessage(text);
