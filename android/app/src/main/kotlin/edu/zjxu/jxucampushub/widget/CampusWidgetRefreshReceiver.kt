package edu.zjxu.jxucampushub.widget

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * 桌面组件「自走时」重渲入口（不导出）。
 *
 * - [CampusWidgetScheduler] 排的课程边界 / 午夜 / 进度条闹钟（显式组件 PendingIntent）；
 * - 快照插件写入后发的 [ACTION_REFRESH]（显式组件）；
 * - 系统时间变化：`TIME_SET` / `TIMEZONE_CHANGED` / `DATE_CHANGED`（这几个允许 manifest 注册）；
 *   `BOOT_COMPLETED` / `MY_PACKAGE_REPLACED` 用来在重启 / 升级清掉闹钟后重新排上。
 *
 * 都只做一件事：按当前设备时钟重渲所有实例并重排下一个闹钟（[CampusWidgetStore.refreshAll]）。
 * 渲染是 JSON 解析 + 几次 updateAppWidget，毫秒级，直接在 onReceive 里同步完成。
 */
class CampusWidgetRefreshReceiver : BroadcastReceiver() {
    companion object {
        const val ACTION_REFRESH = "edu.zjxu.jxucampushub.widget.ACTION_REFRESH"
        const val ACTION_ALARM_BOUNDARY = "edu.zjxu.jxucampushub.widget.ACTION_ALARM_BOUNDARY"
        const val ACTION_ALARM_PROGRESS = "edu.zjxu.jxucampushub.widget.ACTION_ALARM_PROGRESS"
        private const val TAG = "CampusWidgetRefresh"

        private val HANDLED = setOf(
            ACTION_REFRESH,
            ACTION_ALARM_BOUNDARY,
            ACTION_ALARM_PROGRESS,
            Intent.ACTION_TIME_CHANGED,
            Intent.ACTION_TIMEZONE_CHANGED,
            Intent.ACTION_DATE_CHANGED,
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
        )
    }

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action !in HANDLED) return
        try {
            CampusWidgetStore.refreshAll(context)
        } catch (error: Exception) {
            Log.w(TAG, "refresh failed: ${error.javaClass.simpleName}")
        }
    }
}
