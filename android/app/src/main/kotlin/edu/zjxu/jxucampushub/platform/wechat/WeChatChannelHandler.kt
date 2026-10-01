package edu.zjxu.jxucampushub.platform.wechat

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import io.flutter.plugin.common.BinaryMessenger
import edu.zjxu.jxucampushub.platform.requireStringArg
import io.flutter.plugin.common.MethodChannel

/**
 * 微信跳转通道：返回值仅表示 intent 已发出，不代表页面加载成功。
 */
class WeChatChannelHandler(private val activity: Activity) {
    companion object {
        private const val CHANNEL = "edu.zjxu.jxucampushub/wechat"
        private const val WECHAT_PACKAGE = "com.tencent.mm"
    }

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "openUrlInWeChat" -> {
                    val url = call.requireStringArg("url", result)
                        ?: return@setMethodCallHandler
                    result.success(openUrlInWeChat(url))
                }

                else -> result.notImplemented()
            }
        }
    }

    private fun openUrlInWeChat(url: String): Boolean {
        if (activity.packageManager.getLaunchIntentForPackage(WECHAT_PACKAGE) == null) {
            android.util.Log.w("WeChat", "WeChat is not installed")
            return false
        }

        val uri = Uri.parse(url)
        val attempts = listOf(
            Intent(Intent.ACTION_VIEW, uri).apply {
                setPackage(WECHAT_PACKAGE)
                addCategory(Intent.CATEGORY_BROWSABLE)
            },
            createWeChatWebViewIntent(url, "com.tencent.mm.plugin.webview.ui.tools.SDKWebViewUI"),
            createWeChatWebViewIntent(url, "com.tencent.mm.plugin.webview.ui.tools.WebViewUI"),
        )

        for ((index, intent) in attempts.withIndex()) {
            if (tryStartWeChatIntent(intent, "url-attempt-$index")) return true
        }

        // Opening the WeChat home screen does not deliver the URL. Keep the
        // caller in the app so it can offer copying the link instead.
        return false
    }

    private fun createWeChatWebViewIntent(url: String, className: String): Intent {
        return Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
            setClassName(WECHAT_PACKAGE, className)
            addCategory(Intent.CATEGORY_BROWSABLE)
            putExtra("rawUrl", url)
        }
    }

    private fun tryStartWeChatIntent(intent: Intent, label: String): Boolean {
        return try {
            activity.startActivity(intent)
            android.util.Log.i("WeChat", "Started WeChat route: $label")
            true
        } catch (e: ActivityNotFoundException) {
            android.util.Log.w("WeChat", "Route not found: $label")
            false
        } catch (e: SecurityException) {
            android.util.Log.w("WeChat", "Route not exported: $label")
            false
        } catch (e: Exception) {
            android.util.Log.e("WeChat", "Route failed: $label, ${e.javaClass.simpleName}: ${e.message}")
            false
        }
    }
}
