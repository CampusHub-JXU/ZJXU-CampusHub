package edu.zjxu.jxucampushub.widget

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.res.ColorStateList
import android.net.Uri
import android.os.Build
import android.view.View
import android.widget.RemoteViews
import edu.zjxu.jxucampushub.MainActivity
import edu.zjxu.jxucampushub.R
import edu.zjxu.jxucampushub.widget.CampusWidgetTimeLogic.Course
import edu.zjxu.jxucampushub.widget.CampusWidgetTimeLogic.FlowItem
import edu.zjxu.jxucampushub.widget.CampusWidgetTimeLogic.MediumKind
import java.time.LocalDate
import java.time.LocalDateTime

/**
 * 三种固定尺寸组件的 RemoteViews 渲染（A · Swiss 排版，docs/desktop-widget-v2.md §7）。
 *
 * 渲染时按**设备时钟**（[LocalDateTime] now）从快照 v2 里挑「进行中 / 下一节 / 之后几天」，
 * 所以 App 不打开、快照不更新，组件也不会显示过时的课；换内容的时刻由 [CampusWidgetScheduler]
 * 的闹钟推进。课程行数按桌面给这个实例的**实际高度**决定（不放大字号，只加行），
 * 自上而下排列，没课的日子直接跳过，有课的日子带「周一 10/19」小标题。
 *
 * RemoteViews 会 reapply 复用上一次的视图：每次渲染都显式写入所有可变属性
 * （可见性 / 文案 / 颜色 / 进度 / 着色），不写回会残留上一次的状态。
 */
internal object CampusWidgetRenderer {
    private const val ACTION_SCHEDULE = "schedule.today"
    private const val ACTION_EXAM = "exam.open"
    private const val ACTION_CARD = "campus-card.open"
    private const val ACTION_ELECTRICITY = "electricity.open"
    private const val ACTION_NOTICE = "notice.inbox"

    /** requestCode = widgetId * 16 + 这里的下标：同一实例不同动作、不同实例同一动作都互不相同。 */
    private val ACTIONS = listOf(
        ACTION_SCHEDULE, ACTION_EXAM, ACTION_CARD, ACTION_ELECTRICITY, ACTION_NOTICE,
    )

    /** 资产 / 通知区块超过这么久没更新才标「N 小时前」；课程按绝对时间自走，不会「过期」。 */
    private const val STALE_AFTER_HOURS = 24L

    private const val TEXT_OPEN_APP = "点按打开 App"
    private const val TEXT_NO_DATA = "打开 App 加载校园数据"
    private const val TEXT_OLD_SCHEMA = "打开 App 更新组件"
    private const val TEXT_OUT_OF_RANGE = "打开 App 更新课表"
    private const val TEXT_NO_COURSE_SOON = "未来 7 天没有课程"

    // 纵向预算（dp）：布局里固定部分的估算高度，剩余高度用来排课程行。
    private const val MEDIUM_FIXED_DP = 28 + 22 + 6 // 上下内边距 + 标题行 + 与首行间距
    private const val LARGE_FIXED_DP = 36 + 14 + 6 + 34 + 3 + 17 // 内边距 + 标签 + 课程名 + 元信息
    private const val LARGE_PROGRESS_DP = 14
    private const val LARGE_NEXT_LABEL_DP = 26
    private const val LARGE_TILES_DP = 8 + 76
    private const val LARGE_TILES_NO_EXAM_DP = 8 + 62
    private const val LARGE_NOTICE_DP = 8 + 18
    private const val LARGE_SAFETY_DP = 10
    private const val SMALL_ONE_NEXT_DP = 150
    private const val SMALL_WIDE_DP = 150
    private const val SMALL_TWO_NEXT_DP = 175

    /** 课表区的整体状态（先于具体课程判断）。 */
    private enum class ScheduleState { PLACEHOLDER, EMPTY_STATE, OUT_OF_RANGE, OK }

