package edu.zjxu.jxucampushub.widget

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.view.View
import android.widget.RemoteViews
import edu.zjxu.jxucampushub.MainActivity
import edu.zjxu.jxucampushub.R
import org.json.JSONObject

/**
 * 三种固定尺寸组件的 RemoteViews 渲染（无尺寸自适应：每种尺寸一份独立布局）。
 *
 * 每次渲染都显式写入所有可变属性（可见性 / 文案 / 颜色）：RemoteViews 复用视图，
 * 不写回会残留上一次的状态。
 */
internal object CampusWidgetRenderer {
    private const val MAX_ROWS_MEDIUM = 3
    private const val MAX_ROWS_LARGE = 4
    private const val STALE_TEXT = "数据可能已过期"
    private const val ACTION_SCHEDULE = "schedule.today"

    private class CourseRow(
        val time: String,
        val name: String,
        val location: String,
        val ongoing: Boolean,
    )

    private class Hero(
        val course: String,
        val time: String,
        val location: String,
        /** 无课程名时的状态大字（如「今天没课」）。 */
        val headline: String,
    ) {
        val hasCourse: Boolean get() = course.isNotBlank()
        val titleText: String get() = course.ifBlank { headline }.ifBlank { "今天没课" }
        val metaLines: List<String> get() = listOf(time, location).filter { it.isNotBlank() }
    }

    fun render(
        context: Context,
        kind: CampusWidgetKind,
        widgetId: Int,
        json: JSONObject?,
        stale: Boolean,
    ): RemoteViews = when (kind) {
        CampusWidgetKind.SMALL -> renderSmall(context, json, stale)
        CampusWidgetKind.MEDIUM -> renderMedium(context, json, stale)
        CampusWidgetKind.LARGE -> renderLarge(context, widgetId, json, stale)
    }

    // ---------------------------------------------------------------- small

