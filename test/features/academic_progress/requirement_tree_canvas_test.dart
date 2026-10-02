import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/academic_progress/academic_progress_model.dart';
import 'package:jxu_campus_hub/features/academic_progress/requirement_tree_canvas.dart';

RequirementNode _n(
  String id, [
  List<RequirementNode> children = const [],
  RequirementRelation relation = RequirementRelation.all,
]) => RequirementNode(
  id: id,
  name: id,
  children: children,
  relation: relation,
  isLeaf: children.isEmpty,
);

void main() {
  const w = RequirementTreeLayout.nodeWidth;
  const h = RequirementTreeLayout.nodeHeight;
  const pad = RequirementTreeLayout.padding;
  const col = RequirementTreeLayout.columnGap;
  const row = RequirementTreeLayout.rowGap;

  test('末节点逐行排列，父节点居中于首尾子节点', () {
    final layout = layoutRequirementTree([
      _n('root', [
        _n('a', [_n('a1'), _n('a2')]),
        _n('b'),
      ]),
      _n('other'),
    ]);

    expect(layout.nodes['a1']!.top, pad);
    expect(layout.nodes['a2']!.top, pad + h + row);
    expect(layout.nodes['b']!.top, pad + 2 * (h + row));
    expect(layout.nodes['other']!.top, pad + 3 * (h + row));
    expect(layout.nodes['a']!.top, (pad + pad + h + row) / 2);
    expect(
      layout.nodes['root']!.top,
      (layout.nodes['a']!.top + layout.nodes['b']!.top) / 2,
    );
    expect(layout.nodes['a1']!.left, pad + 2 * (w + col));
    expect(
      layout.size,
      Size(pad * 2 + 3 * w + 2 * col, pad * 2 + 4 * h + 3 * row),
    );
    expect(layout.edges, hasLength(4));
  });

  test('任意深度都布局，不丢子树', () {
    final layout = layoutRequirementTree([
      _n('l0', [
        _n('l1', [
          _n('l2', [
            _n('l3', [_n('l4')]),
          ]),
        ]),
      ]),
    ]);
    expect(layout.nodes.keys, containsAll(['l0', 'l1', 'l2', 'l3', 'l4']));
    expect(layout.nodes['l4']!.left, pad + 4 * (w + col));
    expect(layout.size.width, pad * 2 + 5 * w + 4 * col);
  });

  test('「或者」关系的连线标记为虚线', () {
    final layout = layoutRequirementTree([
      _n('g', [_n('x'), _n('y')], RequirementRelation.any),
      _n('s', [_n('z')], RequirementRelation.any),
    ]);
    final alt = layout.edges.where((e) => e.alternative);
    expect(alt, hasLength(2));
  });

  test('空树', () {
    final layout = layoutRequirementTree(const []);
    expect(layout.nodes, isEmpty);
    expect(layout.size.height, pad * 2);
  });
}
