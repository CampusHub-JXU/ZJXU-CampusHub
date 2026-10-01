package edu.zjxu.jxucampushub.platform.widget

import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.os.Build
import edu.zjxu.jxucampushub.platform.invalidArgs
import edu.zjxu.jxucampushub.widget.CampusWidgetProvider
import edu.zjxu.jxucampushub.widget.CampusWidgetStore
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/**
 * 桌面组件通道：只接收无凭据快照并请求固定组件。
 */
class WidgetChannelHandler(private val activity: Activity) {
    companion object {
        private const val CHANNEL = "edu.zjxu.jxucampushub/widget"
    }

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "pushSnapshot" -> {
                    val snapshot = call.argument<Map<String, Any?>>("snapshot")
                    if (snapshot == null) {
                        result.invalidArgs("snapshot is required")
                        return@setMethodCallHandler
                    }
                    CampusWidgetStore.store(activity, JSONObject(snapshot).toString())
                    result.success(null)
                }

                "requestPin" -> result.success(requestCampusWidgetPin())

                "isSupported" -> {
                    result.success(
                        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                            AppWidgetManager.getInstance(activity)
                                .isRequestPinAppWidgetSupported,
                    )
                }

                else -> result.notImplemented()
            }
        }
    }

    private fun requestCampusWidgetPin(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        val manager = AppWidgetManager.getInstance(activity)
        if (!manager.isRequestPinAppWidgetSupported) return false
        return manager.requestPinAppWidget(
            ComponentName(activity, CampusWidgetProvider::class.java),
            null,
            null,
        )
    }
}
