import 'package:flutter/material.dart';

import '../../../core/theme/app_theme_controller.dart';
import '../../../core/theme/personalization_controller.dart';
import '../models/home_presentation.dart';
import '../../../core/theme/app_typography.dart';

/// Primary Status Hero：首页唯一的最强视觉焦点（无框纯排版）。
///
/// 顶部环境行「周次 · 日期」+ 通知铃 / 更新入口；
/// 主体按 kicker → 大字 → 时间 → 地点元信息 → 「查看课表」的
/// 纯文字层级直接坐在页面背景上，靠 typography + spacing 建立层级，
/// 不使用任何卡片容器 / 玻璃 / 底纹。文字颜色统一走
/// [AppThemeController] 的 system 透传路径，兼容自定义背景图模式。
class HomePrimaryStatusHero extends StatelessWidget {
  const HomePrimaryStatusHero({
    super.key,
    required this.hero,
    required this.envDateText,
    required this.envStatusText,
    this.canShowUpdateAction = false,
    required this.onOpenSchedule,
    required this.onNotificationTap,
    this.unreadNoticeCount = 0,
    required this.onUpdateTap,
    this.onLoginTap,
  });

  /// 官方校徽水印资源（矢量源件在 tools/brand/jxu_emblem.svg）。
  static const String _emblemAsset = 'assets/brand/jxu_emblem.png';

  final HomeHeroPresentation hero;

  /// 环境行日期文案，如「8月29日 周六」。
  final String envDateText;

  /// 环境行状态文案，如「第 3 周」/「学期已结束」；为空时省略该段
  /// （未开学时为空，「开学」语义由 Hero 倒计时唯一承担）。
  final String envStatusText;
  final bool canShowUpdateAction;

  /// 打开课表回调；仅课程类 Hero 显示「查看课表」入口，
  /// 其余 kind 传 null 且不渲染该入口。
  final VoidCallback? onOpenSchedule;
  final VoidCallback onNotificationTap;

  /// 教务处通知未读数（角标；0 时隐藏）。
  final int unreadNoticeCount;
  final VoidCallback? onUpdateTap;

  /// 打开教务登录弹层；仅「登录后查看课程」态整块可点并显示「去登录」入口。
  final VoidCallback? onLoginTap;

  /// 课程大字形态的 Hero：正在上课 / 下一节课(今天) / 下一节课(今天没课)。
  bool get _isCourseKind =>
      hero.kind == HomeHeroKind.currentCourse ||
      hero.kind == HomeHeroKind.nextCourseToday ||
      hero.kind == HomeHeroKind.nextCourseUpcoming;

  /// 未开学倒计时 Hero 也可整体点进课表（下方「开学首日」预览同源），
  /// 但不渲染「查看课表」文字入口——入口由预览段落承担。
  bool get _isStatusHeroTappable =>
      onOpenSchedule != null && hero.kind == HomeHeroKind.beforeSemester;

