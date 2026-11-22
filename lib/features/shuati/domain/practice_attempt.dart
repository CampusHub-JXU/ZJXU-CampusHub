/// 一次作答的提交规则（PWA `QuestionCard.tsx` 的 handleSubmit / handleSelfGrade /
/// handleRedo / toggleOption 里与 UI 无关的部分）。
///
/// 第二阶段 UI 只需把用户操作喂给这些纯函数，再按返回的 [AttemptDecision] 去
/// 保存记录（`PracticeAnswerService`）、更新 `results`、安排自动前进。
library;

import 'answer_judge.dart';
import 'practice_session.dart';
import 'question_type.dart';
import 'shuati_models.dart';

/// 一次提交 / 自评的决定。
class AttemptDecision {
  const AttemptDecision({
    required this.state,
    this.persist,
    this.persistedAnswer = const [],
    this.autoAdvance = false,
  });

  /// 无事发生（已提交 / 题目不可作答 / 空答案）。
  const AttemptDecision.noop(this.state)
    : persist = null,
      persistedAnswer = const [],
      autoAdvance = false;

  /// 新的单题状态。
  final QuestionState state;

  /// 非空表示需要保存一条作答记录（status 即 [persist]）。
  final AnswerStatus? persist;

  /// 要保存的用户答案。
  final List<String> persistedAnswer;

  /// 记录保存**成功后**是否安排 [kAutoAdvanceDelay] 后自动下一题。
  final bool autoAdvance;
}

/// 选项点击：单选 / 判断替换，多选切换；已提交后不可改。
List<String> toggleOption(
  QuestionType type,
  List<String> current,
  String option, {
  required bool submitted,
}) {
  if (submitted) return current;
  if (type == QuestionType.single || type == QuestionType.judge) {
    return [option];
  }
  return current.contains(option)
      ? [
          for (final a in current)
            if (a != option) a,
        ]
      : [...current, option];
}

/// 提交答案（PWA `handleSubmit`）。
///
/// - 已提交 / 题目不可作答（无答案或选择题无选项）/ 答案为空 → [AttemptDecision.noop]；
/// - 填空 / 简答：答案取 `blankInput.trim()`；在**立即展示答案**的模式下进入「待自评」
///   （`submitted=true, status=unanswered`，**不保存记录**）；考试模式则像选择题一样自动判分；
/// - 其余题型：[checkAnswer] 判分并保存记录；答对且立即展示答案 → 自动前进。
AttemptDecision submitAnswer({
  required Question question,
  required QuestionState state,
  required bool showAnswerImmediately,
}) {
  if (state.submitted || !question.isPracticeReady) {
    return AttemptDecision.noop(state);
  }
  final answer = question.type.isSelfGraded
      ? blankInputToAnswer(state.blankInput)
      : state.userAnswer;
  if (answer.isEmpty) return AttemptDecision.noop(state);

  final result = checkAnswer(question, answer);

  if (question.type.isSelfGraded && showAnswerImmediately) {
    return AttemptDecision(
      state: state.copyWith(
        userAnswer: answer,
        submitted: true,
        status: AnswerStatus.unanswered,
      ),
    );
  }

  return AttemptDecision(
    state: state.copyWith(userAnswer: answer, submitted: true, status: result),
    persist: result,
    persistedAnswer: answer,
    autoAdvance: shouldAutoAdvance(
      result,
      showAnswerImmediately: showAnswerImmediately,
    ),
  );
}

/// 填空 / 简答自评（PWA `handleSelfGrade`）：必须已提交；可重复自评（更新同一条记录）。
AttemptDecision selfGrade({
  required QuestionState state,
  required AnswerStatus grade,
  required bool showAnswerImmediately,
}) {
  if (!state.submitted || !grade.isDecided) return AttemptDecision.noop(state);
  final answer = state.userAnswer.isNotEmpty
      ? state.userAnswer
      : blankInputToAnswer(state.blankInput);
  return AttemptDecision(
    state: state.copyWith(status: grade),
    persist: grade,
    persistedAnswer: answer,
    autoAdvance: shouldAutoAdvance(
      grade,
      showAnswerImmediately: showAnswerImmediately,
    ),
  );
}

/// 重做（仅错题本模式）：清空作答并**丢弃 recordId**，下次作答会新增一条记录
/// 而不是覆盖旧记录；调用方同时要把该下标从 `results` 里移除。
QuestionState redo() => const QuestionState.initial();
