package edu.zjxu.jxucampushub.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
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
}

object CampusWidgetStore {
    private const val PREFS = "campus_widget"
    private const val KEY_SNAPSHOT = "snapshot"
    private const val KEY_GENERATED_AT = "generated_at"
    private const val STALE_AFTER_MS = 6L * 60L * 60L * 1000L

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

        val options = manager.getAppWidgetOptions(widgetId)
        val minWidth = options.getInt(
            AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH,
            180,
        )

        views.setViewVisibility(
            R.id.widget_header,
            if (minWidth >= 210) View.VISIBLE else View.GONE,
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
        views.setTextViewText(
            R.id.widget_hero_meta,
            buildMeta(
                json.text("heroTimeText"),
                json.text("heroLocationText"),
            ),
        )

        renderToday(views, json.optJSONArray("todayCourses"), minWidth)
        renderAssets(views, json, minWidth)
        renderExtras(views, json, minWidth)

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
        minWidth: Int,
    ) {
        val show = minWidth >= 300 && (today?.length() ?: 0) > 0
        if (!show) {
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
            val row = today?.optJSONObject(i)
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

    private fun renderAssets(views: RemoteViews, json: JSONObject, minWidth: Int) {
        val show = minWidth >= 230 &&
            (json.optBoolean("hasCampusCardData") || json.optBoolean("hasElectricityData"))
        if (!show) {
            views.setViewVisibility(R.id.widget_assets, View.GONE)
            return
        }
        views.setViewVisibility(R.id.widget_assets, View.VISIBLE)
        views.setTextViewText(
            R.id.widget_balance,
            if (json.optBoolean("hasCampusCardData")) {
                "一卡通 ${json.text("campusCardBalance")}"
            } else {
                ""
            },
        )
        views.setTextViewText(
            R.id.widget_electricity,
            if (json.optBoolean("hasElectricityData")) {
                "电费 ${json.text("dormElectricity")}"
            } else {
                ""
            },
        )
    }

    private fun renderExtras(views: RemoteViews, json: JSONObject, minWidth: Int) {
        val examName = json.text("nextExamCourseName")
        val showExam = minWidth >= 300 && examName.isNotBlank()
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
        val showNotice = minWidth >= 300 && unread > 0
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
