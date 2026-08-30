/// 首页「功能」Bento 网格纯算法层：离散尺寸分配、贪心打包与成绩统计口径。
///
/// 本文件保持纯 Dart（仅依赖无任何 import 的 [GradeEntry] 模型），不引入
/// Flutter，便于单元测试与布局逻辑复用；Widget 层见 function_zone_section.dart。
library;

import '../../grades/grades_model.dart';

/// Bento 瓦片的离散尺寸。本版仅三种，不实现 1x2 竖条（tallRect）。
enum BentoTileSize {
  /// 2x2 units —— 段落内最重要入口（rank 0）。
  large,

  /// 2x1 units —— 次重要入口（rank 1-2）。
  wide,

  /// 1x1 unit —— 其余入口。
  small,
}

/// 参与尺寸分配的功能入口极简描述（与 Flutter 解耦）。
class BentoEntryInput {
  const BentoEntryInput({required this.id, required this.sortOrder});

  final String id;

  /// 目录内排序值，得分平分时按升序破平。
  final int sortOrder;
}

/// 使用数据快照的极简描述（来自 ServiceHubUsageStore）。
class BentoUsageInput {
  const BentoUsageInput({
    this.pinnedIds = const [],
    this.visitCountById = const {},
  });

  final List<String> pinnedIds;
  final Map<String, int> visitCountById;
}

/// 分配好尺寸的瓦片。
class BentoTile {
  const BentoTile({
    required this.id,
    required this.sortOrder,
    required this.size,
  });

  final String id;
  final int sortOrder;
  final BentoTileSize size;
}

/// 打包结果：瓦片在 unit 网格中的占位（col/row 从 0 起）。
class BentoPlacement {
  const BentoPlacement({
    required this.tile,
    required this.col,
    required this.row,
    required this.colSpan,
    required this.rowSpan,
  });

  final BentoTile tile;
  final int col;
  final int row;
  final int colSpan;
  final int rowSpan;
}

/// 静态重要度：按「学生日常使用频率 + 场景刚性」离线写死，理由见各条注释。
const Map<String, int> _staticImportanceById = {
  'schedule': 90, // 课表：查课是每日刚需，稳居最大瓦片
  'grades': 88, // 成绩：出分季高频，且有绩点统计可展示
  'exam': 86, // 考试安排：考前刚需，可展示倒计时
  'campus-card': 84, // 一卡通：余额/充值高频刚需
  'campus-card-payment': 80, // 付款码：支付场景高频，与一卡通同域
  'dorm-electricity': 78, // 宿舍电费：低电量时刚需
  'library': 60, // 图书馆：借阅期高频，平日一般
  'second-classroom': 58, // 第二课堂：活动申报季使用
  'notification-center': 56, // 通知中心：聚合查看，中频
  'shuati-practice': 50, // 刷题：备考期高频，平日低频
  'service-hall': 46, // 服务大厅：低频聚合兜底入口
  'sjjx-notice-list': 44, // 实践通知：实习季低频
  'notice-list': 42, // 校园公告：低频浏览
  'changxing-jiada': 40, // 畅行嘉大：请假/返校低频
};

/// 未收录入口的静态重要度兜底分。
const int _fallbackImportance = 30;

/// 置顶加成：保证置顶入口必进前两名（拿到 large/wide）。
const int _pinnedBonus = 100;

/// 访问量化分：阈值阶梯制。
///
/// 同一档位内访问次数变化不改变得分 —— 「尺寸变化快、位置变化慢」：
/// 只有跨过 1/3/8/20 次档位边界才会影响尺寸与排名，日常使用中网格保持
/// 惯性，不会因为多点了一次就左右跳动。
int _usageScore(int visitCount) {
  if (visitCount >= 20) return 32;
  if (visitCount >= 8) return 24;
  if (visitCount >= 3) return 16;
  if (visitCount >= 1) return 8;
  return 0;
}

/// 宽屏（4 units/行）的 wide 瓦片数量：在 3/2/1 中选择使 small 数量为
/// 偶数的最大档。
///
/// small 数量为偶数时末行自然铺满，不触发「末行孤 unit 升级 wide」补丁，
/// 也避免最低分入口意外变成整宽瓦片。入口数不足 2 时没有 wide。
int _wideTileCount(int entryCount) {
  if (entryCount < 2) return 0;
  for (final candidate in const [3, 2, 1]) {
    if (candidate >= entryCount) continue;
    if ((entryCount - 1 - candidate).isEven) return candidate;
  }
  return 1;
}

