package edu.zjxu.jxucampushub.platform.app_icon

import android.app.Activity
import android.content.ComponentName
import android.content.pm.PackageManager
import edu.zjxu.jxucampushub.platform.invalidArgs
import edu.zjxu.jxucampushub.platform.requireStringArg
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * 动态切换 Android 桌面图标（`<activity-alias>`）。
 *
 * 原则：
 * 1. 只允许白名单内的已知 alias；
 * 2. 目标 alias 已唯一启用时直接返回 true，避免重复触发桌面重建图标；
 * 3. alias 切换排队到 [onActivityStopped] 才真正执行——在前台禁用「启动当前任务」
 *    的那个 launcher 组件，会被 HyperOS 等系统直接把任务退回桌面（DONT_KILL_APP
 *    也救不回来）；应用退到后台后任务已不可见，此时切换安全且桌面即时刷新；
 * 4. 切换时先启用新 alias 再禁用旧 alias，保证任意时刻至少有一个 LAUNCHER 入口；
 * 5. 深浅款靠 `drawable-night`/`values-night` 资源随系统夜间模式渲染，运行时
 *    不随主题模式翻转 alias。
 */
class AppIconChannelHandler(private val activity: Activity) {
    companion object {
        private const val CHANNEL = "edu.zjxu.jxucampushub/app_icon"
        private const val COMPONENT_PREFIX = "edu.zjxu.jxucampushub."
        private const val DEFAULT_ALIAS = "LauncherCeladon"

        private val ALL_ALIASES: List<String> = buildList {
            add("LauncherCeladon")
            add("LauncherCeladonDay")
            add("LauncherCrimson")
            add("LauncherRedBlack")
            for (i in 0 until 8) {
                add("LauncherTheme$i")
                add("LauncherTheme${i}Dark")
                add("LauncherTheme${i}Auto")
            }
        }
        private val VALID_ALIASES = ALL_ALIASES.toSet()
    }

    @Volatile
    private var pendingAlias: String? = null

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "setIconAlias" -> {
                    val alias = call.requireStringArg("alias", result) ?: return@setMethodCallHandler
                    if (alias !in VALID_ALIASES) {
                        result.invalidArgs("Unknown icon alias: $alias")
                        return@setMethodCallHandler
                    }
                    // 只排队，真正生效在 onActivityStopped；Dart 侧已持久化偏好，
                    // 即便进程在下次 onStop 前被杀，下次启动会重新同步。
                    pendingAlias = alias
                    result.success(true)
                }

                "getIconAlias" -> {
                    result.success(pendingAlias ?: currentEnabledAlias())
                }

                else -> result.notImplemented()
            }
        }
    }

    /** MainActivity.onStop 调用：应用退到后台后应用挂起的 alias 切换。 */
    fun onActivityStopped() {
        val alias = pendingAlias ?: return
        pendingAlias = null
        applyIconAlias(alias)
    }

    private fun componentFor(alias: String): ComponentName {
        return ComponentName(activity.packageName, "$COMPONENT_PREFIX$alias")
    }

    private fun isAliasEnabled(pm: PackageManager, alias: String): Boolean {
        return when (pm.getComponentEnabledSetting(componentFor(alias))) {
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED -> true
            PackageManager.COMPONENT_ENABLED_STATE_DISABLED -> false
            else -> alias == DEFAULT_ALIAS
        }
    }

    private fun currentEnabledAlias(): String {
        val pm = activity.packageManager
        return ALL_ALIASES.firstOrNull { isAliasEnabled(pm, it) } ?: DEFAULT_ALIAS
    }

    private fun applyIconAlias(targetAlias: String) {
        val pm = activity.packageManager
        val currentlyEnabled = ALL_ALIASES.filter { isAliasEnabled(pm, it) }
        if (currentlyEnabled.size == 1 && currentlyEnabled[0] == targetAlias) {
            return
        }

        // 先启用目标 alias，再禁用其余 alias，保证任意时刻至少有一个 LAUNCHER 入口。
        pm.setComponentEnabledSetting(
            componentFor(targetAlias),
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
            PackageManager.DONT_KILL_APP,
        )
        for (alias in ALL_ALIASES) {
            if (alias == targetAlias) continue
            if (isAliasEnabled(pm, alias)) {
                pm.setComponentEnabledSetting(
                    componentFor(alias),
                    PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                    PackageManager.DONT_KILL_APP,
                )
            }
        }
    }
}
