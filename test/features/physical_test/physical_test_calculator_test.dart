import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/features/physical_test/physical_test_calculator.dart';

PhysicalTestCalculation _calculate({
  PhysicalTestGrade grade = PhysicalTestGrade.freshman,
  PhysicalTestGender gender = PhysicalTestGender.male,
  double rawBmi = 20,
  double lungCapacityMl = 4545,
  double sprintSeconds = 7.2,
  double sitAndReachCm = 3.7,
  double standingLongJumpCm = 208,
  int strengthReps = 10,
  double enduranceSeconds = 272,
}) => calculatePhysicalTest(
  grade: grade,
  gender: gender,
  heightCm: 200,
  weightKg: rawBmi * 4,
  lungCapacityMl: lungCapacityMl,
  sprintSeconds: sprintSeconds,
  sitAndReachCm: sitAndReachCm,
  standingLongJumpCm: standingLongJumpCm,
  strengthReps: strengthReps,
  enduranceSeconds: enduranceSeconds,
);

void main() {
  test('weights all seven events and uses the last attained threshold', () {
    final result = _calculate();

    expect(result.items.map((item) => item.score), [
      100,
      80,
      78,
      60,
      60,
      60,
      60,
    ]);
    expect(result.items.map((item) => item.weightPercent), [
      15,
      15,
      20,
      10,
      10,
      10,
      20,
    ]);
    expect(result.items.map((item) => item.weightedScore), [
      15,
      12,
      15.6,
      6,
      6,
      6,
      12,
    ]);
    expect(result.totalScore, 72.6);
  });

  test('selects the women’s events and the correct year-group thresholds', () {
    final scoresByGrade = {
      for (final grade in PhysicalTestGrade.values)
        grade: _calculate(
          grade: grade,
          gender: PhysicalTestGender.female,
          lungCapacityMl: 3350,
          sprintSeconds: 8.25,
          sitAndReachCm: 6.4,
          standingLongJumpCm: 151,
          strengthReps: 27,
          enduranceSeconds: 273,
        ),
    };
    expect(scoresByGrade[PhysicalTestGrade.freshman]!.totalScore, 75.25);
    expect(scoresByGrade[PhysicalTestGrade.sophomore]!.totalScore, 75.25);

    final junior = scoresByGrade[PhysicalTestGrade.junior]!;
    expect(junior.items.map((item) => item.score), [
      100,
      90,
      78,
      50,
      50,
      60,
      50,
    ]);
    expect(junior.items[5].name, '1 分钟仰卧起坐');
    expect(junior.items[6].name, '800 米跑');
    expect(junior.totalScore, 70.1);
    expect(scoresByGrade[PhysicalTestGrade.senior]!.totalScore, 70.1);
  });

  test('rounds BMI to one decimal before selecting the category', () {
    const male = PhysicalTestGender.male;
    const female = PhysicalTestGender.female;
    for (final (gender, rawBmi, bmi, score) in [
      (male, 17.84, 17.8, 80),
      (male, 17.86, 17.9, 100),
      (female, 17.14, 17.1, 80),
      (female, 17.16, 17.2, 100),
      (male, 23.94, 23.9, 100),
      (male, 23.96, 24.0, 80),
      (female, 27.94, 27.9, 80),
      (female, 27.96, 28.0, 60),
    ]) {
      final result = _calculate(gender: gender, rawBmi: rawBmi);
      expect(result.bmi, bmi);
      expect(result.items.first.score, score);
    }
  });

  test('skips blank pull-up thresholds and accepts a negative reach', () {
    final result = _calculate(strengthReps: 14, sitAndReachCm: -0.3);

    expect(result.items[3].score, 20);
    expect(result.items[5].score, 76);
  });

  test('scores below the lowest threshold as zero', () {
    final result = _calculate(
      lungCapacityMl: 2299,
      sprintSeconds: 10.11,
      sitAndReachCm: -1.4,
      standingLongJumpCm: 182.99,
      strengthReps: 4,
      enduranceSeconds: 372.01,
    );

    expect(result.items.map((item) => item.score), [100, 0, 0, 0, 0, 0, 0]);
    expect(result.totalScore, 15);
  });

  test('caps each event and the weighted total at 100', () {
    final result = _calculate(
      lungCapacityMl: 6000,
      sprintSeconds: 6.5,
      sitAndReachCm: 30,
      standingLongJumpCm: 280,
      strengthReps: 30,
      enduranceSeconds: 150,
    );

    expect(result.items.map((item) => item.score), everyElement(100));
    expect(result.totalScore, 100);
  });
}
