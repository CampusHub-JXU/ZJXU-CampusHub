package edu.zjxu.campus_widget_store

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/** Stores only the display projection; no Activity or auth access. */
class CampusWidgetStorePlugin : FlutterPlugin {
    private var channel: MethodChannel? = null
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "edu.zjxu.jxucampushub/widget_store").also { ch ->
            ch.setMethodCallHandler { call, result ->
                if (call.method == "installedCount") {
                    try {
                        val manager = AppWidgetManager.getInstance(context)
                        result.success(PROVIDERS.sumOf { manager.getAppWidgetIds(ComponentName(context.packageName, it)).size })
                    } catch (error: Exception) {
                        result.error("query_failed", error.javaClass.simpleName, null)
                    }
                    return@setMethodCallHandler
                }
                if (call.method != "push") { result.notImplemented(); return@setMethodCallHandler }
                val snapshot = call.argument<Map<String, Any?>>("snapshot")
                if (snapshot == null) { result.error("invalid_args", "snapshot required", null); return@setMethodCallHandler }
                try {
                    val saved = context.getSharedPreferences("campus_widget", Context.MODE_PRIVATE).edit()
                        .putString("snapshot", JSONObject(snapshot).toString())
                        .putLong("generated_at", System.currentTimeMillis()).commit()
                    if (!saved) { result.error("storage_failed", "snapshot not saved", null); return@setMethodCallHandler }
                    context.sendBroadcast(Intent("edu.zjxu.jxucampushub.widget.ACTION_REFRESH")
                        .setClassName(context.packageName, "edu.zjxu.jxucampushub.widget.CampusWidgetRefreshReceiver"))
                    result.success(true)
                } catch (error: Exception) {
                    result.error("store_failed", error.javaClass.simpleName, null)
                }
            }
        }
    }
    private companion object {
        val PROVIDERS = listOf(
            "edu.zjxu.jxucampushub.widget.CampusWidgetSmallProvider",
            "edu.zjxu.jxucampushub.widget.CampusWidgetProvider",
            "edu.zjxu.jxucampushub.widget.CampusWidgetLargeProvider",
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }
}
