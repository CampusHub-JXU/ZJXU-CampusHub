import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/features/grades/grades_model.dart';
import 'package:jxu_campus_hub/features/home/function_zone/function_zone_bento.dart';

void main() {
  group('assignBentoTiles 尺寸分配', () {
    final realEntries = [
      // 静态重要度：90/88/86/84/80/78/60/58/56/50/46/44/42/40
      for (final id in const [
        'schedule',
        'grades',
        'exam',
        'campus-card',
        'campus-card-payment',
        'dorm-electricity',
        'library',
        'second-classroom',
        'notification-center',
        'shuati-practice',
        'service-hall',
        'sjjx-notice-list',
        'notice-list',
        'changxing-jiada',
      ])
        BentoEntryInput(id: id, sortOrder: 0),
    ];

    test('手机（2 units/行）：整行 wide 只给 rank0，其余全部 small', () {
      final tiles = assignBentoTiles(
        realEntries,
        const BentoUsageInput(),
        unitsPerRow: 2,
      );

      expect(tiles, hasLength(14));
      expect(tiles[0].id, 'schedule');
      expect(tiles[0].size, BentoTileSize.wide);
      for (final tile in tiles.skip(1)) {
        expect(tile.size, BentoTileSize.small, reason: tile.id);
      }
    });

    test('宽屏（4 units/行）：rank0 → large，wide 按奇偶档取值，其余 → small', () {
      // 14 条入口：small = 14-1-w 为偶数 → w 取 3（grades/exam/campus-card），
      // 剩余 10 个 small 两两成行，末行不留孤 unit。
      final tiles = assignBentoTiles(
        realEntries,
        const BentoUsageInput(),
        unitsPerRow: 4,
      );

      expect(tiles, hasLength(14));
      expect(tiles[0].id, 'schedule');
      expect(tiles[0].size, BentoTileSize.large);
      expect(tiles[1].id, 'grades');
      expect(tiles[1].size, BentoTileSize.wide);
      expect(tiles[2].id, 'exam');
      expect(tiles[2].size, BentoTileSize.wide);
      expect(tiles[3].id, 'campus-card');
      expect(tiles[3].size, BentoTileSize.wide);
      for (final tile in tiles.skip(4)) {
        expect(tile.size, BentoTileSize.small, reason: tile.id);
      }
    });

    test('宽屏奇数入口（15 条）：wide 降档为 2，保证 small 成偶', () {
      final tiles = assignBentoTiles(
        [
          ...realEntries,
          const BentoEntryInput(id: 'unknown-entry', sortOrder: 0),
        ],
        const BentoUsageInput(),
        unitsPerRow: 4,
      );

      expect(tiles, hasLength(15));
      expect(tiles[0].size, BentoTileSize.large);
      expect(tiles[1].id, 'grades');
      expect(tiles[1].size, BentoTileSize.wide);
      expect(tiles[2].id, 'exam');
      expect(tiles[2].size, BentoTileSize.wide);
      expect(tiles[3].id, 'campus-card');
      expect(tiles[3].size, BentoTileSize.small);
      for (final tile in tiles.skip(3)) {
        expect(tile.size, BentoTileSize.small, reason: tile.id);
      }
    });

    test('置顶条目获得 rank0（手机 wide / 宽屏 large）', () {
      final usage = const BentoUsageInput(pinnedIds: ['notice-list']);
      final entries = const [
        BentoEntryInput(id: 'grades', sortOrder: 10),
        BentoEntryInput(id: 'notice-list', sortOrder: 65),
      ];

      // notice-list 静态 42 + 置顶 100 = 142 > grades 88。
      final compact = assignBentoTiles(entries, usage, unitsPerRow: 2);
      expect(compact[0].id, 'notice-list');
      expect(compact[0].size, BentoTileSize.wide);
      expect(compact[1].id, 'grades');
      expect(compact[1].size, BentoTileSize.small);

      final expanded = assignBentoTiles(entries, usage, unitsPerRow: 4);
      expect(expanded[0].id, 'notice-list');
      expect(expanded[0].size, BentoTileSize.large);
      expect(expanded[1].id, 'grades');
      expect(expanded[1].size, BentoTileSize.wide);
    });

    test('访问计数阈值：1 次与 2 次同序（布局惯性），3 次跳档反超', () {
      const second = BentoEntryInput(id: 'second-classroom', sortOrder: 10);
      const shuati = BentoEntryInput(id: 'shuati-practice', sortOrder: 20);

      List<BentoTile> ranked(int visitCount) => assignBentoTiles(
        const [second, shuati],
        BentoUsageInput(visitCountById: {'shuati-practice': visitCount}),
        unitsPerRow: 2,
      );

      // 1 次与 2 次同为 +8 分档：shuati 50+8=58 与 second 58 平分，
      // 按 sortOrder 升序 → 结果完全一致（布局惯性）。
      final atOne = ranked(1);
      final atTwo = ranked(2);
      expect(atOne.map((t) => t.id), atTwo.map((t) => t.id));
      expect(atOne[0].id, 'second-classroom');
      expect(atOne[0].size, BentoTileSize.wide);
      expect(atOne[1].size, BentoTileSize.small);

      // 3 次跳到 +16 分档：66 > 58，反超拿到整行 wide。
      final atThree = ranked(3);
      expect(atThree[0].id, 'shuati-practice');
      expect(atThree[0].size, BentoTileSize.wide);
      expect(atThree[1].id, 'second-classroom');
      expect(atThree[1].size, BentoTileSize.small);
    });

    test('得分平分按 sortOrder 升序', () {
      final tiles = assignBentoTiles(
        const [
          BentoEntryInput(id: 'unknown-a', sortOrder: 30),
          BentoEntryInput(id: 'unknown-b', sortOrder: 10),
        ],
        const BentoUsageInput(),
        unitsPerRow: 2,
      );

      // 两者都走兜底分 30，平分按 sortOrder 升序。
      expect(tiles[0].id, 'unknown-b');
      expect(tiles[0].size, BentoTileSize.wide);
      expect(tiles[1].id, 'unknown-a');
      expect(tiles[1].size, BentoTileSize.small);
    });

    test('空列表返回空', () {
      expect(
        assignBentoTiles(const [], const BentoUsageInput(), unitsPerRow: 2),
        isEmpty,
      );
    });
  });

  group('packBentoTiles 打包', () {
    List<BentoTile> tilesFromSizes(List<BentoTileSize> sizes) => [
      for (var i = 0; i < sizes.length; i++)
        BentoTile(id: 't$i', sortOrder: i, size: sizes[i]),
    ];

    void expectNoOverlap(List<BentoPlacement> placements, int unitsPerRow) {
      final cells = <String>{};
      for (final placement in placements) {
        expect(
          placement.col + placement.colSpan,
          lessThanOrEqualTo(unitsPerRow),
          reason: '${placement.tile.id} 越出网格右边界',
        );
        for (
          var row = placement.row;
          row < placement.row + placement.rowSpan;
          row++
        ) {
          for (
            var col = placement.col;
            col < placement.col + placement.colSpan;
            col++
          ) {
            final key = '$row:$col';
            expect(
              cells.contains(key),
              isFalse,
              reason: '${placement.tile.id} 在 $key 与已有瓦片重叠',
            );
            cells.add(key);
          }
        }
      }
    }

    BentoPlacement placementOf(List<BentoPlacement> placements, String id) =>
        placements.firstWhere((placement) => placement.tile.id == id);

    test('[large, wide, wide, small×10] 紧凑 2 列：占位无重叠、行号正确', () {
      final tiles = tilesFromSizes([
        BentoTileSize.large,
        BentoTileSize.wide,
        BentoTileSize.wide,
        ...List.filled(10, BentoTileSize.small),
      ]);

      final placements = packBentoTiles(tiles, unitsPerRow: 2);
      expectNoOverlap(placements, 2);
      expect(placements, hasLength(13));

      // large 需要连续两行整行空闲 → 占满第 0-1 行。
      final large = placementOf(placements, 't0');
      expect(large.col, 0);
      expect(large.row, 0);
      expect(large.colSpan, 2);
      expect(large.rowSpan, 2);

      // wide 需要整行空闲 → 各占一整行。
      expect(placementOf(placements, 't1').row, 2);
      expect(placementOf(placements, 't1').colSpan, 2);
      expect(placementOf(placements, 't2').row, 3);
      expect(placementOf(placements, 't2').colSpan, 2);

      // small 两两成行铺在第 4-8 行，末行满 2 unit 不触发升级。
      for (var i = 3; i <= 12; i++) {
        final placement = placementOf(placements, 't$i');
        expect(placement.row, 4 + (i - 3) ~/ 2, reason: 't$i');
        expect(placement.col, (i - 3) % 2, reason: 't$i');
        expect(placement.tile.size, BentoTileSize.small, reason: 't$i');
      }
    });

    test('[large, wide, wide, small×10] 宽屏 4 列：small 回填行尾空 unit', () {
      final tiles = tilesFromSizes([
        BentoTileSize.large,
        BentoTileSize.wide,
        BentoTileSize.wide,
        ...List.filled(10, BentoTileSize.small),
      ]);

      final placements = packBentoTiles(tiles, unitsPerRow: 4);
      expectNoOverlap(placements, 4);
      expect(placements, hasLength(13));

      expect(placementOf(placements, 't0').row, 0);
      expect(placementOf(placements, 't0').colSpan, 2);
      expect(placementOf(placements, 't0').rowSpan, 2);
      // wide 锚定整行空闲行的行首。
      expect(placementOf(placements, 't1').row, 2);
      expect(placementOf(placements, 't1').col, 0);
      expect(placementOf(placements, 't2').row, 3);
      expect(placementOf(placements, 't2').col, 0);

      // small 依「第一个空闲 unit」回填 large/wide 的行尾。
      final expectedCells = {
        't3': const (2, 0),
        't4': const (3, 0),
        't5': const (2, 1),
        't6': const (3, 1),
        't7': const (2, 2),
        't8': const (3, 2),
        't9': const (2, 3),
        't10': const (3, 3),
        't11': const (0, 4),
        't12': const (1, 4),
      };
      expectedCells.forEach((id, cell) {
        final placement = placementOf(placements, id);
        expect(placement.col, cell.$1, reason: id);
        expect(placement.row, cell.$2, reason: id);
        expect(placement.tile.size, BentoTileSize.small, reason: id);
      });
    });

    test('末行孤 unit 的 small 升级为 wide 补满行', () {
      final placements = packBentoTiles(
        tilesFromSizes(const [
          BentoTileSize.small,
          BentoTileSize.small,
          BentoTileSize.small,
        ]),
        unitsPerRow: 2,
      );

      expectNoOverlap(placements, 2);
      final lone = placementOf(placements, 't2');
      expect(lone.row, 1);
      expect(lone.col, 0);
      expect(lone.tile.size, BentoTileSize.wide);
      expect(lone.colSpan, 2);
      expect(lone.rowSpan, 1);
      // 前一行的小瓦片不受影响。
      expect(placementOf(placements, 't0').tile.size, BentoTileSize.small);
      expect(placementOf(placements, 't1').tile.size, BentoTileSize.small);
    });

    test('全 small 奇数个：末行孤 unit 补满（2 列与 4 列）', () {
      final compact = packBentoTiles(
        tilesFromSizes(List.filled(5, BentoTileSize.small)),
        unitsPerRow: 2,
      );
      expectNoOverlap(compact, 2);
      final lastCompact = placementOf(compact, 't4');
      expect(lastCompact.row, 2);
      expect(lastCompact.tile.size, BentoTileSize.wide);
      expect(lastCompact.colSpan, 2);

      final expanded = packBentoTiles(
        tilesFromSizes(List.filled(5, BentoTileSize.small)),
        unitsPerRow: 4,
      );
      expectNoOverlap(expanded, 4);
      final lastExpanded = placementOf(expanded, 't4');
      expect(lastExpanded.row, 1);
      expect(lastExpanded.col, 0);
      expect(lastExpanded.tile.size, BentoTileSize.wide);
      expect(lastExpanded.colSpan, 2);
    });

    test('空列表不崩且返回空', () {
      expect(packBentoTiles(const [], unitsPerRow: 2), isEmpty);
      expect(packBentoTiles(const [], unitsPerRow: 4), isEmpty);
    });
  });

  group('formatGradeStats 绩点统计口径', () {
    GradeEntry grade(double gpaPoints, double credits) => GradeEntry(
      courseName: '课程',
      grade: '',
      percentageScore: '',
      gpaPoints: gpaPoints,
      credits: credits,
      academicYear: '',
      semester: '',
      examType: '',
      assessmentMethod: '',
      courseRequirement: '',
    );

    test('正常加权：Σ(gpa×credits)/Σcredits，绩点 2 位、学分 1 位', () {
      final stats = formatGradeStats([grade(4.0, 3), grade(3.0, 2)]);
      // (4.0×3 + 3.0×2) / 5 = 3.60。
      expect(stats, '绩点 3.60 · 已修 5.0 学分');
    });

    test('空列表与 null 返回 null（回退 subtitle）', () {
      expect(formatGradeStats(null), isNull);
      expect(formatGradeStats(<GradeEntry>[]), isNull);
    });

    test('全零学分无可计入条目，返回 null', () {
      expect(formatGradeStats([grade(4.0, 0), grade(3.0, 0)]), isNull);
    });

    test('gpaPoints≤0 的条目剔除（不进分子也不进学分分母）', () {
      final stats = formatGradeStats([grade(4.0, 3), grade(0.0, 2)]);
      // 0 绩点条目不计入：12 / 3 = 4.00，学分只算 3.0。
      expect(stats, '绩点 4.00 · 已修 3.0 学分');

      final negative = formatGradeStats([grade(4.0, 3), grade(-1.0, 2)]);
      expect(negative, '绩点 4.00 · 已修 3.0 学分');
    });
  });
}