  bool get _isLoginHero =>
      onLoginTap != null && hero.kind == HomeHeroKind.loggedOut;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final textTheme = theme.textTheme;
    final primaryTextColor = AppThemeController.instance.resolveHomeTextColor(
      context,
      cs.onSurface,
    );
    final secondaryTextColor = AppThemeController.instance
        .resolveHomeSecondaryTextColor(context, cs.onSurfaceVariant);
    // kicker / 「查看课表」强调色：system 模式透传主题酒红，
    // 强制文字色模式（自定义背景图）下跟随可读文字色。
    final accentColor = AppThemeController.instance.resolveHomeTextColor(
      context,
      cs.primary,
    );
    final kickerColor = hero.kind == HomeHeroKind.examSoon
        ? AppThemeController.instance.resolveHomeTextColor(context, cs.error)
        : accentColor;
    final kickerText = switch (hero.kind) {
      HomeHeroKind.currentCourse => '正在上课',
      HomeHeroKind.nextCourseToday => '下一节课',
      HomeHeroKind.examSoon => '考试临近',
      HomeHeroKind.beforeSemester => '未开学',
      HomeHeroKind.semesterOver => '本学期已结束',
      HomeHeroKind.noCourseToday => '今天',
      HomeHeroKind.nextCourseUpcoming => '今天没课 · 下一节',
      HomeHeroKind.holiday => hero.kicker ?? '放假中',
      HomeHeroKind.loggedOut => '未登录',
    };
    // kicker 去重：与环境行状态相同（如「学期已结束」）时不再重复；
    // 未开学态的「开学」语义由倒计时大字唯一承担，同样不出 kicker。
    final showKicker =
        kickerText != envStatusText && hero.kind != HomeHeroKind.beforeSemester;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildEnvRow(context, primaryTextColor, secondaryTextColor),
        // 环境行以下整体垫一层校徽水印（在文字下层，不拦截点击），
        // 填补 Hero 文字右侧留白。Stack 必须撑满可用宽度，否则
        // 水印的 right:0 锚在文字列右缘而不是页面右缘。
        SizedBox(
          width: double.infinity,
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 环境行到 kicker 之间的呼吸空间。
                  const SizedBox(height: 56),
                  if (showKicker) ...[
                    Text(
                      kickerText,
                      style: textTheme.labelLarge!.copyWith(
                        letterSpacing: 0.5,
                        color: kickerColor,
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (_isCourseKind)
                    _buildCourseHero(
                      context,
                      accentColor: accentColor,
                      primaryTextColor: primaryTextColor,
                      secondaryTextColor: secondaryTextColor,
                    )
                  else
                    _buildStatusHero(
                      context,
                      accentColor: accentColor,
                      primaryTextColor: primaryTextColor,
                      secondaryTextColor: secondaryTextColor,
                    ),
                ],
              ),
              _buildEmblemWatermarkSlot(accentColor),
            ],
          ),
        ),
      ],
    );
  }

  /// 校徽水印插槽：按首页个性化开关启停（关闭时整块不渲染）。
  Widget _buildEmblemWatermarkSlot(Color tintColor) {
    return ValueListenableBuilder<bool>(
      valueListenable:
          PersonalizationController.instance.emblemWatermarkEnabled,
      builder: (context, enabled, _) {
        if (!enabled) return const SizedBox.shrink();
        return _buildEmblemWatermark(tintColor);
      },
    );
  }

  /// 品牌校徽水印：贴 Hero 右下角，纯装饰（指针穿透 + 无语义）。
  /// 用 srcIn 把校徽着色到 accentColor——system 模式即主题酒红，
  /// 自定义背景图强制文字色模式下跟随可读文字色；边长随 Hero 块高
  /// 自适应，上限 170。Image 必须给显式宽高，交给约束自然缩放时
  /// 测试渲染会出现原尺寸溢出绘制。
  Widget _buildEmblemWatermark(Color tintColor) {
    return Positioned(
      right: 0,
      top: 0,
      bottom: 0,
      child: IgnorePointer(
        child: ExcludeSemantics(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final double side = constraints.maxHeight.clamp(0.0, 170.0);
              // y=0.7：整体偏右下角，与 Hero 右下留白对齐；x=1 贴页面右缘。
              return Align(
                alignment: const Alignment(1, 0.7),
                // 着色 + 透明度合并进图片自身的 srcIn 颜色滤镜：0.12 保证
                // 环形英文与嘉字细节可辨、不与正文抢视觉；不再套 Opacity +
                // ColorFiltered（两层离屏 saveLayer，滚动重绘时每帧都要额外合成）。
                child: Image.asset(
                  _emblemAsset,
                  width: side,
                  height: side,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.medium,
                  color: tintColor.withValues(alpha: 0.12),
                  colorBlendMode: BlendMode.srcIn,
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  /// 顶部环境行：左「周次 · 日期」（如「第 5 周 · 10月2日 周五」），右更新角标 + 通知铃。
  /// 周次状态为空（未开学，语义由 Hero 倒计时承担）时省略该段。
  Widget _buildEnvRow(
    BuildContext context,
    Color primaryTextColor,
    Color secondaryTextColor,
  ) {
    final cs = Theme.of(context).colorScheme;
    final envStyle = context.appText.rowTitle;
    final hasStatus = envStatusText.isNotEmpty;
    return Row(
      children: [
        Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                // 周次在前、日期在后（「第 5 周 · 10月2日 周五」）；周次为空
                // （未开学）时只剩日期。
                if (hasStatus) ...[
                  TextSpan(
                    text: envStatusText,
                    style: envStyle.copyWith(
                      fontWeight: FontWeight.w600,
                      color: secondaryTextColor,
                    ),
                  ),
                  TextSpan(
                    text: ' · ',
                    style: envStyle.copyWith(
                      fontWeight: FontWeight.w500,
                      color: secondaryTextColor,
                    ),
                  ),
                ],
                TextSpan(
                  text: envDateText,
                  style: envStyle.copyWith(
                    fontWeight: hasStatus ? FontWeight.w500 : FontWeight.w600,
                    color: secondaryTextColor,
                  ),
                ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (canShowUpdateAction && onUpdateTap != null) ...[
          const SizedBox(width: 12),
          _buildUpdateAction(cs, primaryTextColor),
        ],
        const SizedBox(width: 12),
        IconButton(
          icon: Badge(
            isLabelVisible: unreadNoticeCount > 0,
            label: Text('$unreadNoticeCount'),
            child: Icon(
              Icons.notifications_outlined,
              color: primaryTextColor,
              size: 22,
            ),
          ),
          onPressed: onNotificationTap,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
          tooltip: '通知中心',
        ),
      ],
    );
  }

  Widget _buildUpdateAction(ColorScheme cs, Color iconColor) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        IconButton(
          icon: Icon(Icons.system_update_outlined, color: iconColor, size: 22),
          onPressed: onUpdateTap,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
          tooltip: '发现新版本',
        ),
        Positioned(
          right: -1,
          top: -1,
          child: Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              color: cs.error,
              shape: BoxShape.circle,
              border: Border.all(color: cs.onError, width: 1.2),
            ),
          ),
        ),
      ],
    );
  }

  /// 课程类 Hero（正在上课 / 下一节课今天 / 下一节课今天没课）：
  /// 课程名（`O4` 自适应 34/28/22）→ 时间 → 地点/节次 → 查看课表。
  /// 课程信息主体整体可点跳转课表（课表双入口：hero 主体 + 功能区瓦片）。
  Widget _buildCourseHero(
    BuildContext context, {
    required Color accentColor,
    required Color primaryTextColor,
    required Color secondaryTextColor,
  }) {
    // 「下一节课(今天)」的倒计时大字（如「42 分钟后上课」）并入时间行；
    // 「下一节课(今天没课)」的时间行自带日期标签（如「明天 08:00」），原样展示。
    final timeLine =
        hero.kind == HomeHeroKind.nextCourseToday && hero.headline.isNotEmpty
        ? '${hero.timeText} · ${hero.headline}'
        : hero.timeText;
    // `O4` 自适应课名：4 个汉字和 18 个汉字都真实存在，固定字号不是折成
    // 4 行就是截掉「（上）」「实验」这类关键后缀。
    final courseTitle = hero.courseName ?? hero.headline;
    final courseInfo = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          courseTitle,
          style: AppHeroType.forTitle(courseTitle)
              .copyWith(color: primaryTextColor),
          maxLines: AppHeroType.maxLinesFor(courseTitle),
          overflow: TextOverflow.ellipsis,
        ),
        if (timeLine != null && timeLine.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            timeLine,
            style: AppChromeType.topBar.copyWith(
              height: 1.5,
              color: primaryTextColor,
            ),
          ),
        ],
        if (hero.locationText != null) ...[
          const SizedBox(height: 12),
          _heroMetaLine(
            context,
            Icons.location_on_outlined,
            hero.locationText!,
            secondaryTextColor,
          ),
        ],
        if (hero.lessonText != null) ...[
          SizedBox(height: hero.locationText != null ? 8 : 12),
          _heroMetaLine(
            context,
            Icons.schedule_outlined,
            hero.lessonText!,
            secondaryTextColor,
          ),
        ],
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (onOpenSchedule != null)
          Semantics(
            button: true,
            label: '查看课表 ${hero.courseName ?? ''}',
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: onOpenSchedule,
              child: courseInfo,
            ),
          )
        else
          courseInfo,
        if (onOpenSchedule != null) ...[
          const SizedBox(height: 10),
          Semantics(
            button: true,
            label: '查看课表 ${hero.courseName ?? ''}',
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: onOpenSchedule,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '查看课表',
                      style: context.appText.rowTitle.copyWith(
                        color: accentColor,
                      ),
                    ),
                    const SizedBox(width: 2),
                    Icon(Icons.chevron_right, size: 16, color: accentColor),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// 课程 Hero 的地点 / 节次行：各占一行，避免挤在一起。
  Widget _heroMetaLine(
    BuildContext context,
    IconData icon,
    String text,
    Color color,
  ) {
    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            text,
            style: context.appText.rowTitle.copyWith(
              fontWeight: FontWeight.w400,
              height: 1.5,
              color: color,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  /// 非课程类 Hero：headline 作大字，时间 / 课程名 / 地点作为副文案，
  /// 确保原有信息一项不丢。
  ///
  /// 未开学倒计时态整块可点进课表（与下方「开学首日」预览同一动作）；
  /// 未登录态整块可点打开教务登录；其余状态不承担跳转。
  Widget _buildStatusHero(
    BuildContext context, {
    required Color accentColor,
    required Color primaryTextColor,
    required Color secondaryTextColor,
  }) {
    final textTheme = Theme.of(context).textTheme;
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          // 假期文案在第一个逗号后换行，两行短句不压右侧校徽。
          hero.kind == HomeHeroKind.holiday
              ? hero.headline.replaceFirst('，', '，\n')
              : hero.headline,
          // 假期文案是整屏的主角，与课程 Hero 同档（headlineLarge 32）；
          // 其余状态（未开学 / 学期结束 / 无课 / 未登录）保持 25 的状态档。
          style: hero.kind == HomeHeroKind.holiday
              ? textTheme.headlineLarge!.copyWith(
                  height: 1.3,
                  color: primaryTextColor,
                )
              : textTheme.headlineSmall!.copyWith(
                  fontSize: 25,
                  height: 1.2,
                  fontWeight: FontWeight.w700,
                  color: primaryTextColor,
                ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        if (hero.timeText != null) ...[
          const SizedBox(height: 6),
          Text(
            hero.timeText!,
            style: context.appText.rowTitle.copyWith(color: secondaryTextColor),
          ),
        ],
        if (hero.courseName != null) ...[
          const SizedBox(height: 4),
          Text(
            hero.courseName!,
            style: context.appText.rowTitle.copyWith(
              fontWeight: FontWeight.w500,
              color: secondaryTextColor,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        if (hero.locationText != null || hero.lessonText != null) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              if (hero.locationText != null) ...[
                Icon(
                  Icons.location_on_outlined,
                  size: 14,
                  color: secondaryTextColor,
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    hero.locationText!,
                    style: textTheme.bodyMedium!.copyWith(
                      color: secondaryTextColor,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
              if (hero.lessonText != null) ...[
                if (hero.locationText != null) const SizedBox(width: 12),
                Icon(
                  Icons.schedule_outlined,
                  size: 14,
                  color: secondaryTextColor,
                ),
                const SizedBox(width: 4),
                Text(
                  hero.lessonText!,
                  style: textTheme.bodyMedium!.copyWith(
                    color: secondaryTextColor,
                  ),
                ),
              ],
            ],
          ),
        ],
        if (_isLoginHero) ...[
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '去登录',
                  style: context.appText.rowTitle.copyWith(color: accentColor),
                ),
                const SizedBox(width: 2),
                Icon(Icons.chevron_right, size: 16, color: accentColor),
              ],
            ),
          ),
        ],
      ],
    );

    if (_isLoginHero) {
      return Semantics(
        button: true,
        label: '登录教务系统查看课程',
        excludeSemantics: true,
        child: InkWell(
          onTap: onLoginTap,
          borderRadius: BorderRadius.circular(12),
          child: body,
        ),
      );
    }
    if (!_isStatusHeroTappable) return body;
    return Semantics(
      button: true,
      label: '查看课表',
      child: InkWell(
        onTap: onOpenSchedule,
        borderRadius: BorderRadius.circular(12),
        child: body,
      ),
    );
  }
}
