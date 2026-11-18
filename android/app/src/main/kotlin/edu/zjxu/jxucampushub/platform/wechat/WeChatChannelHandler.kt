package edu.zjxu.jxucampushub.platform.wechat

import android.app.Activity
import androidx.annotation.Keep

@Keep
class WeChatJniResult(
    val status: String,
    val route: String?,
    val detail: String?,
)

/**
 * 微信跳转原生服务（由 Dart 经 JNIgen 直调）。
 * status == launched 仅表示 intent 已发出，不代表页面加载成功。
 */
@Keep
class WeChatChannelHandler(private val activity: Activity) {
    private val planner = WeChatLaunchPlanner(AndroidWeChatLaunchGateway(activity))

    @Keep
    fun openUrlInWeChat(url: String): WeChatJniResult {
        val result = planner.openUrlInWeChat(url)
        return WeChatJniResult(
            status = result.status,
            route = result.route,
            detail = result.detail,
        )
    }

    @Keep
    fun openWeChatApp(): WeChatJniResult {
        val result = planner.openWeChatApp()
        return WeChatJniResult(
            status = result.status,
            route = result.route,
            detail = result.detail,
        )
    }
}
