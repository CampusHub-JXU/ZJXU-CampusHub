import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/second_classroom/second_classroom_matcher.dart';

void main() {
  group('normalizeSecondClassroomTag', () {
    test('lowercases, drops spaces and punctuation, folds fullwidth', () {
      expect(normalizeSecondClassroomTag(' ＡＢＣ１２３ '), 'abc123');
      expect(normalizeSecondClassroomTag('经院·开跑（2026）'), '经院开跑2026');
      expect(normalizeSecondClassroomTag('Hello, World!'), 'helloworld');
      expect(normalizeSecondClassroomTag('——'), '');
    });
  });

  group('secondClassroomKeywords', () {
    test('splits on spaces and plus signs', () {
      expect(secondClassroomKeywords('经院 开跑'), ['经院', '开跑']);
      expect(secondClassroomKeywords('经院+开跑'), ['经院', '开跑']);
      expect(secondClassroomKeywords('经院＋开跑'), ['经院', '开跑']);
      expect(secondClassroomKeywords('  经院  开跑  '), ['经院', '开跑']);
    });

    test('drops words that normalize to nothing', () {
      expect(secondClassroomKeywords('，。 开跑'), ['开跑']);
      expect(secondClassroomKeywords('   '), isEmpty);
      expect(secondClassroomKeywords('+＋'), isEmpty);
    });
  });

  group('secondClassroomMatchesKeywords', () {
    test('matches when every keyword appears in the title', () {
      expect(secondClassroomMatchesKeywords('经院学子 开跑啦', ['经院', '开跑']), isTrue);
    });

    test('requires all keywords (AND), partial match fails', () {
      expect(
        secondClassroomMatchesKeywords('经院学子 开跑啦', ['经院', '开跑', '讲座']),
        isFalse,
      );
      expect(secondClassroomMatchesKeywords('经院学子 开跑啦', ['讲座']), isFalse);
    });

    test('keyword order does not matter', () {
      expect(secondClassroomMatchesKeywords('经院学子 开跑啦', ['开跑', '经院']), isTrue);
    });

    test('ignores fullwidth/halfwidth, punctuation and case differences', () {
      expect(
        secondClassroomMatchesKeywords('ＡＢＣ讲座·2026', ['ａｂｃ', '2026']),
        isTrue,
      );
      expect(
        secondClassroomMatchesKeywords('经院：开跑（2026）', ['经院 2026']),
        isTrue,
      );
      expect(secondClassroomMatchesKeywords('ABC 分享会', ['abc分享会']), isTrue);
    });

    test('college alias matches the full name and the other way round', () {
      expect(secondClassroomMatchesKeywords('经济学院学子开跑啦', ['经院']), isTrue);
      expect(secondClassroomMatchesKeywords('经院学子开跑啦', ['经济学院']), isTrue);
    });

    test('alias does not leak across colleges', () {
      expect(secondClassroomMatchesKeywords('商学院学子开跑啦', ['经院']), isFalse);
      expect(secondClassroomMatchesKeywords('机电工程学院招新', ['经院']), isFalse);
    });

    test('college-only keyword filters out other colleges', () {
      const title = '数据信息工程学院 编程马拉松';
      expect(secondClassroomMatchesKeywords(title, ['数信']), isTrue);
      expect(secondClassroomMatchesKeywords(title, ['经院']), isFalse);
    });

    test('empty keywords or empty title never match', () {
      expect(secondClassroomMatchesKeywords('经院学子开跑啦', const []), isFalse);
      expect(secondClassroomMatchesKeywords('经院学子开跑啦', ['   ']), isFalse);
      expect(secondClassroomMatchesKeywords('', ['经院']), isFalse);
      expect(secondClassroomMatchesKeywords('!!!', ['经院']), isFalse);
    });

    test('duplicate and padded keywords behave like a single keyword', () {
      expect(
        secondClassroomMatchesKeywords('经院学子开跑啦', ['经院', '经院', ' 经院 ']),
        isTrue,
      );
      expect(
        secondClassroomMatchesKeywords('经院学子开跑啦', ['经院', '开跑', '开跑']),
        isTrue,
      );
    });
  });
}
