package edu.zjxu.jxucampushub.platform.deeplink

import android.content.Intent
import edu.zjxu.jxucampushub.platform.extractDeepLinkRaw
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * 深链通道：冷启动 intent 挂起到 Dart 消费；新 intent 直接下发。
 */
class DeepLinkChannelHandler {
    companion object {
        private const val CHANNEL = "edu.zjxu.jxucampushub/deeplink"
    }

    private var pendingDeepLink: String? = null
    private var channel: MethodChannel? = null

    fun captureInitialIntent(intent: Intent?) {
        pendingDeepLink = extractDeepLinkRaw(intent)
    }

    /** @return true 表示该 intent 是深链并已处理（或挂起），调用方应停止后续分发。 */
    fun onNewIntent(intent: Intent): Boolean {
        val raw = extractDeepLinkRaw(intent) ?: return false
        val current = channel
        if (current == null) {
            pendingDeepLink = raw
        } else {
            current.invokeMethod("onDeepLinkAction", raw)
        }
        return true
    }

    fun register(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "consumeInitialDeepLink" -> {
                        val raw = pendingDeepLink
                        pendingDeepLink = null
                        result.success(raw)
                    }

                    else -> result.notImplemented()
                }
            }
        }
    }
}