    private class Ctx(
        val context: Context,
        val widgetId: Int,
        val snapshot: CampusWidgetSnapshot?,
        val generatedAtMs: Long,
        val now: LocalDateTime,
        val nowMs: Long,
        val palette: WidgetPalette,
        /** 桌面当前给这个实例的高度 / 宽度（dp）。 */
        val heightDp: Int,
        val widthDp: Int,
    ) {
        val state: ScheduleState = when {
            snapshot == null || !snapshot.isCurrentSchema -> ScheduleState.PLACEHOLDER
            snapshot.emptyState.isNotBlank() -> ScheduleState.EMPTY_STATE
            snapshot.days.none { it.date == now.toLocalDate() } -> ScheduleState.OUT_OF_RANGE
            else -> ScheduleState.OK
        }

        /** 占位 / 空状态 / 快照过旧时课表区显示的整句提示。 */
        val stateText: String
            get() = when (state) {
                ScheduleState.PLACEHOLDER ->
                    if (snapshot == null) TEXT_NO_DATA else TEXT_OLD_SCHEMA
                ScheduleState.EMPTY_STATE -> emptyText(snapshot!!)
                ScheduleState.OUT_OF_RANGE -> TEXT_OUT_OF_RANGE
                ScheduleState.OK -> ""
            }

        val days get() = snapshot?.days.orEmpty()
    }

    fun render(
        context: Context,
        kind: CampusWidgetKind,
        widgetId: Int,
        snapshot: CampusWidgetSnapshot?,
        generatedAtMs: Long,
        now: LocalDateTime,
        nowMs: Long,
        palette: WidgetPalette,
        heightDp: Int,
        widthDp: Int,
    ): RemoteViews {
        val ctx = Ctx(context, widgetId, snapshot, generatedAtMs, now, nowMs, palette, heightDp, widthDp)
        return when (kind) {
            CampusWidgetKind.SMALL -> renderSmall(ctx)
            CampusWidgetKind.MEDIUM -> renderMedium(ctx)
            CampusWidgetKind.LARGE -> renderLarge(ctx)
        }
    }

    // ---------------------------------------------------------------- small

    private fun renderSmall(c: Ctx): RemoteViews {
        val views = RemoteViews(c.context.packageName, R.layout.campus_widget_small)
        bindClick(c, views, android.R.id.background, ACTION_SCHEDULE)

        var label = "课表"
        var labelAccent = false
        var title = ""
        var line1 = ""
        var line1Accent = false
        var line2 = ""
        var nextLines: List<String> = emptyList()

        if (c.state != ScheduleState.OK) {
            if (c.state == ScheduleState.PLACEHOLDER) label = "嘉兴大学"
            title = c.stateText
            if (c.state == ScheduleState.EMPTY_STATE) {
                line1 = TEXT_OPEN_APP
                line1Accent = true
            }
        } else {
            val hero = CampusWidgetTimeLogic.hero(c.days, c.now)
            if (hero == null) {
                title = "近期没课"
                line1 = TEXT_NO_COURSE_SOON
            } else {
                val course = hero.course
                val today = c.now.toLocalDate()
                label = when {
                    // 2x2 够宽（>= 150dp）写「进行中 · 11:55 下课」，窄了只写「进行中 · 11:55」。
                    hero.ongoing -> if (c.widthDp >= SMALL_WIDE_DP) {
                        "进行中 · ${CampusWidgetTimeLogic.hhmm(course.end)} 下课"
                    } else {
                        "进行中 · ${CampusWidgetTimeLogic.hhmm(course.end)}"
                    }
                    hero.date == today -> "下一节 ${CampusWidgetTimeLogic.hhmm(course.start)}"
                    else -> "${CampusWidgetTimeLogic.dayLabel(today, hero.date)} " +
                        CampusWidgetTimeLogic.hhmm(course.start)
                }
                labelAccent = hero.ongoing
                title = course.name
                line1 = timeText(course)
                line2 = course.location
                nextLines = smallNextLines(c, course)
            }
        }

        views.setTextViewText(R.id.widget_hero_label, label)
        val sp = c.palette
        textColor(views, sp, R.id.widget_hero_label, if (labelAccent) sp.accent else sp.secondary)
        views.setTextViewText(R.id.widget_hero_course, title)
        setLine(views, sp, R.id.widget_hero_time, line1, if (line1Accent) sp.accent else sp.secondary)
        setLine(views, sp, R.id.widget_hero_location, line2, sp.secondary, dynamic = false)
        setLine(views, sp, R.id.widget_hero_next_1, nextLines.getOrNull(0).orEmpty(), sp.secondary, dynamic = false)
        setLine(views, sp, R.id.widget_hero_next_2, nextLines.getOrNull(1).orEmpty(), sp.secondary, dynamic = false)
        return views
    }

