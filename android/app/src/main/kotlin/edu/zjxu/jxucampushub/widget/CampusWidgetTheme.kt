package edu.zjxu.jxucampushub.widget

import android.content.Context
import android.content.res.Configuration
import edu.zjxu.jxucampushub.R

/** 一个颜色的浅色 / 深色两个值（API 34+ 的 RemoteViews 双值 API 直接吃这一对）。 */
internal class Duo(val light: Int, val night: Int) {
    fun pick(isNight: Boolean): Int = if (isNight) night else light
}

/**
 * 一次渲染用的配色。每个颜色都带浅 / 深两个值：
 * - API 34+：用 `setColorInt` / `setColorStateList` 的 notNight / night 双值重载写进 RemoteViews，
 *   桌面深浅色切换时由 launcher 自己换值，不需要重新渲染；
 * - API 34 以下：只能按渲染时桌面的深浅色 [night] 取一个值写入，切换后到下一次重渲才变
 *   （不随切换变化的颜色留在 XML `@color`，由 values-night 自动跟随）。
 */
internal class WidgetPalette(
    val night: Boolean,
    /** 跟随设置里的主题色（快照 `theme.accentLight/accentDark`）。 */
    val accent: Duo,
    /** 强调底：强调色 + 8%（浅）/ 14%（深）透明度，ARGB。 */
    val tint: Duo,
    val warn: Duo,
    val primary: Duo,
    val secondary: Duo,
) {
    /** API 34 以下强调底写法用：不透明 RGB + 透明度。 */
    val tintRgb: Int get() = accent.pick(night) or 0xFF000000.toInt()
    val tintAlpha: Int get() = if (night) TINT_ALPHA_DARK else TINT_ALPHA_LIGHT

    companion object {
        const val TINT_ALPHA_LIGHT = 20 // 8% of 255
        const val TINT_ALPHA_DARK = 36 // 14% of 255
    }
}

/**
 * 强调色来源（docs/desktop-widget-v2.md §7.1）：
 * 快照 `theme.accentLight/accentDark`（Dart 已做对比度兜底）→ 最近一次收到并保存的值 →
 * 资源 `campus_widget_accent` 兜底（从未收到过）。浅 / 深两个值分别取，缺哪个就回退哪个。
 */
internal object CampusWidgetTheme {
    private const val PREFS = "campus_widget"
    private const val KEY_ACCENT_LIGHT = "theme_accent_light"
    private const val KEY_ACCENT_DARK = "theme_accent_dark"

    fun isNight(context: Context): Boolean {
        val mode = context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK
        return mode == Configuration.UI_MODE_NIGHT_YES
    }

    /** 快照带了 `theme` 且与已保存的不同才写盘；没带则保持原值。 */
    fun remember(context: Context, snapshot: CampusWidgetSnapshot?) {
        val light = snapshot?.accentLight
        val dark = snapshot?.accentDark
        if (light == null && dark == null) return
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val editor = prefs.edit()
        var changed = false
        if (light != null && prefs.getInt(KEY_ACCENT_LIGHT, 0) != light) {
            editor.putInt(KEY_ACCENT_LIGHT, light)
            changed = true
        }
        if (dark != null && prefs.getInt(KEY_ACCENT_DARK, 0) != dark) {
            editor.putInt(KEY_ACCENT_DARK, dark)
            changed = true
        }
        if (changed) editor.apply()
    }

    fun palette(context: Context, snapshot: CampusWidgetSnapshot?): WidgetPalette {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val lightCtx = colorContext(context, night = false)
        val nightCtx = colorContext(context, night = true)

        fun duo(res: Int) = Duo(lightCtx.getColor(res), nightCtx.getColor(res))

        val accentLight = snapshot?.accentLight
            ?: prefs.takeIf { it.contains(KEY_ACCENT_LIGHT) }?.getInt(KEY_ACCENT_LIGHT, 0)
            ?: lightCtx.getColor(R.color.campus_widget_accent)
        val accentDark = snapshot?.accentDark
            ?: prefs.takeIf { it.contains(KEY_ACCENT_DARK) }?.getInt(KEY_ACCENT_DARK, 0)
            ?: nightCtx.getColor(R.color.campus_widget_accent)
        return WidgetPalette(
            night = isNight(context),
            accent = Duo(accentLight, accentDark),
            tint = Duo(
                withAlpha(accentLight, WidgetPalette.TINT_ALPHA_LIGHT),
                withAlpha(accentDark, WidgetPalette.TINT_ALPHA_DARK),
            ),
            warn = duo(R.color.campus_widget_warn),
            primary = duo(R.color.campus_widget_text_primary),
            secondary = duo(R.color.campus_widget_text_secondary),
        )
    }

    private fun withAlpha(rgb: Int, alpha: Int): Int = (alpha shl 24) or (rgb and 0x00FFFFFF)

    /** 强制浅色 / 深色配置的 Context，用来读出资源里 values / values-night 两套颜色。 */
    private fun colorContext(context: Context, night: Boolean): Context {
        val config = Configuration(context.resources.configuration)
        val mode = if (night) Configuration.UI_MODE_NIGHT_YES else Configuration.UI_MODE_NIGHT_NO
        config.uiMode = (config.uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or mode
        return context.createConfigurationContext(config)
    }
}
