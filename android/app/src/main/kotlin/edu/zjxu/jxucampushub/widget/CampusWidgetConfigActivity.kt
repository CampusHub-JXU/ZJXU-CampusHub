package edu.zjxu.jxucampushub.widget

import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.Intent
import android.os.Bundle
import android.widget.Button
import android.widget.Switch
import edu.zjxu.jxucampushub.R

/**
 * 桌面组件配置页（每个 appWidgetId 独立设置显示内容）。
 *
 * 草稿语义：进入时把已存配置读入内存草稿，只有「保存」才落盘并回 RESULT_OK；
 * 直接返回 / 取消不写盘、也不创建半成品实例（onCreate 即预设 RESULT_CANCELED）。
 * 「恢复默认」只重置当前实例的内存草稿，同样要点保存才生效。
 */
class CampusWidgetConfigActivity : Activity() {
    private var widgetId = AppWidgetManager.INVALID_APPWIDGET_ID

    private var showBalance = true
    private var showElectricity = true
    private var showNotice = true

    private lateinit var showBalanceSwitch: Switch
    private lateinit var showElectricitySwitch: Switch
    private lateinit var showNoticeSwitch: Switch

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 先声明取消：任何未点「保存」的退出路径都不写配置，
        // 首次添加组件时 launcher 也不会创建半成品实例。
        setResult(RESULT_CANCELED)

        widgetId = intent?.extras?.getInt(
            AppWidgetManager.EXTRA_APPWIDGET_ID,
            AppWidgetManager.INVALID_APPWIDGET_ID,
        ) ?: AppWidgetManager.INVALID_APPWIDGET_ID
        if (widgetId == AppWidgetManager.INVALID_APPWIDGET_ID) {
            finish()
            return
        }

        val config = CampusWidgetConfigStore.load(this, widgetId)
        showBalance = config.showBalance
        showElectricity = config.showElectricity
        showNotice = config.showNotice

        setContentView(R.layout.campus_widget_config)
        showBalanceSwitch = findViewById(R.id.campus_widget_config_show_balance)
        showElectricitySwitch = findViewById(R.id.campus_widget_config_show_electricity)
        showNoticeSwitch = findViewById(R.id.campus_widget_config_show_notice)

        showBalanceSwitch.isChecked = showBalance
        showElectricitySwitch.isChecked = showElectricity
        showNoticeSwitch.isChecked = showNotice

        showBalanceSwitch.setOnCheckedChangeListener { _, checked -> showBalance = checked }
        showElectricitySwitch.setOnCheckedChangeListener { _, checked ->
            showElectricity = checked
        }
        showNoticeSwitch.setOnCheckedChangeListener { _, checked -> showNotice = checked }

        findViewById<Button>(R.id.campus_widget_config_save).setOnClickListener { save() }
        findViewById<Button>(R.id.campus_widget_config_restore_default).setOnClickListener {
            restoreDefault()
        }
    }

    private fun save() {
        CampusWidgetConfigStore.save(
            this,
            widgetId,
            CampusWidgetConfigStore.Config(
                showBalance = showBalance,
                showElectricity = showElectricity,
                showNotice = showNotice,
            ),
        )
        // 复用 Provider 现有公开刷新入口，让已存实例立即按新配置重绘。
        CampusWidgetStore.refreshAll(this)
        setResult(
            RESULT_OK,
            Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId),
        )
        finish()
    }

    /** 只重置当前实例的草稿；点「保存」前不落盘，其他实例不受影响。 */
    private fun restoreDefault() {
        showBalance = true
        showElectricity = true
        showNotice = true
        showBalanceSwitch.isChecked = true
        showElectricitySwitch.isChecked = true
        showNoticeSwitch.isChecked = true
    }
}