    /**
     * 小组件在高度够时，在当前课下面补「接下来」的课（同一天只写开始时间，
     * 之后的日子带「周二 08:00」），高度 >= 150dp 补一行，>= 175dp 补两行。
     */
    private fun smallNextLines(c: Ctx, hero: Course): List<String> {
        val count = when {
            c.heightDp >= SMALL_TWO_NEXT_DP -> 2
            c.heightDp >= SMALL_ONE_NEXT_DP -> 1
            else -> 0
        }
        if (count == 0) return emptyList()
        val today = c.now.toLocalDate()
        val lines = ArrayList<String>(count)
        for (item in CampusWidgetTimeLogic.flow(c.days, c.now, hero, hero.start.toLocalDate())) {
            val course = item.course ?: continue
            val day = course.start.toLocalDate()
            val time = CampusWidgetTimeLogic.hhmm(course.start)
            val prefix = if (day == hero.start.toLocalDate()) "" else
                "${CampusWidgetTimeLogic.dayLabel(today, day)} "
            lines += "$prefix$time ${course.name}"
            if (lines.size >= count) break
        }
        return lines
    }

    // --------------------------------------------------------------- medium

    private fun renderMedium(c: Ctx): RemoteViews {
        val views = RemoteViews(c.context.packageName, R.layout.campus_widget_medium)
        bindClick(c, views, android.R.id.background, ACTION_SCHEDULE)
        bindClick(c, views, R.id.widget_message, ACTION_SCHEDULE)

        var right = ""
        var items: List<FlowItem> = emptyList()
        var message = ""
        var cta = ""

        if (c.state != ScheduleState.OK) {
            message = c.stateText
            if (c.state == ScheduleState.EMPTY_STATE) cta = TEXT_OPEN_APP
        } else {
            val plan = CampusWidgetTimeLogic.mediumPlan(c.days, c.now)
            val today = c.now.toLocalDate()
            val holiday = plan.today?.holidayName.orEmpty()
            // 状态放标题行右侧（小字）；正文永远是课程行，不只显示一句状态。
            when (plan.kind) {
                MediumKind.TODAY ->
                    right = CampusWidgetTimeLogic.weekOnly(plan.today?.weekLabel.orEmpty())
                MediumKind.OVER -> right = "今天的课已结束"
                MediumKind.NONE ->
                    right = if (holiday.isBlank()) "今天没课" else "今天没课 · $holiday"
                MediumKind.UNKNOWN -> message = TEXT_OUT_OF_RANGE
            }
            if (plan.kind != MediumKind.UNKNOWN) {
                // 今天余下的课不加标题；之后每个有课的日子一组，带「周一 10/19」小标题。
                val all = CampusWidgetTimeLogic.flow(
                    c.days,
                    c.now,
                    null,
                    if (plan.kind == MediumKind.TODAY) today else null,
                )
                // 预算至少一行：桌面报告的高度异常小时也不能把「有课」显示成「没课」。
                items = CampusWidgetTimeLogic.fit(
                    all,
                    maxOf(c.heightDp - MEDIUM_FIXED_DP, CampusWidgetTimeLogic.COURSE_ROW_DP),
                    CampusWidgetSlotIds.MEDIUM.size,
                )
                if (all.isEmpty()) message = TEXT_NO_COURSE_SOON
            }
        }

        views.setTextViewText(R.id.widget_title, "今日课表")
        views.setTextViewText(R.id.widget_week, right)
        views.setViewVisibility(R.id.widget_week, if (right.isBlank()) View.GONE else View.VISIBLE)

        val showRows = items.isNotEmpty()
        views.setViewVisibility(R.id.widget_rows, if (showRows) View.VISIBLE else View.GONE)
        views.setViewVisibility(R.id.widget_message, if (showRows) View.GONE else View.VISIBLE)
        fillSlots(c, views, CampusWidgetSlotIds.MEDIUM, items, c.now.toLocalDate())
        views.setTextViewText(R.id.widget_message_primary, message)
        views.setViewVisibility(R.id.widget_message_secondary, View.GONE)
        setLine(views, c.palette, R.id.widget_message_cta, cta, c.palette.accent)
        return views
    }

