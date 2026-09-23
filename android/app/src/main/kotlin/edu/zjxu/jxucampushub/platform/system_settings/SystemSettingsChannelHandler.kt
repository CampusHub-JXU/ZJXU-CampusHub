package edu.zjxu.jxucampushub.platform.system_settings

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * 系统设置通道：把用户带到通知 / 应用详情 / 精确闹钟 / 电池优化 / 自启动设置页。
 *
 * 仅负责「打开设置页」，**不代表任何权限已授予**：本类不修改权限、不申请危险
 * 权限、不发起电池优化直接授权弹窗（只打开列表页）。
 *
 * 每个目标失败后逐级降级：目标页 → 应用详情页 → 系统设置首页；全部失败返回
 * `unavailable`。返回值小写字符串与 Dart `SystemSettingsOpenResult` 一一对应。
 */
class SystemSettingsChannelHandler(private val activity: Activity) {
    companion object {
        private const val CHANNEL = "edu.zjxu.jxucampushub/system_settings"

        private const val RESULT_TARGET = "target"
        private const val RESULT_APP_DETAILS = "appDetails"
        private const val RESULT_SETTINGS = "settings"
        private const val RESULT_UNAVAILABLE = "unavailable"

        private const val MIUI_SECURITY_CENTER_PACKAGE = "com.miui.securitycenter"
        private const val MIUI_AUTOSTART_ACTIVITY =
            "com.miui.permcenter.autostart.AutoStartManagementActivity"
    }

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "open" -> {
                    val target = call.argument<String>("target")
                    if (target.isNullOrBlank()) {
                        result.error("invalid_args", "target is required", null)
                        return@setMethodCallHandler
                    }
                    result.success(open(target))
                }

                else -> result.notImplemented()
            }
        }
    }

    /** 打开目标设置页；逐级降级，全部失败返回 `unavailable`。 */
    private fun open(target: String): String {
        if (tryOpenTarget(target)) {
            return RESULT_TARGET
        }
        if (tryOpenAppDetails()) {
            return RESULT_APP_DETAILS
        }
        if (tryOpen(Intent(Settings.ACTION_SETTINGS))) {
            return RESULT_SETTINGS
        }
        return RESULT_UNAVAILABLE
    }

    private fun tryOpenTarget(target: String): Boolean {
        return when (target) {
            "notifications" -> openNotificationSettings()
            // 目标本身就是应用详情页，交给统一降级链处理即可。
            "appDetails" -> false
            "exactAlarms" -> openExactAlarmSettings()
            "batteryOptimization" -> tryOpen(
                Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS),
            )
            "autostart" -> openAutostartSettings()
            else -> false
        }
    }

    /** Android 8.0+ 应用通知设置；低版本返回 false 由降级链接管。 */
    private fun openNotificationSettings(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return false
        }
        val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
            putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName)
        }
        return tryOpen(intent)
    }

    private fun tryOpenAppDetails(): Boolean {
        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
            data = Uri.parse("package:${activity.packageName}")
        }
        return tryOpen(intent)
    }

    /**
     * Android 12+ 精确闹钟设置（package: URI）。
     *
     * API < 31 没有独立的精确闹钟设置页，返回 false 降级到应用详情页，不伪造
     * 精确闹钟入口。
     */
    private fun openExactAlarmSettings(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            return false
        }
        val intent = Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM).apply {
            data = Uri.parse("package:${activity.packageName}")
        }
        return tryOpen(intent)
    }

    /**
     * 自启动管理：仅小米 ROM 尽力尝试私有 Activity（无官方保证），
     * 其他设备 / 组件不存在 / 被拒时返回 false 降级到应用详情页。
     */
    private fun openAutostartSettings(): Boolean {
        if (!isMiuiLikeDevice()) {
            return false
        }
        val intent = Intent().apply {
            setClassName(MIUI_SECURITY_CENTER_PACKAGE, MIUI_AUTOSTART_ACTIVITY)
            putExtra("extra_pkgname", activity.packageName)
        }
        return tryOpen(intent)
    }

    private fun isMiuiLikeDevice(): Boolean {
        val manufacturer = Build.MANUFACTURER.lowercase()
        val brand = Build.BRAND.lowercase()
        return manufacturer.contains("xiaomi") ||
            manufacturer.contains("redmi") ||
            manufacturer.contains("poco") ||
            brand.contains("xiaomi") ||
            brand.contains("redmi") ||
            brand.contains("poco")
    }

    /**
     * 启动设置页；SecurityException / ActivityNotFoundException 及其他运行时
     * 异常一律视为该级失败，由调用方继续降级。
     */
    private fun tryOpen(intent: Intent): Boolean {
        return try {
            activity.startActivity(intent)
            true
        } catch (_: ActivityNotFoundException) {
            false
        } catch (_: SecurityException) {
            false
        } catch (_: Exception) {
            false
        }
    }
}
