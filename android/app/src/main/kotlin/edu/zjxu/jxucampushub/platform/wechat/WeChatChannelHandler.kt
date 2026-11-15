package edu.zjxu.jxucampushub.platform.wechat

import android.app.Activity
import io.flutter.plugin.common.BinaryMessenger
import edu.zjxu.jxucampushub.platform.requireStringArg
import io.flutter.plugin.common.MethodChannel

/**
 * 微信跳转通道：结果以 Map 返回（status/route/detail）。
 * status == launched 仅表示 intent 已发出，不代表页面加载成功。
 */
class WeChatChannelHandler(private val activity: Activity) {
    private val planner = WeChatLaunchPlanner(AndroidWeChatLaunchGateway(activity))

    companion object {
        private const val CHANNEL = "edu.zjxu.jxucampushub/wechat"
    }

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "openUrlInWeChat" -> {
                    val url = call.requireStringArg("url", result)
                        ?: return@setMethodCallHandler
                    result.success(openUrlInWeChat(url))
                }

                "openWeChatApp" -> {
                    result.success(openWeChatApp())
                }

                else -> result.notImplemented()
            }
        }
    }

    internal fun openUrlInWeChat(url: String): Map<String, Any?> {
        return planner.openUrlInWeChat(url).toChannelMap()
    }

    internal fun openWeChatApp(): Map<String, Any?> {
        return planner.openWeChatApp().toChannelMap()
    }
}
