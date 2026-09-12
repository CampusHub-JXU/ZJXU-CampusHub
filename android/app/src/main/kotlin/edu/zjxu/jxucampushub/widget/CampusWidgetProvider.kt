package edu.zjxu.jxucampushub.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.util.TypedValue
import android.view.View
import android.widget.RemoteViews
import edu.zjxu.jxucampushub.MainActivity
import edu.zjxu.jxucampushub.R
import org.json.JSONObject

/**
 * 校园桌面组件（PRD 0.7.0 §12/§13）。
 *
 * 数据由 Dart 侧 WidgetProjection 经 MethodChannel 推送到 [CampusWidgetStore]，
 * 组件本身不访问网络 / CAS / Cookie / SecureStorage，快照中不含任何凭据。
 * 交互统一走 `jxucampushub://action/<actionId>`，由 MainActivity 分发到 CampusAction。
 */
class CampusWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        for (widgetId in appWidgetIds) {
            CampusWidgetStore.update(context, appWidgetManager, widgetId)
        }
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: android.os.Bundle?,
    ) {
        CampusWidgetStore.update(context, appWidgetManager, appWidgetId)
    }

    /** 实例被删除时清理它的独立配置，避免复用同一 id 时串配置。 */
    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        for (widgetId in appWidgetIds) {
            CampusWidgetConfigStore.clear(context, widgetId)
        }
    }
}

object CampusWidgetStore {
    private const val PREFS = "campus_widget"
    private const val KEY_SNAPSHOT = "snapshot"
    private const val KEY_GENERATED_AT = "generated_at"
    private const val STALE_AFTER_MS = 6L * 60L * 60L * 1000L

    private const val HERO_COURSE_SP = 20f
    private const val HERO_COURSE_COMPACT_SP = 17f

    /**
     * 组件可用尺寸（dp）。
     *
     * 只用同一次上报的 [AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH] /
     * [AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT] 下界；MIN_WIDTH 配 MAX_HEIGHT
     * 的方向语义不同，混用会把宽矮实例误判成高实例。
     */
    private data class WidgetSize(val widthDp: Int, val heightDp: Int) {
        /** 矮尺寸（≈2 行高）：只保留主课程与时间，其余行让位。 */
        val isCompact: Boolean get() = heightDp < COMPACT_HEIGHT_DP

        /** 高尺寸（≈4 行高及以上）：才展开今日课程 / 考试 / 通知等多行信息。 */
        val isRoomy: Boolean get() = heightDp >= ROOMY_HEIGHT_DP

        /** 今日课程最多行数：极高尺寸才从 2 行升到 3 行。 */
        val maxTodayRows: Int
            get() = when {
                !isRoomy -> 0
                heightDp >= 300 -> 3
                else -> 2
            }

        private companion object {
            // Launcher 单元高约 70n-30 dp：2 行 ≈ 110、3 行 ≈ 180、4 行 ≈ 250、5 行 ≈ 320。
            const val COMPACT_HEIGHT_DP = 150
            const val ROOMY_HEIGHT_DP = 250
        }
    }

