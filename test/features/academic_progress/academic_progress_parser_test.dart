import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/features/academic_progress/academic_progress_model.dart';
import 'package:jxu_campus_hub/features/academic_progress/academic_progress_parser.dart';

/// 夹具按 2026-10 抓到的首页脚本模板精简生成：学号 2020000000、姓名「测试同学」，
/// GPA / 学分 / 门数均为假数据（docs/academic-progress-xsxyqk-api.md）。
String _fixture() =>
    File('test/fixtures/academic_progress/xsxyqk_index_excerpt.html')
        .readAsStringSync();

void main() {
  test('解析首页：统计区、隐藏参数与学分要求树', () {
    final page = parseAcademicProgressIndex(_fixture());
    expect(page, isNotNull);

    expect(page!.summary.gpa, '3.000');
    expect(page.summary.planTotal, 90);
    expect(page.summary.planPassed, 30);
    expect(page.summary.outsideFailed, 1);
    expect(page.queryParams['cjlrxn'], '2026');
    expect(page.queryParams['cjlrxq'], '3');
    expect(page.queryParams['cjzt'], '');

    expect(page.roots.map((r) => r.name), ['主修', '其他课程', '创新创业情况']);

    final major = page.roots.first;
    expect(major.requiredCredits, isNull, reason: '主修容器的 0.0 不是要求');
    expect(major.relation, RequirementRelation.all);
    expect(major.children.map((c) => c.name), ['必修课合计', '校通识课合计']);

    final required = major.children.first;
    expect(required.requiredCredits, 120);
    expect(required.earnedCredits, 70);
    expect(required.isLeaf, isFalse);
    expect(required.children.map((c) => c.name), ['其他必修课', '实践环节']);

    final other = required.children.first;
    expect(other.id, '2F7FB60CC2808277E063150B0A0A612B');
    expect(other.parentId, required.id);
    expect(other.requiredCredits, 56);
    expect(other.earnedCredits, 40);
    expect(other.missingCredits, 16);
    expect(other.courseAttribute, '1');
    expect(other.isLeaf, isTrue);
    expect(other.serverPassedCount, 20);
    expect(other.usesGroupEndpoint, isFalse);

    final general = major.children.last;
    expect(general.relation, RequirementRelation.any);
    final history = general.children.first;
    expect(history.name, '“四史”类');
    final science = general.children.last;
    expect(science.courseAttribute, '4');
    expect(science.usesGroupEndpoint, isTrue);
    expect(science.creditStatus, CreditStatus.met);

    final others = page.roots[1];
    expect(others.isOtherCourses, isTrue);
    expect(others.needsCourses, isTrue);
    expect(others.usesGroupEndpoint, isFalse);
    expect(others.requiredCredits, isNull);
    expect(page.roots[2].needsCourses, isFalse);

    // 需要请求课程明细的末节点：4 个计划节点 + 其他课程。
    final leaves = page.roots
        .expand((r) => r.leaves)
        .where((l) => l.needsCourses)
        .map((l) => l.name)
        .toList();
    expect(leaves, ['其他必修课', '实践环节', '“四史”类', '自然科学类', '其他课程']);
  });

  test('结构无法识别时 fail closed', () {
    expect(parseAcademicProgressIndex('<html><body>登录</body></html>'), isNull);
  });
}
