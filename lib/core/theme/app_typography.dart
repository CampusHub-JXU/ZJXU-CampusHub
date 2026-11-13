import 'package:flutter/material.dart';

/// 内容层字号角色 —— 设计系统 v2（`docs/design-baseline/DESIGN.md` §3）。
///
/// 主题 [TextTheme] 只有 11/12/14/16/20… 几档，而内容层最常用的 13 号
/// （分组标、次要文字）与 16 号（行标题）以及数字阶梯没有对应位置，
/// 于是各页各写 `TextStyle(fontSize: …)`。这里把这些角色集中定义：
///
/// * 颜色随 [ColorScheme] 注入（[AppTypography.fromScheme]），调用方一般
///   直接用，需要强调色时再 `copyWith(color: …)`；
/// * 只给普通 `fontSize`，文字缩放由 `AppTextScaleScope` 在
///   `MediaQuery.textScaler` 层统一生效，不在这里乘倍率；
/// * 字体家族不写：继承 `ThemeData.fontFamily`（打包的 Inter 子集，中文
///   回退系统字体）。
///
/// ## v2 的两条硬规则
///
/// 1. **轻量正文 + 强数字对比**：中文笔画在 700–800 会挤死，行标题降到
///    `w500`、正文 `w400`，`w700` 只留给顶层标题与等宽数字读数。
/// 2. **白名单外不自造字号**：基础阶梯是 7 文本 + 5 数字角色，另加 5 类
///    受控 Override（[AppScheduleType] `O1`、[AppArticleType] `O2`、
///    [AppCompactMetricType] `O3`、[AppHeroType] `O4`、[AppChromeType]
///    `O5`）。其余场景一律回到基础阶梯。
///
/// 访问：`context.appText.body`。未注册扩展（如测试里的裸 `MaterialApp`）
/// 时按当前 [ColorScheme] 现算一份，不会抛错。
@immutable
class AppTypography extends ThemeExtension<AppTypography> {
  const AppTypography({
    required this.display,
    required this.title,
    required this.section,
    required this.rowTitle,
    required this.rowTitleStrong,
    required this.body,
    required this.group,
    required this.meta,
    required this.tag,
    required this.numReadout,
    required this.numStat,
    required this.numValue,
    required this.numUnit,
    required this.numUnitCompact,
  });