    fun store(context: Context, snapshotJson: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_SNAPSHOT, snapshotJson)
            .putLong(KEY_GENERATED_AT, System.currentTimeMillis())
            .apply()
        refreshAll(context)
    }

    fun refreshAll(context: Context) {
        val manager = AppWidgetManager.getInstance(context)
        val ids = manager.getAppWidgetIds(
            ComponentName(context, CampusWidgetProvider::class.java),
        )
        for (id in ids) {
            update(context, manager, id)
        }
    }

    fun update(context: Context, manager: AppWidgetManager, widgetId: Int) {
        val views = RemoteViews(context.packageName, R.layout.campus_widget)
        bindClicks(context, views)

        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val raw = prefs.getString(KEY_SNAPSHOT, null)
        val json = raw?.let { runCatching { JSONObject(it) }.getOrNull() }
        if (json == null) {
            views.setTextViewText(R.id.widget_hero_label, "打开 App 加载校园数据")
            views.setTextViewText(R.id.widget_hero_course, "嘉兴大学")
            views.setTextViewText(R.id.widget_hero_meta, "下一节课 · 一卡通 · 电费")
            for (id in hiddenIds) {
                views.setViewVisibility(id, View.GONE)
            }
            manager.updateAppWidget(widgetId, views)
            return
        }

        // 传统 launcher options 给出横竖屏范围：竖屏窄而高，横屏宽而矮。
        val options = manager.getAppWidgetOptions(widgetId)
        val landscape = context.resources.configuration.orientation ==
            android.content.res.Configuration.ORIENTATION_LANDSCAPE
        val size = WidgetSize(
            widthDp = options.getInt(if (landscape)
                AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH else
                AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 180),
            heightDp = options.getInt(if (landscape)
                AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT else
                AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, 220),
        )

        views.setViewVisibility(
            R.id.widget_header,
            if (!size.isCompact && size.widthDp >= 210) View.VISIBLE else View.GONE,
        )
        views.setTextViewText(R.id.widget_header, json.text("weekLabel"))

        views.setTextViewText(R.id.widget_hero_label, "下一节课")
        val heroCourse = json.text("heroCourseName").ifBlank {
            json.text("heroHeadline")
        }
        views.setTextViewText(
            R.id.widget_hero_course,
            heroCourse.ifBlank { "今天没课" },
        )
        // 每次更新显式写入字号：RemoteViews 复用视图，紧凑尺寸缩到 17sp 后
        // 若恢复正常尺寸不写回，旧字号会残留。
        views.setTextViewTextSize(
            R.id.widget_hero_course,
            TypedValue.COMPLEX_UNIT_SP,
            if (size.isCompact) HERO_COURSE_COMPACT_SP else HERO_COURSE_SP,
        )
        // 时间优先：紧凑尺寸只保留主课程时间，没有时间才退回地点。
        val heroTime = json.text("heroTimeText")
        val heroLocation = json.text("heroLocationText")
        views.setTextViewText(
            R.id.widget_hero_meta,
            if (size.isCompact) {
                heroTime.ifBlank { heroLocation }
            } else {
                buildMeta(heroTime, heroLocation)
            },
        )

        renderToday(views, json.optJSONArray("todayCourses"), size)
        // 每实例显示开关（配置页写入）：只影响该实例的还款/电费/通知条目。
        val config = CampusWidgetConfigStore.load(context, widgetId)
        renderAssets(views, json, size, config)
        renderExtras(views, json, size, config)

        val generatedAt = prefs.getLong(KEY_GENERATED_AT, 0L)
        val stale = generatedAt > 0L &&
            System.currentTimeMillis() - generatedAt > STALE_AFTER_MS
        if (stale) {
            views.setTextViewText(R.id.widget_stale, "数据可能已过期，打开 App 更新")
        }
        views.setViewVisibility(
            R.id.widget_stale,
            if (stale) View.VISIBLE else View.GONE,
        )

        manager.updateAppWidget(widgetId, views)
    }

    private val hiddenIds = intArrayOf(
        R.id.widget_header,
        R.id.widget_today_container,
        R.id.widget_assets,
        R.id.widget_exam,
        R.id.widget_notice,
        R.id.widget_stale,
    )

    private fun renderToday(
        views: RemoteViews,
        today: org.json.JSONArray?,
        size: WidgetSize,
    ) {
        val maxRows = if (size.widthDp >= 300) size.maxTodayRows else 0
        if (maxRows == 0 || today == null || today.length() == 0) {
            views.setViewVisibility(R.id.widget_today_container, View.GONE)
            return
        }
        views.setViewVisibility(R.id.widget_today_container, View.VISIBLE)
        val rowIds = intArrayOf(
            R.id.widget_today_1,
            R.id.widget_today_2,
            R.id.widget_today_3,
        )
        for (i in rowIds.indices) {
            val row = if (i < maxRows) today.optJSONObject(i) else null
            if (row == null) {
                views.setViewVisibility(rowIds[i], View.GONE)
                continue
            }
            views.setViewVisibility(rowIds[i], View.VISIBLE)
            views.setTextViewText(
                rowIds[i],
                "${row.text("timeText")}  ${row.text("courseName")}",
            )
        }
    }

    private fun renderAssets(
        views: RemoteViews,
        json: JSONObject,
        size: WidgetSize,
        config: CampusWidgetConfigStore.Config,
    ) {
        val hasBalance =
            config.showBalance && json.optBoolean("hasCampusCardData") &&
                json.text("campusCardBalance").isNotBlank()
        val hasElectricity =
            config.showElectricity && json.optBoolean("hasElectricityData") &&
                json.text("dormElectricity").isNotBlank()
        val show = !size.isCompact && size.widthDp >= 230 &&
            (hasBalance || hasElectricity)
        if (!show) {
            views.setViewVisibility(R.id.widget_assets, View.GONE)
            return
        }
        views.setViewVisibility(R.id.widget_assets, View.VISIBLE)
        // 单项关闭时隐藏该子视图（weight 行会让另一项占满整行），而不是留空位。
        views.setViewVisibility(
            R.id.widget_balance,
            if (hasBalance) View.VISIBLE else View.GONE,
        )
        views.setTextViewText(
            R.id.widget_balance,
            if (hasBalance) {
                "一卡通 ${withUnit(json.text("campusCardBalance"), "元")}"
            } else {
                ""
            },
        )
        views.setViewVisibility(
            R.id.widget_electricity,
            if (hasElectricity) View.VISIBLE else View.GONE,
        )
        views.setTextViewText(
            R.id.widget_electricity,
            if (hasElectricity) {
                "电费 ${withUnit(json.text("dormElectricity"), "度")}"
            } else {
                ""
            },
        )
    }

    private fun renderExtras(
        views: RemoteViews,
        json: JSONObject,
        size: WidgetSize,
        config: CampusWidgetConfigStore.Config,
    ) {
        val examName = json.text("nextExamCourseName")
        val showExam = size.isRoomy && size.widthDp >= 300 && examName.isNotBlank()
        if (showExam) {
            views.setViewVisibility(R.id.widget_exam, View.VISIBLE)
            views.setTextViewText(
                R.id.widget_exam,
                buildMeta(
                    "考试 " + examName,
                    json.text("nextExamTimeText"),
                ),
            )
        } else {
            views.setViewVisibility(R.id.widget_exam, View.GONE)
        }

        val unread = json.optInt("unreadNoticeCount", 0)
        // 通知受实例开关控制；过期提示（stale）是数据新鲜度信息，
        // 不受该开关影响，仍在 update() 末尾独立渲染。
        val showNotice = config.showNotice && size.isRoomy &&
            size.widthDp >= 300 && unread > 0
        views.setViewVisibility(
            R.id.widget_notice,
            if (showNotice) View.VISIBLE else View.GONE,
        )
        if (showNotice) {
            views.setTextViewText(R.id.widget_notice, "未读通知 $unread 条")
        }
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
        return listOf(primary, secondary)
            .filter { it.isNotBlank() }
            .joinToString(" · ")
    }

    /**
     * 只在纯数字后补单位；已带单位（¥ / 元 / 度 等）或非数字文本原样返回，
     * 避免「¥32.50 元」这类重复标注。
     */
    private fun withUnit(value: String, unit: String): String {
        return if (PURE_NUMBER.matches(value)) "$value $unit" else value
    }

    private val PURE_NUMBER = Regex("-?\\d+(\\.\\d+)?")

    private fun bindClicks(context: Context, views: RemoteViews) {
        bindClick(context, views, R.id.widget_hero, "schedule.today")
        bindClick(context, views, R.id.widget_balance, "campus-card.open")
        bindClick(context, views, R.id.widget_electricity, "electricity.open")
        bindClick(context, views, R.id.widget_exam, "exam.open")
        bindClick(context, views, R.id.widget_notice, "notice.inbox")
        bindClick(context, views, R.id.widget_today_1, "schedule.today")
        bindClick(context, views, R.id.widget_today_2, "schedule.today")
        bindClick(context, views, R.id.widget_today_3, "schedule.today")
    }

    private fun bindClick(
        context: Context,
        views: RemoteViews,
        viewId: Int,
        actionId: String,
    ) {
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
        val pending = PendingIntent.getActivity(
            context,
            actionId.hashCode(),
            intent,
            flags,
        )
        views.setOnClickPendingIntent(viewId, pending)
    }
}
