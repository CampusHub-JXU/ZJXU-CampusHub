package edu.zjxu.jxucampushub.widget

import android.content.Context

/**
 * 桌面组件每实例显示配置。
 *
 * 按 appWidgetId 独立存储于 SharedPreferences 的 campus_widget_config 文件，
 * 与组件快照（[CampusWidgetStore] 的 campus_widget 文件）分离。
 * 无配置记录 / 键缺失一律回退默认全显示 true，绝不写死 false。
 */
object CampusWidgetConfigStore {
    private const val PREFS = "campus_widget_config"

    private fun keyShowBalance(widgetId: Int) = "widget_${widgetId}_show_balance"

    private fun keyShowElectricity(widgetId: Int) = "widget_${widgetId}_show_electricity"

    private fun keyShowNotice(widgetId: Int) = "widget_${widgetId}_show_notice"

    /** 单个桌面组件实例的显示开关。 */
    data class Config(
        val showBalance: Boolean,
        val showElectricity: Boolean,
        val showNotice: Boolean,
    ) {
        companion object {
            /** 默认全部显示。 */
            val DEFAULT = Config(
                showBalance = true,
                showElectricity = true,
                showNotice = true,
            )
        }
    }

    /** 读取指定实例配置；无记录时返回 [Config.DEFAULT]。 */
    fun load(context: Context, widgetId: Int): Config {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        return Config(
            showBalance = prefs.getBoolean(keyShowBalance(widgetId), true),
            showElectricity = prefs.getBoolean(keyShowElectricity(widgetId), true),
            showNotice = prefs.getBoolean(keyShowNotice(widgetId), true),
        )
    }

    /** 写入指定实例配置。 */
    fun save(context: Context, widgetId: Int, config: Config) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(keyShowBalance(widgetId), config.showBalance)
            .putBoolean(keyShowElectricity(widgetId), config.showElectricity)
            .putBoolean(keyShowNotice(widgetId), config.showNotice)
            .apply()
    }

    /** 清理指定实例配置（Provider 删除组件时调用）；无记录时为无操作。 */
    fun clear(context: Context, widgetId: Int) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .remove(keyShowBalance(widgetId))
            .remove(keyShowElectricity(widgetId))
            .remove(keyShowNotice(widgetId))
            .apply()
    }
}
