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
 * 3. 切换时先启用新 alias 再禁用旧 alias（DONT_KILL_APP），防止桌面图标瞬间丢失。
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

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "setIconAlias" -> {
                    val alias = call.requireStringArg("alias", result) ?: return@setMethodCallHandler
                    if (alias !in VALID_ALIASES) {
                        result.invalidArgs("Unknown icon alias: $alias")
                        return@setMethodCallHandler
                    }
                    result.success(applyIconAlias(alias))
                }

                "getIconAlias" -> {
                    result.success(currentEnabledAlias())
                }

                else -> result.notImplemented()
            }
        }
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

    private fun applyIconAlias(targetAlias: String): Boolean {
        val pm = activity.packageManager
        val currentlyEnabled = ALL_ALIASES.filter { isAliasEnabled(pm, it) }
        if (currentlyEnabled.size == 1 && currentlyEnabled[0] == targetAlias) {
            return true
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
        return true
    }
}
