package edu.zjxu.jxucampushub.platform

import android.content.Intent
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** 快捷方式 / 深链 intent 的公共协议常量（PRD §8）。 */
internal const val EXTRA_SHORTCUT_ACTION = "shortcut_action"
internal const val SHORTCUT_SCHEME = "jxucampushub"
internal const val SHORTCUT_HOST = "shortcut"
internal const val ACTION_HOST = "action"

/** 各通道共用的参数校验失败错误码（Dart 侧按该码降级）。 */
internal const val ERROR_INVALID_ARGS = "invalid_args"

/** 回复 [ERROR_INVALID_ARGS]；[message] 为不含 PII 的固定说明。 */
internal fun MethodChannel.Result.invalidArgs(message: String) {
    error(ERROR_INVALID_ARGS, message, null)
}

/**
 * 取非空白 String 参数；缺失/空白时回复 `invalid_args`（`"<name> is required"`）并返回 null，
 * 调用方应随即 `return@setMethodCallHandler`。
 */
internal fun MethodCall.requireStringArg(name: String, result: MethodChannel.Result): String? {
    val value = argument<String>(name)
    if (value.isNullOrBlank()) {
        result.invalidArgs("$name is required")
        return null
    }
    return value
}

/**
 * 深链原始串（只允许本 scheme + action/shortcut host）；Dart 侧再经
 * CampusDeepLink 白名单解析。
 */
internal fun extractDeepLinkRaw(intent: Intent?): String? {
    if (intent == null) return null

    val data = intent.data
    if (data != null &&
        data.scheme == SHORTCUT_SCHEME &&
        (data.host == ACTION_HOST || data.host == SHORTCUT_HOST)
    ) {
        return data.toString()
    }

    val extraAction = intent.getStringExtra(EXTRA_SHORTCUT_ACTION)?.trim()
    if (!extraAction.isNullOrEmpty()) {
        return "$SHORTCUT_SCHEME://$ACTION_HOST/$extraAction"
    }

    return null
}

internal fun extractShortcutAction(intent: Intent?): String? {
    if (intent == null) return null

    val extraAction = intent.getStringExtra(EXTRA_SHORTCUT_ACTION)?.trim()
    if (!extraAction.isNullOrEmpty()) {
        return extraAction
    }

    val data = intent.data ?: return null
    if (data.scheme != SHORTCUT_SCHEME ||
        (data.host != SHORTCUT_HOST && data.host != ACTION_HOST)
    ) {
        return null
    }

    return data.lastPathSegment?.trim()?.takeIf { it.isNotEmpty() }
}
