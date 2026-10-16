package edu.zjxu.jxucampushub.platform.widget

import android.app.Activity
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Intent
import android.os.Build
import edu.zjxu.jxucampushub.platform.MiuiShortcutPermission
import edu.zjxu.jxucampushub.platform.PinRequestResult
import edu.zjxu.jxucampushub.platform.invalidArgs
import edu.zjxu.jxucampushub.widget.CampusWidgetKind
import edu.zjxu.jxucampushub.widget.CampusWidgetPinReceiver
import edu.zjxu.jxucampushub.widget.CampusWidgetStore
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/**
 * 桌面组件通道：只接收无凭据快照并请求固定组件。
 *
 * `requestPin` 参数 `size` ∈ small / medium / large，返回
 * `requested` / `unsupported` / `rejected` / `error`。`requested` 只表示请求已交给
 * launcher；组件落在哪一页 / 哪个格子由 launcher 决定，本 App 无法控制。
 */
class WidgetChannelHandler(private val activity: Activity) {
    companion object {
        private const val CHANNEL = "edu.zjxu.jxucampushub/widget"
        private const val TAG = "WidgetChannel"
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

                "requestPin" -> {
                    val kind = CampusWidgetKind.fromCode(call.argument<String>("size"))
                    if (kind == null) {
                        result.invalidArgs("size must be small, medium or large")
                        return@setMethodCallHandler
                    }
                    result.success(requestCampusWidgetPin(kind).code)
                }

                "isSupported" -> {
                    result.success(
                        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                            AppWidgetManager.getInstance(activity)
                                .isRequestPinAppWidgetSupported,
                    )
                }

                "getStatus" -> result.success(readStatus())

                else -> result.notImplemented()
            }
        }
    }

    /**
     * 设置页用的只读状态：是否支持一键固定、每种尺寸已放置的实例数、原生最近一次
     * 收到快照的时间（毫秒；从未收到为 null）。读取失败的项按 0 / null 兜底。
     */
    private fun readStatus(): Map<String, Any?> {
        val manager = AppWidgetManager.getInstance(activity)
        val installed = CampusWidgetKind.values().associate { kind ->
            kind.code to runCatching {
                manager.getAppWidgetIds(ComponentName(activity, kind.providerClass)).size
            }.getOrDefault(0)
        }
        val pinSupported = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            runCatching { manager.isRequestPinAppWidgetSupported }.getOrDefault(false)
        val lastSnapshotAt = CampusWidgetStore.lastSnapshotAtMs(activity)
        return mapOf(
            "pinSupported" to pinSupported,
            "installed" to installed,
            "lastSnapshotAtMs" to lastSnapshotAt,
        )
    }

    private fun requestCampusWidgetPin(kind: CampusWidgetKind): PinRequestResult {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return PinRequestResult.UNSUPPORTED
        return try {
            val manager = AppWidgetManager.getInstance(activity)
            if (!manager.isRequestPinAppWidgetSupported) return PinRequestResult.UNSUPPORTED
            val accepted = manager.requestPinAppWidget(
                ComponentName(activity, kind.providerClass),
                null,
                pinSuccessCallback(kind),
            )
            if (accepted) {
                PinRequestResult.REQUESTED
            } else {
                // MIUI/HyperOS 的「桌面快捷方式」权限（app-op 10017）是否也限制组件固定未经验证，
                // 因此只作诊断日志，不再提前拦截；Dart 侧对 rejected 给出通用引导。
                if (MiuiShortcutPermission.isDenied(activity)) {
                    android.util.Log.w(TAG, "widget pin rejected with MIUI shortcut permission denied: ${kind.code}")
                }
                PinRequestResult.REJECTED
            }
        } catch (error: Exception) {
            android.util.Log.w(TAG, "requestPinAppWidget failed: ${error.javaClass.simpleName}")
            PinRequestResult.ERROR
        }
    }

    /** 用户在桌面确认添加后，launcher 触发该广播（显式组件、不可变）。 */
    private fun pinSuccessCallback(kind: CampusWidgetKind): PendingIntent {
        val intent = Intent(activity, CampusWidgetPinReceiver::class.java).apply {
            action = CampusWidgetPinReceiver.ACTION_PIN_RESULT
            putExtra(CampusWidgetPinReceiver.EXTRA_SIZE, kind.code)
        }
        return PendingIntent.getBroadcast(
            activity,
            kind.ordinal,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}
