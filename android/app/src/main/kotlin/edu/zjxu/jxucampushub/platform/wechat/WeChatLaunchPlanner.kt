package edu.zjxu.jxucampushub.platform.wechat

import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.content.pm.ResolveInfo
import android.net.Uri
import android.os.Build
import android.util.Log
import java.net.URI

/**
 * 「在微信中打开」决策层：URL 校验 → 安装检测 → 解析导出 handler → 启动。
 *
 * 本类只依赖 [WeChatLaunchGateway] 接口，不触碰 Flutter 引擎，也不直接调用
 * PackageManager / Activity，因此可以在本地 JVM 单测中用 fake gateway 覆盖
 * 全部分支；Android 细节集中在 [AndroidWeChatLaunchGateway]。
 *
 * 状态约定（Dart 侧按 status 降级并给复制兜底）：
 * - [STATUS_UNSUPPORTED_URL]：URL 为空、无法解析或 scheme 不在白名单。
 * - [STATUS_NOT_INSTALLED]：查不到 `com.tencent.mm` 包信息。
 * - [STATUS_NO_HANDLER]：微信内没有匹配且导出的组件可承接该 intent。
 * - [STATUS_LAUNCH_FAILED]：startActivity 抛异常（页面未交给微信）。
 * - [STATUS_LAUNCHED]：intent 已发出（不代表网页加载完成）。
 */
internal class WeChatLaunchPlanner(
    private val gateway: WeChatLaunchGateway,
) {
    fun openUrlInWeChat(url: String): WeChatLaunchResult {
        val normalizedUrl = normalizeWeChatLaunchUrl(url)
            ?: return WeChatLaunchResult(STATUS_UNSUPPORTED_URL, detail = "url has no http/https/weixin scheme")
        if (!gateway.isWeChatInstalled()) {
            return WeChatLaunchResult(STATUS_NOT_INSTALLED, detail = "com.tencent.mm package not found")
        }

        val target = gateway.resolveHandler(normalizedUrl)
            ?: return WeChatLaunchResult(STATUS_NO_HANDLER, route = ROUTE_ACTION_VIEW_WECHAT, detail = "no exported wechat component")

        return try {
            gateway.launch(target)
            WeChatLaunchResult(STATUS_LAUNCHED, route = ROUTE_ACTION_VIEW_WECHAT)
        } catch (e: ActivityNotFoundException) {
            launchFailed("ActivityNotFoundException", e, ROUTE_ACTION_VIEW_WECHAT)
        } catch (e: SecurityException) {
            launchFailed("SecurityException", e, ROUTE_ACTION_VIEW_WECHAT)
        } catch (e: Exception) {
            launchFailed(e.javaClass.simpleName.ifEmpty { "Exception" }, e, ROUTE_ACTION_VIEW_WECHAT)
        }
    }

    /**
     * 降级路径：网页直达不可用（no_handler）时，仅拉起微信 App 本体。
     * 先尝试 `weixin://` scheme 的导出 handler，再退到 launch intent。
     */
    fun openWeChatApp(): WeChatLaunchResult {
        if (!gateway.isWeChatInstalled()) {
            return WeChatLaunchResult(STATUS_NOT_INSTALLED, route = ROUTE_WECHAT_APP_SCHEME, detail = "com.tencent.mm package not found")
        }

        val target = gateway.resolveWeChatAppLaunch()
            ?: return WeChatLaunchResult(STATUS_NO_HANDLER, route = ROUTE_WECHAT_APP_SCHEME, detail = "no launchable wechat component")

        return try {
            gateway.launch(target)
            WeChatLaunchResult(STATUS_LAUNCHED, route = ROUTE_WECHAT_APP_SCHEME)
        } catch (e: ActivityNotFoundException) {
            launchFailed("ActivityNotFoundException", e, ROUTE_WECHAT_APP_SCHEME)
        } catch (e: SecurityException) {
            launchFailed("SecurityException", e, ROUTE_WECHAT_APP_SCHEME)
        } catch (e: Exception) {
            launchFailed(e.javaClass.simpleName.ifEmpty { "Exception" }, e, ROUTE_WECHAT_APP_SCHEME)
        }
    }

    private fun launchFailed(reason: String, e: Exception, route: String): WeChatLaunchResult {
        Log.w(TAG, "wechat launch failed: $reason")
        return WeChatLaunchResult(STATUS_LAUNCH_FAILED, route = route, detail = reason)
    }

    internal companion object {
        const val TAG = "WeChat"
        const val WECHAT_PACKAGE = "com.tencent.mm"

        const val STATUS_UNSUPPORTED_URL = "unsupported_url"
        const val STATUS_NOT_INSTALLED = "not_installed"
        const val STATUS_NO_HANDLER = "no_handler"
        const val STATUS_LAUNCHED = "launched"
        const val STATUS_LAUNCH_FAILED = "launch_failed"

        const val ROUTE_ACTION_VIEW_WECHAT = "action_view_wechat"
        const val ROUTE_WECHAT_APP_SCHEME = "wechat_app_scheme"

        private val allowedSchemes = setOf("http", "https", "weixin")

        /** 去掉首尾空白并校验 scheme 白名单；不接受隐式相对地址。 */
        internal fun normalizeWeChatLaunchUrl(url: String): String? {
            val trimmed = url.trim()
            if (trimmed.isEmpty()) return null
            val scheme = runCatching { URI(trimmed).scheme }.getOrNull()
                ?: return null
            if (scheme.lowercase() !in allowedSchemes) return null
            return trimmed
        }
    }
}