    private fun renderSmall(context: Context, json: JSONObject?, stale: Boolean): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.campus_widget_small)
        bindClick(context, views, R.id.widget_root, ACTION_SCHEDULE)
        if (json == null) {
            views.setTextViewText(R.id.widget_hero_label, "嘉兴大学")
            views.setTextViewText(R.id.widget_hero_course, "打开 App")
            views.setTextViewText(R.id.widget_hero_meta, "加载校园数据")
            return views
        }
        val hero = parseHero(json)
        // 标签恒为静态「下一节课」：headline 里的相对时间（「42 分钟后上课」）在
        // 前台推送之间会变旧，不在组件上展示。过期时改提示过期。
        views.setTextViewText(R.id.widget_hero_label, if (stale) "下一节课 · 过期" else "下一节课")
        views.setTextViewText(R.id.widget_hero_course, hero.titleText)
        views.setTextViewText(R.id.widget_hero_meta, hero.metaLines.joinToString("\n"))
        return views
    }

    // --------------------------------------------------------------- medium

    private fun renderMedium(context: Context, json: JSONObject?, stale: Boolean): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.campus_widget_medium)
        bindClick(context, views, R.id.widget_root, ACTION_SCHEDULE)
        val rowIds = intArrayOf(R.id.widget_today_1, R.id.widget_today_2, R.id.widget_today_3)
        for (id in rowIds) bindClick(context, views, id, ACTION_SCHEDULE)

        if (json == null) {
            views.setTextViewText(R.id.widget_title, "今日课表")
            views.setTextViewText(R.id.widget_week, "")
            fillRows(context, views, rowIds, emptyList(), "打开 App 加载校园数据", null)
            return views
        }
        views.setTextViewText(R.id.widget_title, scheduleTitle(json))
        views.setTextViewText(R.id.widget_week, if (stale) STALE_TEXT else json.text("weekLabel"))

        val hero = parseHero(json)
        val rows = rowsWithHero(json, hero, MAX_ROWS_MEDIUM)
        if (rows.isEmpty()) {
            // 没有课程行：Hero 文案（如「今天没课」）占第一行，时间 / 地点占第二行。
            fillRows(
                context,
                views,
                rowIds,
                emptyList(),
                hero.titleText,
                hero.metaLines.joinToString(" · "),
            )
        } else {
            fillRows(context, views, rowIds, rows, null, null)
        }
        return views
    }

    // ---------------------------------------------------------------- large

    private fun renderLarge(
        context: Context,
        widgetId: Int,
        json: JSONObject?,
        stale: Boolean,
    ): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.campus_widget_large)
        bindClick(context, views, R.id.widget_root, ACTION_SCHEDULE)
        bindClick(context, views, R.id.widget_hero, ACTION_SCHEDULE)
        bindClick(context, views, R.id.widget_balance, "campus-card.open")
        bindClick(context, views, R.id.widget_electricity, "electricity.open")
        bindClick(context, views, R.id.widget_exam, "exam.open")
        bindClick(context, views, R.id.widget_notice, "notice.inbox")
        val rowIds = intArrayOf(
            R.id.widget_today_1,
            R.id.widget_today_2,
            R.id.widget_today_3,
            R.id.widget_today_4,
        )
        for (id in rowIds) bindClick(context, views, id, ACTION_SCHEDULE)

        views.setTextViewText(R.id.widget_title, "校园总览")
        if (json == null) {
            views.setTextViewText(R.id.widget_week, "")
            views.setTextViewText(R.id.widget_hero_course, "嘉兴大学")
            views.setTextViewText(R.id.widget_hero_meta, "打开 App 加载校园数据")
            views.setViewVisibility(R.id.widget_today_container, View.GONE)
            views.setViewVisibility(R.id.widget_assets, View.GONE)
            views.setViewVisibility(R.id.widget_exam, View.GONE)
            views.setViewVisibility(R.id.widget_notice, View.GONE)
            return views
        }
        views.setTextViewText(R.id.widget_week, if (stale) STALE_TEXT else json.text("weekLabel"))

        val hero = parseHero(json)
        views.setTextViewText(R.id.widget_hero_course, hero.titleText)
        views.setTextViewText(R.id.widget_hero_meta, hero.metaLines.joinToString(" · "))

        // Hero 已单独展示，只去掉今日行里那一行 Hero 本身；同名的其他课程块保留。
        val allRows = parseRows(json)
        val heroIndex = heroRowIndex(allRows, hero)
        val rows = allRows
            .filterIndexed { index, _ -> index != heroIndex }
            .take(MAX_ROWS_LARGE)
        views.setViewVisibility(
            R.id.widget_today_container,
            if (rows.isEmpty()) View.GONE else View.VISIBLE,
        )
        fillRows(context, views, rowIds, rows, null, null)

        // 每实例显示开关（配置页写入）：只影响该实例的一卡通 / 电费 / 通知条目。
        val config = CampusWidgetConfigStore.load(context, widgetId)
        renderAssets(views, json, config)

        val examName = json.text("nextExamCourseName")
        if (examName.isNotBlank()) {
            views.setViewVisibility(R.id.widget_exam, View.VISIBLE)
            views.setTextViewText(
                R.id.widget_exam,
                buildMeta("考试 $examName", json.text("nextExamTimeText")),
            )
        } else {
            views.setViewVisibility(R.id.widget_exam, View.GONE)
        }

        val unread = json.optInt("unreadNoticeCount", 0)
        val showNotice = config.showNotice && unread > 0
        views.setViewVisibility(R.id.widget_notice, if (showNotice) View.VISIBLE else View.GONE)
        if (showNotice) views.setTextViewText(R.id.widget_notice, "未读通知 $unread 条")
        return views
    }

    private fun renderAssets(
        views: RemoteViews,
        json: JSONObject,
        config: CampusWidgetConfigStore.Config,
    ) {
        val hasBalance = config.showBalance && json.optBoolean("hasCampusCardData") &&
            json.text("campusCardBalance").isNotBlank()
        val hasElectricity = config.showElectricity && json.optBoolean("hasElectricityData") &&
            json.text("dormElectricity").isNotBlank()
        views.setViewVisibility(
            R.id.widget_assets,
            if (hasBalance || hasElectricity) View.VISIBLE else View.GONE,
        )
        // 单项关闭时隐藏该子视图（weight 行会让另一项占满整行），而不是留空位。
        views.setViewVisibility(R.id.widget_balance, if (hasBalance) View.VISIBLE else View.GONE)
        views.setTextViewText(
            R.id.widget_balance,
            if (hasBalance) "一卡通 ${withUnit(json.text("campusCardBalance"), "元")}" else "",
        )
        views.setViewVisibility(
            R.id.widget_electricity,
            if (hasElectricity) View.VISIBLE else View.GONE,
        )
        views.setTextViewText(
            R.id.widget_electricity,
            if (hasElectricity) "电费 ${withUnit(json.text("dormElectricity"), "度")}" else "",
        )
    }

    // -------------------------------------------------------------- helpers

    private fun parseHero(json: JSONObject) = Hero(
        course = json.text("heroCourseName"),
        time = json.text("heroTimeText"),
        location = json.text("heroLocationText"),
        headline = json.text("heroHeadline"),
    )

    private fun parseRows(json: JSONObject): List<CourseRow> {
        val array = json.optJSONArray("todayCourses") ?: return emptyList()
        val rows = ArrayList<CourseRow>(array.length())
        for (i in 0 until array.length()) {
            val row = array.optJSONObject(i) ?: continue
            val name = row.text("courseName")
            if (name.isBlank()) continue
            rows += CourseRow(
                time = row.text("timeText"),
                name = name,
                location = row.text("locationText"),
                ongoing = row.optBoolean("isOngoing"),
            )
        }
        return rows
    }

    /**
     * Hero 对应的今日行下标：优先「课程名 + 时间文案」都匹配，没有时间匹配才退回第一条
     * 同名行；没有 Hero 课程或找不到返回 -1。
     */
    private fun heroRowIndex(rows: List<CourseRow>, hero: Hero): Int {
        if (!hero.hasCourse) return -1
        val exact = rows.indexOfFirst { it.name == hero.course && it.time == hero.time }
        return if (exact >= 0) exact else rows.indexOfFirst { it.name == hero.course }
    }

    /**
     * 课程行；Hero 课程若不在今日行里（折叠 / 次日预览形态）则补在最前，避免丢掉
     * 最重要的一节课。
     */
    private fun rowsWithHero(json: JSONObject, hero: Hero, limit: Int): List<CourseRow> {
        val rows = parseRows(json)
        val withHero = if (hero.hasCourse && heroRowIndex(rows, hero) < 0) {
            listOf(CourseRow(hero.time, hero.course, hero.location, false)) + rows
        } else {
            rows
        }
        return withHero.take(limit)
    }

    /** 「今天」（或缺省）→「今日课表」，其他如「明天」→「明天课表」。 */
    private fun scheduleTitle(json: JSONObject): String {
        return when (val title = json.text("todayTitle")) {
            "", "今天" -> "今日课表"
            else -> "${title}课表"
        }
    }

    /**
     * 写入课程行；[rows] 为空时 [emptyPrimary] 占第一行、[emptySecondary] 占第二行。
     * 每行显式写颜色：进行中用强调色，其余次级色。
     */
    private fun fillRows(
        context: Context,
        views: RemoteViews,
        rowIds: IntArray,
        rows: List<CourseRow>,
        emptyPrimary: String?,
        emptySecondary: String?,
    ) {
        val secondary = context.getColor(R.color.campus_widget_text_secondary)
        val accent = context.getColor(R.color.campus_widget_accent)
        for (i in rowIds.indices) {
            val id = rowIds[i]
            val row = rows.getOrNull(i)
            val text: String? = when {
                row != null -> formatRow(row)
                rows.isEmpty() && i == 0 -> emptyPrimary
                rows.isEmpty() && i == 1 -> emptySecondary
                else -> null
            }
            if (text.isNullOrBlank()) {
                views.setViewVisibility(id, View.GONE)
                continue
            }
            views.setViewVisibility(id, View.VISIBLE)
            views.setTextViewText(id, text)
            views.setTextColor(id, if (row?.ongoing == true) accent else secondary)
        }
    }

    private fun formatRow(row: CourseRow): String {
        val head = if (row.ongoing) "● " else ""
        val main = listOf(row.time, row.name).filter { it.isNotBlank() }.joinToString("  ")
        return if (row.location.isBlank()) "$head$main" else "$head$main · ${row.location}"
    }

    /**
     * JSON null / 缺失一律视为空串。
     *
     * `optString` 会把 JSON null 读成字面量 "null"（Dart 侧 `Map<String, Object?>`
     * 的可空字段序列化后就是 JSON null），屏幕上会直接显示 "null"。
     */
    private fun JSONObject.text(key: String): String {
        if (isNull(key)) return ""
        val value = optString(key)
        return if (value == "null") "" else value
    }

    private fun buildMeta(primary: String, secondary: String): String {
        return listOf(primary, secondary).filter { it.isNotBlank() }.joinToString(" · ")
    }

    /**
     * 只在纯数字后补单位；已带单位（¥ / 元 / 度 等）或非数字文本原样返回，
     * 避免「¥32.50 元」这类重复标注。
     */
    private fun withUnit(value: String, unit: String): String {
        return if (PURE_NUMBER.matches(value)) "$value $unit" else value
    }

    private val PURE_NUMBER = Regex("-?\\d+(\\.\\d+)?")

    private fun bindClick(context: Context, views: RemoteViews, viewId: Int, actionId: String) {
        val intent = Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            data = Uri.parse("jxucampushub://action/$actionId")
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP,
            )
        }
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags = flags or PendingIntent.FLAG_IMMUTABLE
        }
        val pending = PendingIntent.getActivity(context, actionId.hashCode(), intent, flags)
        views.setOnClickPendingIntent(viewId, pending)
    }
}
