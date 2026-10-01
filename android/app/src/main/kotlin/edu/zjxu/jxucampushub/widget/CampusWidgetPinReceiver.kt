package edu.zjxu.jxucampushub.widget

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * `requestPinAppWidget` 的成功回调：用户在桌面确认添加后由 launcher 触发。
 *
 * 只记录并刷新一遍已放置实例；组件落在哪一页 / 哪个格子由 launcher 决定，本 App 无法控制。
 */
class CampusWidgetPinReceiver : BroadcastReceiver() {
    companion object {
        const val ACTION_PIN_RESULT = "edu.zjxu.jxucampushub.widget.PIN_RESULT"
        const val EXTRA_SIZE = "size"
        private const val TAG = "CampusWidgetPin"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_PIN_RESULT) return
        Log.i(TAG, "pin accepted by launcher: size=${intent.getStringExtra(EXTRA_SIZE)}")
        CampusWidgetStore.refreshAll(context)
    }
}