    /**
     * 把课程 / 日期标题项写进槽位（自上而下，不居中）；多余槽位隐藏。
     * 有强调底槽位（中组件）里正在进行的课：整行强调底 + 强调色加粗。
     */
    private fun fillSlots(
        c: Ctx,
        views: RemoteViews,
        slots: List<SlotIds>,
        items: List<FlowItem>,
        today: LocalDate,
    ) {
        val p = c.palette
        for (i in slots.indices) {
            val ids = slots[i]
            val item = items.getOrNull(i)
            if (item == null) {
                views.setViewVisibility(ids.container, View.GONE)
                continue
            }
            views.setViewVisibility(ids.container, View.VISIBLE)
            val labelDate = item.labelDate
            if (labelDate != null) {
                views.setViewVisibility(ids.course, View.GONE)
                if (ids.bg != 0) views.setViewVisibility(ids.bg, View.GONE)
                views.setViewVisibility(ids.label, View.VISIBLE)
                views.setTextViewText(ids.label, CampusWidgetTimeLogic.dateLabel(today, labelDate))
                textColor(views, p, ids.label, p.secondary, dynamic = false)
                continue
            }
            val course = item.course ?: continue
            views.setViewVisibility(ids.label, View.GONE)
            views.setViewVisibility(ids.course, View.VISIBLE)
            val ongoing = ids.bg != 0 && !c.now.isBefore(course.start) && c.now.isBefore(course.end)
            if (ids.bg != 0) {
                if (ongoing) {
                    tintImage(views, ids.bg, p)
                    views.setViewVisibility(ids.bg, View.VISIBLE)
                } else {
                    views.setViewVisibility(ids.bg, View.GONE)
                }
            }
            views.setTextViewText(ids.time, timeText(course))
            // 有强调底的槽位（中组件）里颜色随「进行中」切换；总览「接下来」从不切换。
            val toggles = ids.bg != 0
            textColor(views, p, ids.time, if (ongoing) p.accent else p.secondary, dynamic = toggles)
            views.setTextViewText(ids.name, course.name)
            textColor(views, p, ids.name, p.primary, dynamic = false)
            views.setViewVisibility(ids.name, if (ongoing) View.GONE else View.VISIBLE)
            if (ids.nameOn != 0) {
                views.setTextViewText(ids.nameOn, course.name)
                textColor(views, p, ids.nameOn, p.accent)
                views.setViewVisibility(ids.nameOn, if (ongoing) View.VISIBLE else View.GONE)
            }
            views.setTextViewText(ids.location, course.location)
            textColor(views, p, ids.location, if (ongoing) p.accent else p.secondary, dynamic = toggles)
        }
    }

    // ---------------------------------------------------------------- large

