package edu.zjxu.jxucampushub.platform

import android.content.Intent

/** 快捷方式 / 深链 intent 的公共协议常量（PRD §8）。 */
internal const val EXTRA_SHORTCUT_ACTION = "shortcut_action"
internal const val SHORTCUT_SCHEME = "jxucampushub"
internal const val SHORTCUT_HOST = "shortcut"
internal const val ACTION_HOST = "action"

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
