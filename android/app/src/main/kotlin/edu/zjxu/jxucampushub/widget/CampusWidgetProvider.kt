package edu.zjxu.jxucampushub.widget

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import org.json.JSONObject

/**
 * 校园桌面组件（三种固定尺寸，共用 [CampusWidgetRenderer]）。
 *
 * - 小 2x2「下一节课」：[CampusWidgetSmallProvider]
 * - 中 4x2「今日课表」：[CampusWidgetProvider]（沿用旧类名，已放置的旧实例不丢失）
 * - 大 4x4「校园总览」：[CampusWidgetLargeProvider]
 *
 * 数据由 Dart 侧 WidgetProjection 经 MethodChannel 推送到 [CampusWidgetStore]，
 * 组件本身不访问网络 / CAS / Cookie / SecureStorage，快照中不含任何凭据。
 * 交互统一走 `jxucampushub://action/<actionId>`，由 MainActivity 分发到 CampusAction。
 *
 * 三种尺寸都是固定尺寸（resizeMode=none），不再按 dp 阈值自适应。
 */
enum class CampusWidgetKind(
    val code: String,
    val providerClass: Class<out AppWidgetProvider>,
) {
    SMALL("small", CampusWidgetSmallProvider::class.java),
    MEDIUM("medium", CampusWidgetProvider::class.java),
    LARGE("large", CampusWidgetLargeProvider::class.java),
    ;

    companion object {
        fun fromCode(code: String?): CampusWidgetKind? =
            values().firstOrNull { it.code == code }
    }
}

abstract class BaseCampusWidgetProvider(
    private val kind: CampusWidgetKind,
) : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        CampusWidgetStore.purgeLegacySizeKeys(context)
        for (widgetId in appWidgetIds) {
            CampusWidgetStore.update(context, appWidgetManager, widgetId, kind)
        }
    }

    /** 实例被删除时清理它的独立配置与旧版尺寸持久化，避免复用同一 id 时串配置。 */
    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        for (widgetId in appWidgetIds) {
            CampusWidgetConfigStore.clear(context, widgetId)
            CampusWidgetStore.clearInstanceState(context, widgetId)
        }
    }
}

/** 小 2x2「下一节课」。 */
class CampusWidgetSmallProvider : BaseCampusWidgetProvider(CampusWidgetKind.SMALL)

/** 中 4x2「今日课表」。类名与 receiver 沿用旧版，保证已放置实例继续存活。 */
class CampusWidgetProvider : BaseCampusWidgetProvider(CampusWidgetKind.MEDIUM)

/** 大 4x4「校园总览」。 */
class CampusWidgetLargeProvider : BaseCampusWidgetProvider(CampusWidgetKind.LARGE)

object CampusWidgetStore {
    private const val PREFS = "campus_widget"
    private const val KEY_SNAPSHOT = "snapshot"
    private const val KEY_GENERATED_AT = "generated_at"

    // 旧版（可缩放组件）持久化的尺寸键；现已不用，仅用于清理残留。
    private const val LEGACY_KEY_SIZE_W_PREFIX = "size_w_"
    private const val LEGACY_KEY_SIZE_H_PREFIX = "size_h_"

    private const val STALE_AFTER_MS = 6L * 60L * 60L * 1000L

    fun store(context: Context, snapshotJson: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_SNAPSHOT, snapshotJson)
            .putLong(KEY_GENERATED_AT, System.currentTimeMillis())
            .apply()
        refreshAll(context)
    }

    /** 刷新三种尺寸的全部已放置实例。 */
    fun refreshAll(context: Context) {
        val manager = AppWidgetManager.getInstance(context)
        purgeLegacySizeKeys(context)
        for (kind in CampusWidgetKind.values()) {
            val ids = manager.getAppWidgetIds(ComponentName(context, kind.providerClass))
            for (id in ids) {
                update(context, manager, id, kind)
            }
        }
    }

    /** 实例被删除时清掉该 id 可能残留的旧版尺寸键；widget id 会被复用。 */
    fun clearInstanceState(context: Context, widgetId: Int) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .remove("$LEGACY_KEY_SIZE_W_PREFIX$widgetId")
            .remove("$LEGACY_KEY_SIZE_H_PREFIX$widgetId")
            .apply()
    }

    /** 一次性清理旧版遗留的 size_w_/size_h_ 键（升级后不再被读取）。 */
    fun purgeLegacySizeKeys(context: Context) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val legacy = prefs.all.keys.filter {
            it.startsWith(LEGACY_KEY_SIZE_W_PREFIX) || it.startsWith(LEGACY_KEY_SIZE_H_PREFIX)
        }
        if (legacy.isEmpty()) return
        prefs.edit().also { editor -> legacy.forEach { editor.remove(it) } }.apply()
    }

    /** 渲染一个实例；快照缺失 / 损坏时渲染「打开 App 加载」占位。 */
    fun update(
        context: Context,
        manager: AppWidgetManager,
        widgetId: Int,
        kind: CampusWidgetKind,
    ) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val json = prefs.getString(KEY_SNAPSHOT, null)
            ?.let { runCatching { JSONObject(it) }.getOrNull() }
        val generatedAt = prefs.getLong(KEY_GENERATED_AT, 0L)
        val stale = generatedAt > 0L &&
            System.currentTimeMillis() - generatedAt > STALE_AFTER_MS
        val views = CampusWidgetRenderer.render(context, kind, widgetId, json, stale)
        manager.updateAppWidget(widgetId, views)
    }
}