  factory AppTypography.fromScheme(ColorScheme cs) {
    const tabular = [FontFeature.tabularFigures()];
    final ink1 = cs.onSurface;
    final ink2 = cs.onSurfaceVariant;
    return AppTypography(
      display: TextStyle(
        fontSize: 36,
        fontWeight: FontWeight.w700,
        height: 1.14,
        letterSpacing: -0.8,
        color: ink1,
      ),
      title: TextStyle(
        fontSize: 26,
        fontWeight: FontWeight.w700,
        height: 1.20,
        letterSpacing: -0.5,
        color: ink1,
      ),
      section: TextStyle(
        fontSize: 19,
        fontWeight: FontWeight.w600,
        height: 1.28,
        letterSpacing: -0.2,
        color: ink1,
      ),
      rowTitle: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w500,
        height: 1.35,
        color: ink1,
      ),
      rowTitleStrong: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        height: 1.35,
        color: ink1,
      ),
      body: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w400,
        height: 1.55,
        color: ink1,
      ),
      group: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        height: 1.42,
        letterSpacing: 0.2,
        color: ink2,
      ),
      meta: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w400,
        height: 1.42,
        color: ink2,
      ),
      tag: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        height: 1.20,
        letterSpacing: 0.3,
        color: ink2,
      ),
      numReadout: TextStyle(
        fontSize: 68,
        fontWeight: FontWeight.w700,
        height: 1.00,
        letterSpacing: -2.2,
        color: ink1,
        fontFeatures: tabular,
      ),
      numStat: TextStyle(
        fontSize: 46,
        fontWeight: FontWeight.w700,
        height: 1.02,
        letterSpacing: -1.2,
        color: ink1,
        fontFeatures: tabular,
      ),
      numValue: TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w700,
        height: 1.12,
        letterSpacing: -0.4,
        color: ink1,
        fontFeatures: tabular,
      ),
      numUnit: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        height: 1.00,
        color: ink2,
      ),
      numUnitCompact: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        height: 1.00,
        color: ink2,
      ),
    );
  }

  /// 36 w700：顶层主标题（整屏最多一处）。
  final TextStyle display;

  /// 26 w700：页面标题（`成绩`、`一卡通`、`全部功能`）。
  final TextStyle title;

  /// 19 w600：段落标题（`校园公告`、`本学期概览`）。
  final TextStyle section;

  /// 16 w500：标准列表 / 卡片条目标题。
  final TextStyle rowTitle;

  /// 16 w600：未读 / 告警强调态标题（`rowTitle` 的唯一加粗变体）。
  final TextStyle rowTitleStrong;

  /// 15 w400：说明文字、只读尾部值。
  final TextStyle body;

  /// 13 w600 灰：卡片上方的分组标（`.t-group`）。
  final TextStyle group;

  /// 13 w400 灰：行副标题、时间戳等元信息。
  final TextStyle meta;

  /// 11 w600：语义状态胶囊 / dock 标签 / 新鲜度徽标。
  final TextStyle tag;

  /// 68 w700 等宽：单值详情页主读数（`DetailReadout`）。
  final TextStyle numReadout;

  /// 46 w700 等宽：单屏唯一的英雄级统计（GPA、倒计时）。
  final TextStyle numStat;

  /// 24 w700 等宽：列表行右侧关键值、摘要卡指标。
  final TextStyle numValue;

  /// 14 w500 灰：紧贴大读数后的单位（`kWh`、`元`）。
  final TextStyle numUnit;

  /// 12 w500 灰：双列 / 三列紧凑读数后的单位。
  final TextStyle numUnitCompact;

  // ── v0 别名（保留 API 兼容，语义已按 v2 收敛） ──────────────────────────

  /// [group] 的历史别名。
  TextStyle get label => group;

  /// [rowTitle] 的历史别名：分组列表行（`PlainListRow`）。
  TextStyle get listTitle => rowTitle;

  /// [meta] 的历史别名。
  TextStyle get secondary => meta;

  /// [numReadout] 的历史别名。
  TextStyle get readout => numReadout;

  /// [numStat] 的历史别名。
  TextStyle get overview => numStat;

  /// [numValue] 的历史别名。
  TextStyle get rowValue => numValue;

  /// [numUnit] 的历史别名。
  TextStyle get unit => numUnit;

  @override
  AppTypography copyWith({
    TextStyle? display,
    TextStyle? title,
    TextStyle? section,
    TextStyle? rowTitle,
    TextStyle? rowTitleStrong,
    TextStyle? body,
    TextStyle? group,
    TextStyle? meta,
    TextStyle? tag,
    TextStyle? numReadout,
    TextStyle? numStat,
    TextStyle? numValue,
    TextStyle? numUnit,
    TextStyle? numUnitCompact,
  }) {
    return AppTypography(
      display: display ?? this.display,
      title: title ?? this.title,
      section: section ?? this.section,
      rowTitle: rowTitle ?? this.rowTitle,
      rowTitleStrong: rowTitleStrong ?? this.rowTitleStrong,
      body: body ?? this.body,
      group: group ?? this.group,
      meta: meta ?? this.meta,
      tag: tag ?? this.tag,
      numReadout: numReadout ?? this.numReadout,
      numStat: numStat ?? this.numStat,
      numValue: numValue ?? this.numValue,
      numUnit: numUnit ?? this.numUnit,
      numUnitCompact: numUnitCompact ?? this.numUnitCompact,
    );
  }

  @override
  AppTypography lerp(covariant AppTypography? other, double t) {
    if (other == null) return this;
    TextStyle l(TextStyle a, TextStyle b) => TextStyle.lerp(a, b, t)!;
    return AppTypography(
      display: l(display, other.display),
      title: l(title, other.title),
      section: l(section, other.section),
      rowTitle: l(rowTitle, other.rowTitle),
      rowTitleStrong: l(rowTitleStrong, other.rowTitleStrong),
      body: l(body, other.body),
      group: l(group, other.group),
      meta: l(meta, other.meta),
      tag: l(tag, other.tag),
      numReadout: l(numReadout, other.numReadout),
      numStat: l(numStat, other.numStat),
      numValue: l(numValue, other.numValue),
      numUnit: l(numUnit, other.numUnit),
      numUnitCompact: l(numUnitCompact, other.numUnitCompact),
    );
  }
}

