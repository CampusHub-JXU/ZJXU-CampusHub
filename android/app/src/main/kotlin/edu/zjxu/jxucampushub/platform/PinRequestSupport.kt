package edu.zjxu.jxucampushub.platform

import android.app.Activity
import android.app.AppOpsManager
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings

/**
 * 「固定到桌面」类请求（快捷方式 / 桌面组件）的统一结果码，Dart 侧按字符串映射。
 *
 * [ERROR] 只用于异常路径（桌面组件通道使用；快捷方式通道不产生）。
 */
internal enum class PinRequestResult(val code: String) {
    REQUESTED("requested"),
    UNSUPPORTED("unsupported"),
    REJECTED("rejected"),
    ERROR("error"),
}

/**
 * MIUI / HyperOS 的「桌面快捷方式」权限（app-op 10017）探测与设置页跳转。
 *
 * 该权限被拒时系统会静默吞掉固定请求，所以固定前先探测，被拒则返回
 * [PinRequestResult.REJECTED] 并引导用户到权限设置页，而不是静默失败。
 * 快捷方式与桌面组件通道共用此处，避免两份 OEM 探测代码。
 */
internal object MiuiShortcutPermission {
    private const val MIUI_INSTALL_SHORTCUT_OP = 10017
    private const val TAG = "PinRequest"

    /** 小米系设备且「桌面快捷方式」权限被明确拒绝。读不到状态一律视为未拒绝。 */
    fun isDenied(activity: Activity): Boolean {
        if (!isMiuiLikeDevice()) return false
        val mode = readAppOpMode(activity, MIUI_INSTALL_SHORTCUT_OP) ?: return false
        return mode != AppOpsManager.MODE_ALLOWED && mode != AppOpsManager.MODE_DEFAULT
    }

    fun isMiuiLikeDevice(): Boolean {
        val manufacturer = Build.MANUFACTURER.lowercase()
        val brand = Build.BRAND.lowercase()
        return manufacturer.contains("xiaomi") ||
            manufacturer.contains("redmi") ||
            manufacturer.contains("poco") ||
            brand.contains("xiaomi") ||
            brand.contains("redmi") ||
            brand.contains("poco")
    }

    private fun readAppOpMode(activity: Activity, opCode: Int): Int? {
        return try {
            val appOps = activity.getSystemService(AppOpsManager::class.java) ?: return null
            val method = AppOpsManager::class.java.getMethod(
                "checkOpNoThrow",
                Int::class.javaPrimitiveType,
                Int::class.javaPrimitiveType,
                String::class.java,
            )
            method.invoke(appOps, opCode, activity.applicationInfo.uid, activity.packageName) as? Int
        } catch (error: Throwable) {
            android.util.Log.d(
                TAG,
                "Unable to read MIUI shortcut app-op: ${error.javaClass.simpleName}",
            )
            null
        }
    }

    /** 打开 MIUI 权限编辑页；失败逐级降级到应用详情页。 */
    fun openPermissionSettings(activity: Activity): Boolean {
        for (intent in permissionSettingsIntents(activity)) {
            if (tryStartActivity(activity, intent)) return true
        }
        val appDetailsIntent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
            data = Uri.parse("package:${activity.packageName}")
        }
        return tryStartActivity(activity, appDetailsIntent)
    }

    private fun permissionSettingsIntents(activity: Activity): List<Intent> {
        val actions = listOf(
            "miui.intent.action.APP_PERM_EDITOR",
            "miui.intent.action.APP_PERM_EDITOR_PRIVATE",
        )
        val classes = listOf(
            "com.miui.permcenter.permissions.PermissionsEditorActivity",
            "com.miui.permcenter.permissions.AppPermissionsEditorActivity",
        )
        val intents = mutableListOf<Intent>()
        for (action in actions) {
            for (className in classes) {
                intents += Intent(action).apply {
                    setClassName("com.miui.securitycenter", className)
                    addPackageExtras(activity)
                }
            }
            intents += Intent(action).apply {
                setPackage("com.miui.securitycenter")
                addPackageExtras(activity)
            }
        }
        return intents
    }

    private fun Intent.addPackageExtras(activity: Activity) {
        putExtra("extra_pkgname", activity.packageName)
        putExtra("packageName", activity.packageName)
    }

    private fun tryStartActivity(activity: Activity, intent: Intent): Boolean {
        return try {
            activity.startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }
}