/// 按得分（静态重要度 + 访问量化分 + 置顶加成）降序分配离散尺寸；
/// 得分平分时按 [BentoEntryInput.sortOrder] 升序。
///
/// 尺寸策略按网格宽度分档：
///
/// * 手机（2 units/行）：**不使用 large**——2×2 通栏大块会淹没两列
///   节奏（整页退化成单列大按钮）。整行 wide 只给 rank0 一名（带统计
///   行的唯一焦点），其余全部 small 两两成行；奇数 small 触发打包层的
///   「末行孤 unit 升级 wide」补丁，末行不留半行。
/// * 宽屏（≥4 units/行）：rank0 → large，rank1..wideCount → wide
///   （数量见 [_wideTileCount]），其余 → small；2×2 在四列网格里比例
///   合适，三档层次恢复。
List<BentoTile> assignBentoTiles(
  List<BentoEntryInput> entries,
  BentoUsageInput usage, {
  required int unitsPerRow,
}) {
  final pinnedIds = usage.pinnedIds.toSet();

  int scoreOf(BentoEntryInput entry) {
    final staticScore = _staticImportanceById[entry.id] ?? _fallbackImportance;
    final visitScore = _usageScore(usage.visitCountById[entry.id] ?? 0);
    final pinnedScore = pinnedIds.contains(entry.id) ? _pinnedBonus : 0;
    return staticScore + visitScore + pinnedScore;
  }

  final ranked = [...entries]
    ..sort((left, right) {
      final byScore = scoreOf(right).compareTo(scoreOf(left));
      if (byScore != 0) return byScore;
      return left.sortOrder.compareTo(right.sortOrder);
    });

  if (unitsPerRow < 4) {
    return [
      for (var rank = 0; rank < ranked.length; rank++)
        BentoTile(
          id: ranked[rank].id,
          sortOrder: ranked[rank].sortOrder,
          size: rank == 0 ? BentoTileSize.wide : BentoTileSize.small,
        ),
    ];
  }

  final wideCount = _wideTileCount(ranked.length);
  return [
    for (var rank = 0; rank < ranked.length; rank++)
      BentoTile(
        id: ranked[rank].id,
        sortOrder: ranked[rank].sortOrder,
        size: switch (rank) {
          0 => BentoTileSize.large,
          final rank when rank <= wideCount => BentoTileSize.wide,
          _ => BentoTileSize.small,
        },
      ),
  ];
}

/// 贪心扫描打包：
///
/// * large/wide 需要整行空闲（large 需连续两行都整行空闲），锚定行首 col0；
/// * small 放全局扫描到的第一个空闲 unit（可回填 wide/large 行尾空 unit）；
/// * 允许行尾留空 unit；打包结束后若最后一行只用了 1 个 unit 且该瓦片是
///   small，则升级为 wide 补满行，避免孤零零半行。
///
/// 结果保证无重叠，且 col + colSpan ≤ unitsPerRow。
List<BentoPlacement> packBentoTiles(
  List<BentoTile> tiles, {
  required int unitsPerRow,
}) {
  final placements = <BentoPlacement>[];
  if (tiles.isEmpty || unitsPerRow <= 0) return placements;

  final occupiedByRow = <int, Set<int>>{};

  bool isFree(int row, int col) =>
      !(occupiedByRow[row]?.contains(col) ?? false);

  bool rowFullyFree(int row) {
    for (var col = 0; col < unitsPerRow; col++) {
      if (!isFree(row, col)) return false;
    }
    return true;
  }

  void markOccupied(int row, int col, int colSpan, int rowSpan) {
    for (var r = row; r < row + rowSpan; r++) {
      final cells = occupiedByRow.putIfAbsent(r, () => <int>{});
      for (var c = col; c < col + colSpan; c++) {
        cells.add(c);
      }
    }
  }

  for (final tile in tiles) {
    final rawColSpan = switch (tile.size) {
      BentoTileSize.large || BentoTileSize.wide => 2,
      BentoTileSize.small => 1,
    };
    // 防御：unitsPerRow 异常缩小时按整行处理，避免越界。
    final colSpan = rawColSpan > unitsPerRow ? unitsPerRow : rawColSpan;
    final rowSpan = tile.size == BentoTileSize.large ? 2 : 1;

    if (tile.size == BentoTileSize.small) {
      // small：逐行逐列扫描，放第一个空闲 unit。
      var placed = false;
      for (var row = 0; !placed; row++) {
        for (var col = 0; col < unitsPerRow; col++) {
          if (!isFree(row, col)) continue;
          markOccupied(row, col, 1, 1);
          placements.add(
            BentoPlacement(
              tile: tile,
              col: col,
              row: row,
              colSpan: 1,
              rowSpan: 1,
            ),
          );
          placed = true;
          break;
        }
      }
    } else {
      // wide/large：找第一段「整行空闲」的行，锚定 col0。
      var row = 0;
      while (true) {
        var spanFree = true;
        for (var r = row; r < row + rowSpan; r++) {
          if (!rowFullyFree(r)) {
            spanFree = false;
            break;
          }
        }
        if (spanFree) {
          markOccupied(row, 0, colSpan, rowSpan);
          placements.add(
            BentoPlacement(
              tile: tile,
              col: 0,
              row: row,
              colSpan: colSpan,
              rowSpan: rowSpan,
            ),
          );
          break;
        }
        row++;
      }
    }
  }

  _upgradeLoneLastUnit(placements, unitsPerRow: unitsPerRow, isFree: isFree);
  return placements;
}