internal data class WeChatLaunchResult(
    val status: String,
    val route: String? = null,
    val detail: String? = null,
) {
    fun toChannelMap(): Map<String, Any?> = mapOf(
        "status" to status,
        "route" to route,
        "detail" to detail,
    )
}

/**
 * 平台能力接缝。resolved target 故意保持不透明（Android 实现包一层
 * [Intent]），JVM 单测可以用任意 token 模拟，无需 Robolectric。
 */
internal interface WeChatLaunchGateway {
    fun isWeChatInstalled(): Boolean

    /** 返回可被 [launch] 消费的句柄；无匹配或非导出组件时返回 null。 */
    fun resolveHandler(url: String): Any?

    /** 拉起微信 App 本体的目标；无可启动入口时返回 null。 */
    fun resolveWeChatAppLaunch(): Any?

    fun launch(resolved: Any)
}

/** [WeChatLaunchGateway] 的 Android 实现：包管理器探测 + ACTION_VIEW 解析 + 启动。 */
internal class AndroidWeChatLaunchGateway(
    private val activity: android.app.Activity,
) : WeChatLaunchGateway {

    private class ResolvedTarget(val intent: Intent)

    override fun isWeChatInstalled(): Boolean {
        val pm = activity.packageManager
        return try {
            getWeChatPackageInfo(pm)
            true
        } catch (e: PackageManager.NameNotFoundException) {
            false
        }
    }

    private fun getWeChatPackageInfo(pm: PackageManager): PackageInfo {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            pm.getPackageInfo(
                WeChatLaunchPlanner.WECHAT_PACKAGE,
                PackageManager.PackageInfoFlags.of(0),
            )
        } else {
            @Suppress("DEPRECATION")
            pm.getPackageInfo(WeChatLaunchPlanner.WECHAT_PACKAGE, 0)
        }
    }

    override fun resolveHandler(url: String): Any? {
        val uri = Uri.parse(url)
        val intent = Intent(Intent.ACTION_VIEW, uri).apply {
            setPackage(WeChatLaunchPlanner.WECHAT_PACKAGE)
            if (uri.scheme == "http" || uri.scheme == "https") {
                addCategory(Intent.CATEGORY_BROWSABLE)
            }
        }

        val resolveInfo = queryResolveActivity(intent) ?: return null
        val activityInfo = resolveInfo.activityInfo
        if (activityInfo == null || !activityInfo.exported) {
            Log.w(WeChatLaunchPlanner.TAG, "wechat handler missing or not exported")
            return null
        }
        return ResolvedTarget(intent)
    }

    override fun resolveWeChatAppLaunch(): Any? {
        // 首选：weixin:// scheme，要求 resolveActivity 命中且组件导出。
        val schemeIntent = Intent(Intent.ACTION_VIEW, Uri.parse("weixin://")).apply {
            setPackage(WeChatLaunchPlanner.WECHAT_PACKAGE)
        }
        val resolveInfo = queryResolveActivity(schemeIntent)
        val activityInfo = resolveInfo?.activityInfo
        if (activityInfo != null && activityInfo.exported) {
            return ResolvedTarget(schemeIntent)
        }

        // 兜底：launcher intent，要求组件存在。
        val launchIntent = try {
            activity.packageManager.getLaunchIntentForPackage(WeChatLaunchPlanner.WECHAT_PACKAGE)
        } catch (e: Exception) {
            Log.w(WeChatLaunchPlanner.TAG, "wechat launch intent lookup failed: ${e.javaClass.simpleName}")
            null
        } ?: return null

        if (launchIntent.component == null) {
            Log.w(WeChatLaunchPlanner.TAG, "wechat launch intent has no component")
            return null
        }
        return ResolvedTarget(launchIntent)
    }

    private fun queryResolveActivity(intent: Intent): ResolveInfo? {
        val pm = activity.packageManager
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            pm.resolveActivity(intent, PackageManager.ResolveInfoFlags.of(0))
        } else {
            @Suppress("DEPRECATION")
            pm.resolveActivity(intent, 0)
        }
    }

    override fun launch(resolved: Any) {
        val target = resolved as ResolvedTarget
        activity.startActivity(target.intent)
    }
}
