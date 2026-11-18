/// 学院简称与活动标题中可能出现的全称。
const secondClassroomCollegeAliases = <List<String>>[
  ['经院', '经济学院'],
  ['商院', '商学院'],
  ['文法', '文法学院'],
  ['医学院', '医学院'],
  ['数信', '数据信息工程学院'],
  ['机电', '机电工程学院'],
];

String normalizeSecondClassroomTag(String value) {
  final output = StringBuffer();
  for (final rune in value.runes) {
    final normalized = rune >= 0xff01 && rune <= 0xff5e ? rune - 0xfee0 : rune;
    final char = String.fromCharCode(normalized).toLowerCase();
    if (RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(char)) {
      output.write(char);
    }
  }
  return output.toString();
}

List<String> secondClassroomKeywords(String input) => input
    .trim()
    .split(RegExp(r'[\s+＋]+'))
    .where((word) => normalizeSecondClassroomTag(word).isNotEmpty)
    .toList();

bool secondClassroomMatchesKeywords(String title, Iterable<String> keywords) {
  final normalizedTitle = normalizeSecondClassroomTag(title);
  final words = keywords
      .expand(secondClassroomKeywords)
      .map(normalizeSecondClassroomTag)
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty || normalizedTitle.isEmpty) return false;
  return words.every((word) {
    if (normalizedTitle.contains(word)) return true;
    for (final aliases in secondClassroomCollegeAliases) {
      final normalized = aliases.map(normalizeSecondClassroomTag).toList();
      if (normalized.contains(word) &&
          normalized.any(normalizedTitle.contains)) {
        return true;
      }
    }
    return false;
  });
}