    private fun renderLarge(c: Ctx): RemoteViews {
        val views = RemoteViews(c.context.packageName, R.layout.campus_widget_large)
        val p = c.palette
        bindClick(c, views, android.R.id.background, ACTION_SCHEDULE)
        bindClick(c, views, R.id.widget_hero, ACTION_SCHEDULE)
        bindClick(c, views, R.id.widget_next, ACTION_SCHEDULE)
        bindClick(c, views, R.id.widget_tile_balance, ACTION_CARD)
        bindClick(c, views, R.id.widget_tile_electricity, ACTION_ELECTRICITY)
        bindClick(c, views, R.id.widget_tile_exam, ACTION_EXAM)
        bindClick(c, views, R.id.widget_notice, ACTION_NOTICE)

        val snapshot = c.snapshot
        val today = c.now.toLocalDate()
        val tiles = largeTiles(c)

        var label = "校园总览"
        var labelAccent = false
        var week = ""
        var heroText = ""
        var meta = ""
        var metaAccent = false
        var progress = -1
        var items: List<FlowItem> = emptyList()

        if (c.state == ScheduleState.PLACEHOLDER) {
            label = "嘉兴大学"
            heroText = c.stateText
        } else {
            week = CampusWidgetTimeLogic.weekOnly(
                c.days.firstOrNull { it.date == today }?.weekLabel
                    ?: snapshot?.weekLabel.orEmpty(),
            )
            if (c.state != ScheduleState.OK) {
                label = "课表"
                heroText = c.stateText
                if (c.state == ScheduleState.EMPTY_STATE) {
                    meta = TEXT_OPEN_APP
                    metaAccent = true
                }
            } else {
                val hero = CampusWidgetTimeLogic.hero(c.days, c.now)
                if (hero == null) {
                    label = "课表"
                    heroText = "近期没课"
                    meta = TEXT_NO_COURSE_SOON
                } else {
                    val course = hero.course
                    label = when {
                        hero.ongoing -> "进行中 · ${CampusWidgetTimeLogic.hhmm(course.end)} 下课"
                        hero.date == today -> "下一节 · ${CampusWidgetTimeLogic.hhmm(course.start)} 上课"
                        else -> "${CampusWidgetTimeLogic.dayLabel(today, hero.date)} · " +
                            "${CampusWidgetTimeLogic.hhmm(course.start)} 上课"
                    }
                    labelAccent = hero.ongoing
                    heroText = course.name
                    meta = listOf(timeText(course), course.location)
                        .filter { it.isNotBlank() }
                        .joinToString(" · ")
                    if (hero.ongoing) progress = CampusWidgetTimeLogic.progressPercent(course, c.now)
                    // 与组件顶部同一天的课不加标题，之后的日子各带日期小标题；
                    // 剩余高度（扣掉固定部分、底部三格与通知）全部用来排课程行。
                    val all = CampusWidgetTimeLogic.flow(c.days, c.now, course, hero.date)
                    var budget = c.heightDp - LARGE_FIXED_DP - LARGE_NEXT_LABEL_DP - LARGE_SAFETY_DP
                    if (progress >= 0) budget -= LARGE_PROGRESS_DP
                    if (tiles.any) {
                        budget -= if (tiles.exam) LARGE_TILES_DP else LARGE_TILES_NO_EXAM_DP
                    }
                    if (tiles.notice) budget -= LARGE_NOTICE_DP
                    items = CampusWidgetTimeLogic.fit(
                        all,
                        budget,
                        CampusWidgetSlotIds.LARGE_NEXT.size,
                    )
                }
            }
        }

        views.setTextViewText(R.id.widget_label, label)
        textColor(views, p, R.id.widget_label, if (labelAccent) p.accent else p.secondary)
        views.setTextViewText(R.id.widget_week, week)
        views.setViewVisibility(R.id.widget_week, if (week.isBlank()) View.GONE else View.VISIBLE)
        views.setTextViewText(R.id.widget_hero_course, heroText)
        setLine(views, p, R.id.widget_hero_meta, meta, if (metaAccent) p.accent else p.secondary)

        renderProgress(views, progress, p)

        views.setViewVisibility(R.id.widget_next, if (items.isEmpty()) View.GONE else View.VISIBLE)
        fillSlots(c, views, CampusWidgetSlotIds.LARGE_NEXT, items, today)

        renderTilesAndNotice(c, views, tiles)
        return views
    }