/// 末行孤 unit 升级：最后一行只占 1 个 unit 且该瓦片是 small 时，
/// 升级为 wide 补满行。
void _upgradeLoneLastUnit(
  List<BentoPlacement> placements, {
  required int unitsPerRow,
  required bool Function(int row, int col) isFree,
}) {
  if (placements.isEmpty) return;

  var lastRow = 0;
  for (final placement in placements) {
    if (placement.row > lastRow) lastRow = placement.row;
  }

  // 统计末行占用 unit 数（rowSpan=2 的瓦片第二行不计入，其 p.row 在上方）。
  var lastRowUsedUnits = 0;
  BentoPlacement? loneSmall;
  for (final placement in placements) {
    if (placement.row != lastRow) continue;
    lastRowUsedUnits += placement.colSpan;
    if (placement.tile.size == BentoTileSize.small) {
      loneSmall = placement;
    }
  }

  final lone = loneSmall;
  if (lastRowUsedUnits != 1 || lone == null) return;
  // 防御：目标 unit 必须在网格内且空闲（正常打包下必然满足）。
  if (lone.col + 1 >= unitsPerRow || !isFree(lastRow, lone.col + 1)) return;

  final index = placements.indexOf(lone);
  placements[index] = BentoPlacement(
    tile: BentoTile(
      id: lone.tile.id,
      sortOrder: lone.tile.sortOrder,
      size: BentoTileSize.wide,
    ),
    col: lone.col,
    row: lone.row,
    colSpan: 2,
    rowSpan: 1,
  );
}

/// 由成绩缓存计算「绩点 X.XX · 已修 Y.Y 学分」统计文案。
///
/// * 加权 GPA = Σ(gpaPoints × credits) / Σcredits，仅 credits>0 且
///   gpaPoints>0 的条目计入（0 绩点/异常记录不参与），四舍五入保留 2 位；
/// * 已修学分 Σcredits 保留 1 位；
/// * [grades] 为 null、空列表或无可计入条目（如全零学分）时返回 null，
///   调用方回退到入口 subtitle。
String? formatGradeStats(List<GradeEntry>? grades) {
  if (grades == null || grades.isEmpty) return null;

  var weightedPoints = 0.0;
  var totalCredits = 0.0;
  for (final grade in grades) {
    if (grade.credits <= 0 || grade.gpaPoints <= 0) continue;
    weightedPoints += grade.gpaPoints * grade.credits;
    totalCredits += grade.credits;
  }
  if (totalCredits <= 0) return null;

  final gpa = weightedPoints / totalCredits;
  return '绩点 ${gpa.toStringAsFixed(2)} · 已修 ${totalCredits.toStringAsFixed(1)} 学分';
}
