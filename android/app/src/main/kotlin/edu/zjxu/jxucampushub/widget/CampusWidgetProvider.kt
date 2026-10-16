package edu.zjxu.jxucampushub.widget

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.res.Configuration
import android.os.Bundle
import java.time.LocalDateTime
import org.json.JSONObject

/**
 * 校园桌面组件（三种固定尺寸，共用 [CampusWidgetRenderer]；视觉与自走时见
 * docs/desktop-widget-v2.md）。
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
        // 重启 / 升级 / launcher 重绑后闹钟可能丢了：按当前时钟重排。
        CampusWidgetScheduler.rearm(context)
    }

    /** 桌面改变了这个实例的尺寸（旋转 / 换网格 / 折叠屏）：按新高度重排课程行数。 */
    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle?,
    ) {
        CampusWidgetStore.update(context, appWidgetManager, appWidgetId, kind)
    }

    /** 实例被删除时清理它的独立配置与旧版尺寸持久化，避免复用同一 id 时串配置。 */
    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        for (widgetId in appWidgetIds) {
            CampusWidgetConfigStore.clear(context, widgetId)
            CampusWidgetStore.clearInstanceState(context, widgetId)
        }
        CampusWidgetScheduler.rearm(context)
    }

    /** 本尺寸的最后一个实例被删除：若三种尺寸都没有实例了，取消所有闹钟。 */
    override fun onDisabled(context: Context) {
        CampusWidgetScheduler.rearm(context)
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

    /** 读出并解析后的快照 + 原生收到它的时间（毫秒，0 = 未知）。 */
    internal class Loaded(val snapshot: CampusWidgetSnapshot?, val generatedAtMs: Long)

    fun store(context: Context, snapshotJson: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_SNAPSHOT, snapshotJson)
            .putLong(KEY_GENERATED_AT, System.currentTimeMillis())
            .apply()
        refreshAll(context)
    }

    /** 原生最近一次收到快照的时间（毫秒）；从未收到返回 null。 */
    fun lastSnapshotAtMs(context: Context): Long? {
        val value = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getLong(KEY_GENERATED_AT, 0L)
        return if (value > 0L) value else null
    }

    internal fun loadSnapshot(context: Context): Loaded {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val snapshot = prefs.getString(KEY_SNAPSHOT, null)
            ?.let { runCatching { CampusWidgetSnapshot.parse(JSONObject(it)) }.getOrNull() }
        return Loaded(snapshot, prefs.getLong(KEY_GENERATED_AT, 0L))
    }

    /** 每种尺寸已放置的实例 id。 */
    private fun instanceIds(context: Context): Map<CampusWidgetKind, IntArray> {
        val manager = AppWidgetManager.getInstance(context)
        return CampusWidgetKind.values().associateWith { kind ->
            manager.getAppWidgetIds(ComponentName(context, kind.providerClass))
        }
    }

    internal fun instanceCounts(context: Context): Map<CampusWidgetKind, Int> =
        instanceIds(context).mapValues { it.value.size }

    /** 刷新三种尺寸的全部已放置实例，并重排下一个自走时闹钟。 */
    fun refreshAll(context: Context) {
        val manager = AppWidgetManager.getInstance(context)
        purgeLegacySizeKeys(context)
        val loaded = loadSnapshot(context)
        CampusWidgetTheme.remember(context, loaded.snapshot)
        val ids = instanceIds(context)
        for ((kind, kindIds) in ids) {
            for (id in kindIds) {
                render(context, manager, id, kind, loaded)
            }
        }
        CampusWidgetScheduler.rearm(context, loaded.snapshot, ids.mapValues { it.value.size })
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

    /** 渲染一个实例；快照缺失 / 旧版 schema 时渲染「打开 App」占位。 */
    fun update(
        context: Context,
        manager: AppWidgetManager,
        widgetId: Int,
        kind: CampusWidgetKind,
    ) {
        val loaded = loadSnapshot(context)
        CampusWidgetTheme.remember(context, loaded.snapshot)
        render(context, manager, widgetId, kind, loaded)
    }

    private fun render(
        context: Context,
        manager: AppWidgetManager,
        widgetId: Int,
        kind: CampusWidgetKind,
        loaded: Loaded,
    ) {
        val palette = CampusWidgetTheme.palette(context, loaded.snapshot)
        val heightDp = heightDp(context, manager, widgetId, kind)
        val views = CampusWidgetRenderer.render(
            context = context,
            kind = kind,
            widgetId = widgetId,
            snapshot = loaded.snapshot,
            generatedAtMs = loaded.generatedAtMs,
            now = LocalDateTime.now(),
            nowMs = System.currentTimeMillis(),
            palette = palette,
            heightDp = heightDp,
            widthDp = widthDp(context, manager, widgetId, kind),
        )
        manager.updateAppWidget(widgetId, views)
    }

    /** 宽度（dp）：竖屏取 MIN_WIDTH，横屏取 MAX_WIDTH；拿不到时退回声明的 minWidth。 */
    private fun widthDp(
        context: Context,
        manager: AppWidgetManager,
        widgetId: Int,
        kind: CampusWidgetKind,
    ): Int {
        val landscape = context.resources.configuration.orientation ==
            Configuration.ORIENTATION_LANDSCAPE
        val key = if (landscape) {
            AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH
        } else {
            AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH
        }
        val reported = runCatching { manager.getAppWidgetOptions(widgetId).getInt(key, 0) }
            .getOrDefault(0)
        if (reported > 0) return reported
        return if (kind == CampusWidgetKind.SMALL) 110 else 250
    }

    /**
     * 桌面当前给这个实例的高度（dp）：竖屏取 MAX_HEIGHT，横屏取 MIN_HEIGHT
     * （见 AppWidgetManager 文档）；拿不到时退回 appwidget-provider 声明的 minHeight。
     */
    private fun heightDp(
        context: Context,
        manager: AppWidgetManager,
        widgetId: Int,
        kind: CampusWidgetKind,
    ): Int {
        val landscape = context.resources.configuration.orientation ==
            Configuration.ORIENTATION_LANDSCAPE
        val key = if (landscape) {
            AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT
        } else {
            AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT
        }
        val reported = runCatching { manager.getAppWidgetOptions(widgetId).getInt(key, 0) }
            .getOrDefault(0)
        if (reported > 0) return reported
        return when (kind) {
            CampusWidgetKind.SMALL -> 110
            CampusWidgetKind.MEDIUM -> 110
            CampusWidgetKind.LARGE -> 250
        }
    }
}