    /**
     * 4dp 进度条（[percent] < 0 = 不显示）。API 31+ 用 `setProgressTintList` 按主题色着色；
     * 旧系统 RemoteViews 没有给 ProgressBar 运行时着色的办法，沿用 drawable 里的资源强调色。
     */
    private fun renderProgress(views: RemoteViews, percent: Int, palette: WidgetPalette) {
        if (percent < 0) {
            views.setViewVisibility(R.id.widget_progress, View.GONE)
            return
        }
        views.setViewVisibility(R.id.widget_progress, View.VISIBLE)
        views.setProgressBar(R.id.widget_progress, 100, percent, false)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            views.setColorStateList(
                R.id.widget_progress,
                "setProgressTintList",
                ColorStateList.valueOf(palette.accent.light),
                ColorStateList.valueOf(palette.accent.night),
            )
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            views.setColorStateList(
                R.id.widget_progress,
                "setProgressTintList",
                ColorStateList.valueOf(palette.accent.pick(palette.night)),
            )
        }
    }

    /** 总览底部各块是否显示（先算出来，课程行预算要扣掉它们占的高度）。 */
    private class Tiles(
        val balance: Boolean,
        val electricity: Boolean,
        val exam: Boolean,
        val notice: Boolean,
    ) {
        val any: Boolean get() = balance || electricity || exam
    }

    private fun largeTiles(c: Ctx): Tiles {
        val snapshot = c.snapshot
        if (snapshot == null || !snapshot.isCurrentSchema) return Tiles(false, false, false, false)
        val config = CampusWidgetConfigStore.load(c.context, c.widgetId)
        return Tiles(
            balance = config.showBalance && snapshot.campusCard.shown,
            electricity = config.showElectricity && snapshot.electricity.shown,
            exam = CampusWidgetTimeLogic.nearestExam(snapshot.exams, c.now) != null,
            notice = config.showNotice && snapshot.unreadNotices > 0,
        )
    }

    private fun renderTilesAndNotice(c: Ctx, views: RemoteViews, tiles: Tiles) {
        val p = c.palette
        val snapshot = c.snapshot
        val staleHours = staleHours(c.generatedAtMs, c.nowMs)
        val ageText = staleHours?.let { "$it 小时前" }.orEmpty()

        // 一卡通
        views.setViewVisibility(R.id.widget_tile_balance, vis(tiles.balance))
        val card = snapshot?.campusCard
        if (tiles.balance && card != null) {
            views.setTextViewText(R.id.widget_tile_balance_value, withPrefix(card.value, "¥"))
            textColor(views, p, R.id.widget_tile_balance_value, if (card.low) p.warn else p.primary)
            setLine(views, p, R.id.widget_tile_balance_sub, ageText, p.secondary, dynamic = false)
        }

        // 电费
        views.setViewVisibility(R.id.widget_tile_electricity, vis(tiles.electricity))
        val electricity = snapshot?.electricity
        if (tiles.electricity && electricity != null) {
            views.setTextViewText(R.id.widget_tile_electricity_value, electricity.value)
            textColor(
                views,
                p,
                R.id.widget_tile_electricity_value,
                if (electricity.low) p.warn else p.primary,
            )
            setLine(views, p, R.id.widget_tile_electricity_sub, ageText, p.secondary, dynamic = false)
        }

        // 考试倒计时（最近一场未结束的考试，按自然日计算；午夜重渲后自动正确）
        views.setViewVisibility(R.id.widget_tile_exam, vis(tiles.exam))
        val exam = if (tiles.exam && snapshot != null) {
            CampusWidgetTimeLogic.nearestExam(snapshot.exams, c.now)
        } else {
            null
        }
        if (exam != null) {
            val days = CampusWidgetTimeLogic.examCountdownDays(exam, c.now)
            views.setTextViewText(R.id.widget_tile_exam_value, if (days == 0) "今天" else "$days 天")
            textColor(views, p, R.id.widget_tile_exam_value, p.accent)
            setLine(views, p, R.id.widget_tile_exam_sub, exam.name, p.secondary, dynamic = false)
        }

        views.setViewVisibility(R.id.widget_tiles, vis(tiles.any))

        // 未读通知
        views.setViewVisibility(R.id.widget_notice, vis(tiles.notice))
        if (tiles.notice && snapshot != null) {
            val unread = snapshot.unreadNotices
            val text = if (ageText.isEmpty()) "$unread 条未读通知" else "$unread 条未读通知 · $ageText"
            views.setTextViewText(R.id.widget_notice, text)
            textColor(views, p, R.id.widget_notice, p.accent)
        }
    }

    // -------------------------------------------------------------- helpers

    private fun emptyText(snapshot: CampusWidgetSnapshot): String {
        if (snapshot.emptyStateText.isNotBlank()) return snapshot.emptyStateText
        return when (snapshot.emptyState) {
            "notLoggedIn" -> "登录教务后显示课表"
            "noCache" -> "打开 App 加载课表"
            "beforeSemester" -> "学期尚未开始"
            "afterSemester" -> "本学期已结束"
            else -> "暂无课表"
        }
    }

    private fun timeText(course: Course): String =
        course.timeText.ifBlank {
            "${CampusWidgetTimeLogic.hhmm(course.start)}-${CampusWidgetTimeLogic.hhmm(course.end)}"
        }

    /** 超过 [STALE_AFTER_HOURS] 小时没更新返回已过小时数；没有记录 / 新鲜返回 null。 */
    private fun staleHours(generatedAtMs: Long, nowMs: Long): Long? {
        if (generatedAtMs <= 0L) return null
        val hours = (nowMs - generatedAtMs) / 3_600_000L
        return if (hours >= STALE_AFTER_HOURS) hours else null
    }

    private fun vis(visible: Boolean) = if (visible) View.VISIBLE else View.GONE

    /**
     * 写文字颜色。API 34+ 用 `setColorInt(notNight, night)` 双值重载，桌面深浅色切换时
     * launcher 自己换值（静态颜色也写，避免旧版本遗留的烘焙色残留）；API 34 以下只能按渲染时的
     * 深浅色取一个值，且只对会随状态切换的颜色（[dynamic]）写，其余留给 XML `@color`
     * 由 values-night 自动跟随。
     */
    private fun textColor(
        views: RemoteViews,
        palette: WidgetPalette,
        id: Int,
        color: Duo,
        dynamic: Boolean = true,
    ) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            views.setColorInt(id, "setTextColor", color.light, color.night)
        } else if (dynamic) {
            views.setTextColor(id, color.pick(palette.night))
        }
    }

    /** 文本为空则隐藏，否则显示并写颜色（视图复用，颜色也必须每次写）。 */
    private fun setLine(
        views: RemoteViews,
        palette: WidgetPalette,
        id: Int,
        text: String,
        color: Duo,
        dynamic: Boolean = true,
    ) {
        if (text.isBlank()) {
            views.setViewVisibility(id, View.GONE)
            return
        }
        views.setViewVisibility(id, View.VISIBLE)
        views.setTextViewText(id, text)
        textColor(views, palette, id, color, dynamic)
    }

    /**
     * 给「进行中」行的强调底 ImageView 着色（白色圆角形状，不用 `setBackgroundColor`，会丢圆角）：
     * API 34+ 用 `setImageTintList` 的浅 / 深双值（颜色自带 8% / 14% 透明度，SRC_IN 叠到形状上）；
     * 以下用 `setColorFilter(rgb)` + `setImageAlpha`，按渲染时的深浅色取值。
     */
    private fun tintImage(views: RemoteViews, id: Int, palette: WidgetPalette) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            views.setColorStateList(
                id,
                "setImageTintList",
                ColorStateList.valueOf(palette.tint.light),
                ColorStateList.valueOf(palette.tint.night),
            )
            views.setInt(id, "setImageAlpha", 255)
        } else {
            views.setInt(id, "setColorFilter", palette.tintRgb)
            views.setInt(id, "setImageAlpha", palette.tintAlpha)
        }
    }

    /** 只在纯数字前补前缀；已带符号 / 单位的文本原样返回。 */
    private fun withPrefix(value: String, prefix: String): String =
        if (PURE_NUMBER.matches(value)) "$prefix$value" else value

    private val PURE_NUMBER = Regex("-?\\d+(\\.\\d+)?")

    private fun bindClick(c: Ctx, views: RemoteViews, viewId: Int, actionId: String) {
        val context = c.context
        val intent = Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            data = Uri.parse("jxucampushub://action/$actionId")
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP,
            )
        }
        val requestCode = c.widgetId * 16 + ACTIONS.indexOf(actionId).coerceAtLeast(0)
        val pending = PendingIntent.getActivity(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        views.setOnClickPendingIntent(viewId, pending)
    }
}