extension AppTypographyContext on BuildContext {
  /// 当前主题的 [AppTypography]；未注册时按当前 [ColorScheme] 现算。
  AppTypography get appText {
    final theme = Theme.of(this);
    return theme.extension<AppTypography>() ??
        AppTypography.fromScheme(theme.colorScheme);
  }
}

// ===========================================================================
// 五类白名单 Override（O1–O5）
//
// 规范之外的任何字号都是 bug；`design_ratchet_test` 会拦住 features/ 与
// shared/widgets/ 里新写的 `fontSize:`。这些常量就是合法出口。
// ===========================================================================

/// **O1 · 课表网格微字阶**（`SchedulePage` 的 7 列周网格专用）。
///
/// `385dp` 视口扣掉 `26dp` 节次栏、卡片内边距与 `2dp` 间距后，每列可用的
/// 文字宽度约 `38dp`：`13sp` 只能放下 2 个汉字，课名与教室号必然截断；
/// `11sp` 可放下 3 个汉字（3 行 = 9 字），配合 `9.5sp` 教室号才读得全。
///
/// 该网格内文字缩放钳制在 `[0.95, 1.08]`（见 [AppTextScaleGuard]）；
/// 需要更大字号的用户走「今日议程」列表视图。
class AppScheduleType {
  AppScheduleType._();

  /// 12 w600：星期（`一` / `二`）。
  static const TextStyle weekday = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    height: 1.20,
  );

  /// 10.5 w400 灰：日期（`09` / `10`），等宽数字。
  static const TextStyle date = TextStyle(
    fontSize: 10.5,
    fontWeight: FontWeight.w400,
    height: 1.20,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// 12 w700：节次序号（`1`…`9`），等宽数字。
  static const TextStyle slotIndex = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w700,
    height: 1.15,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// 9.5 w400 灰：节次开始时刻（`08:00`），等宽数字。
  static const TextStyle slotTime = TextStyle(
    fontSize: 9.5,
    fontWeight: FontWeight.w400,
    height: 1.15,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// 11 w600：课程名（最多 3 行，每行 3 个汉字）。
  static const TextStyle cellTitle = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    height: 1.20,
  );

  /// 9.5 w500：教室 / 教师（在标题色基础上降一档不透明度）。
  static const TextStyle cellRoom = TextStyle(
    fontSize: 9.5,
    fontWeight: FontWeight.w500,
    height: 1.16,
  );
}

/// **O2 · 长文阅读面**（通知详情、协议 / Markdown 正文）。
///
/// 真机审计里可读性最高的页面就是通知详情：`17sp / 1.75`、首行缩进两字。
/// 这个作用域放开系统字号缩放 `[0.85, 1.35]`。
class AppArticleType {
  AppArticleType._();

  /// 21 w700：正文内小标题。
  static const TextStyle heading = TextStyle(
    fontSize: 21,
    fontWeight: FontWeight.w700,
    height: 1.35,
    letterSpacing: -0.3,
  );

  /// 17 w400 / 1.75：正文段落。
  static const TextStyle body = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w400,
    height: 1.75,
  );
}

/// **O3 · 双列 / 三列紧凑读数**（首页资产条、概览摘要格）。
///
/// `24sp` 的 `¥ 1,248.50` 与状态胶囊并排时会被压到截断，降到 `20sp`
/// 后仍保持等宽数字对齐。
class AppCompactMetricType {
  AppCompactMetricType._();

  /// 20 w700 等宽：紧凑格主数值。
  static const TextStyle value = TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.w700,
    height: 1.10,
    letterSpacing: -0.3,
    fontFeatures: [FontFeature.tabularFigures()],
  );
}

/// **O4 · 首页 Hero 课名按字数自适应**。
///
/// 真实教务课名从 4 个汉字到 18 个汉字都有：固定 `36sp` 会让长课名折成
/// 4–5 行或截掉关键后缀（`（上）`、`实验`）。按可见字符数三档下台阶，
/// 长档最多 2 行。
class AppHeroType {
  AppHeroType._();

  /// ≤ 6 字：34 w700。
  static const TextStyle short = TextStyle(
    fontSize: 34,
    fontWeight: FontWeight.w700,
    height: 1.14,
    letterSpacing: -0.7,
  );

  /// 7–11 字：28 w700。
  static const TextStyle medium = TextStyle(
    fontSize: 28,
    fontWeight: FontWeight.w700,
    height: 1.18,
    letterSpacing: -0.5,
  );

  /// ≥ 12 字：22 w600，最多 2 行。
  static const TextStyle long = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w600,
    height: 1.24,
    letterSpacing: -0.2,
    overflow: TextOverflow.ellipsis,
  );

  /// 按课名长度选档（按 Unicode 标量计数，中文 / 字母同权重）。
  static TextStyle forTitle(String title) {
    final length = title.runes.length;
    if (length <= 6) return short;
    if (length <= 11) return medium;
    return long;
  }

  /// 长档的推荐行数上限；短 / 中档可单行展示。
  static int maxLinesFor(String title) => title.runes.length <= 11 ? 2 : 2;
}

/// **O5 · 导航壳层与分段控件锁缩放**。
///
/// 壳层文字排版参与布局（顶栏高度、dock 高度、分段控件宽度都是常量），
/// 系统字号拉到 130% 会把它们撑破。这层的缩放上限钳制到 `1.10`，
/// 见 [AppTextScaleGuard]。
class AppChromeType {
  AppChromeType._();

  /// 13.5 w600：分段控件标签。
  static const TextStyle segment = TextStyle(
    fontSize: 13.5,
    fontWeight: FontWeight.w600,
    height: 1.20,
  );

  /// 16 w600：顶栏标题。
  static const TextStyle topBar = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w600,
    height: 1.20,
  );

  /// 11 w600：dock 标签。
  static const TextStyle dock = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    height: 1.15,
    letterSpacing: 0.2,
  );
}

/// 局部文字缩放钳制（`O1` 网格与 `O5` 壳层共用）。
///
/// 只改这个子树里的 `MediaQuery.textScaler`，不影响页面其余部分。上下限
/// 作用在**最终缩放倍率**上（已包含 `AppTextScaleScope` 的用户因子）。
class AppTextScaleGuard extends StatelessWidget {
  const AppTextScaleGuard({super.key, required this.child, this.min, this.max});

  /// `O1` 课表网格：`[0.95, 1.08]`。
  const AppTextScaleGuard.scheduleGrid({super.key, required this.child})
    : min = 0.95,
      max = 1.08;

  /// `O5` 导航壳层：只压上限 `1.10`。
  const AppTextScaleGuard.chrome({super.key, required this.child})
    : min = null,
      max = 1.10;

  final Widget child;
  final double? min;
  final double? max;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return MediaQuery(
      data: media.copyWith(
        textScaler: media.textScaler.clamp(
          minScaleFactor: min ?? 0,
          maxScaleFactor: max ?? double.infinity,
        ),
      ),
      child: child,
    );
  }
}
