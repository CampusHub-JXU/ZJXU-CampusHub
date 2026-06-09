package edu.zjxu.jxucampushub

import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val WECHAT_CHANNEL = "edu.zjxu.jxucampushub/wechat"
        private const val SHORTCUT_CHANNEL = "edu.zjxu.jxucampushub/shortcut"
        private const val EXTRA_SHORTCUT_ACTION = "shortcut_action"
        private const val SHORTCUT_SCHEME = "jxucampushub"
        private const val SHORTCUT_HOST = "shortcut"
        private const val CAMPUS_CARD_PAYMENT_ACTION = "campus-card-payment"
        private const val SHUATI_ACTION = "shuati-practice"
        private const val CAMPUS_CARD_PAYMENT_PINNED_SHORTCUT_ID = "campus_card_payment_pinned_v2"
        private const val SHUATI_PINNED_SHORTCUT_ID = "shuati_practice_pinned"
        private const val LEGACY_CAMPUS_CARD_PAYMENT_SHORTCUT_ID = "campus_card_payment_pinned"
    }

    private var pendingShortcutAction: String? = null
    private var shortcutChannel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        pendingShortcutAction = extractShortcutAction(intent)
        cleanupLegacyPaymentShortcut()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            WECHAT_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "openUrlInWeChat" -> {
                    val url = call.argument<String>("url")
                    if (url.isNullOrBlank()) {
                        result.error("invalid_args", "url is required", null)
                        return@setMethodCallHandler
                    }
                    result.success(openUrlInWeChat(url))
                }
                else -> result.notImplemented()
            }
        }

        shortcutChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SHORTCUT_CHANNEL,
        ).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "consumeInitialShortcutAction" -> {
                        val action = pendingShortcutAction
                        pendingShortcutAction = null
                        result.success(action)
                    }

                    "requestCampusCardPaymentShortcut" -> {
                        result.success(requestCampusCardPaymentShortcut().code)
                    }

                    "requestShuatiShortcut" -> {
                        result.success(requestShuatiShortcut().code)
                    }

                    "openShortcutPermissionSettings" -> {
                        result.success(openShortcutPermissionSettings())
                    }

                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)

        val action = extractShortcutAction(intent) ?: return
        val channel = shortcutChannel
        if (channel == null) {
            pendingShortcutAction = action
            return
        }

        channel.invokeMethod("onShortcutAction", action)
    }

    private fun openUrlInWeChat(url: String): Boolean {
        // 直接指定微信内置浏览器 Activity，绕过 intent-filter 解析问题
        val intent = Intent().apply {
            action = Intent.ACTION_VIEW
            data = Uri.parse(url)
            setClassName(
                "com.tencent.mm",
                "com.tencent.mm.plugin.webview.ui.tools.SDKWebViewUI",
            )
        }
        return try {
            startActivity(intent)
            true
        } catch (e: ActivityNotFoundException) {
            android.util.Log.w("WeChat", "SDKWebViewUI not found, trying package route")
            val fallback = Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
                setPackage("com.tencent.mm")
            }
            try {
                startActivity(fallback)
                true
            } catch (_: Exception) {
                false
            }
        } catch (e: Exception) {
            android.util.Log.e("WeChat", "Failed: ${e.javaClass.simpleName}: ${e.message}")
            false
        }
    }

    private fun requestCampusCardPaymentShortcut(): ShortcutRequestResult {
        return requestShortcut(
            action = CAMPUS_CARD_PAYMENT_ACTION,
            shortcutId = CAMPUS_CARD_PAYMENT_PINNED_SHORTCUT_ID,
            shortcutIdsToReplace = listOf(
                CAMPUS_CARD_PAYMENT_PINNED_SHORTCUT_ID,
                LEGACY_CAMPUS_CARD_PAYMENT_SHORTCUT_ID,
            ),
            shortLabelRes = R.string.shortcut_campus_card_payment_short_label,
            longLabelRes = R.string.shortcut_campus_card_payment_long_label,
        )
    }

    private fun requestShuatiShortcut(): ShortcutRequestResult {
        return requestShortcut(
            action = SHUATI_ACTION,
            shortcutId = SHUATI_PINNED_SHORTCUT_ID,
            shortcutIdsToReplace = listOf(SHUATI_PINNED_SHORTCUT_ID),
            shortLabelRes = R.string.shortcut_shuati_short_label,
            longLabelRes = R.string.shortcut_shuati_long_label,
        )
    }

    private fun requestShortcut(
        action: String,
        shortcutId: String,
        shortcutIdsToReplace: List<String>,
        shortLabelRes: Int,
        longLabelRes: Int,
    ): ShortcutRequestResult {
        val shortcutIntent = createShortcutIntent(action)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N_MR1) {
            val shortcutManager = getSystemService(ShortcutManager::class.java)
                ?: return ShortcutRequestResult.UNSUPPORTED
            val shortcut = buildShortcutInfo(
                shortcutId = shortcutId,
                shortcutIntent = shortcutIntent,
                shortLabelRes = shortLabelRes,
                longLabelRes = longLabelRes,
            )

            shortcutManager.removeDynamicShortcuts(shortcutIdsToReplace)
            shortcutManager.addDynamicShortcuts(listOf(shortcut))

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                if (!shortcutManager.isRequestPinShortcutSupported) {
                    return ShortcutRequestResult.UNSUPPORTED
                }
                return if (shortcutManager.requestPinShortcut(shortcut, null)) {
                    ShortcutRequestResult.REQUESTED
                } else {
                    ShortcutRequestResult.REJECTED
                }
            }

            return ShortcutRequestResult.REQUESTED
        }

        @Suppress("DEPRECATION")
        sendBroadcast(
            Intent("com.android.launcher.action.INSTALL_SHORTCUT").apply {
                putExtra(Intent.EXTRA_SHORTCUT_INTENT, shortcutIntent)
                putExtra(
                    Intent.EXTRA_SHORTCUT_NAME,
                    getString(shortLabelRes),
                )
                putExtra(
                    Intent.EXTRA_SHORTCUT_ICON_RESOURCE,
                    Intent.ShortcutIconResource.fromContext(this@MainActivity, R.mipmap.ic_launcher),
                )
                putExtra("duplicate", false)
            },
        )
        return ShortcutRequestResult.REQUESTED
    }

    private fun openShortcutPermissionSettings(): Boolean {
        val miuiIntent = Intent("miui.intent.action.APP_PERM_EDITOR").apply {
            setClassName(
                "com.miui.securitycenter",
                "com.miui.permcenter.permissions.PermissionsEditorActivity",
            )
            putExtra("extra_pkgname", packageName)
            putExtra("packageName", packageName)
        }
        if (tryStartActivity(miuiIntent)) {
            return true
        }

        val appDetailsIntent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
            data = Uri.parse("package:$packageName")
        }
        return tryStartActivity(appDetailsIntent)
    }

    private fun tryStartActivity(intent: Intent): Boolean {
        return try {
            startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun cleanupLegacyPaymentShortcut() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N_MR1) {
            return
        }

        val shortcutManager = getSystemService(ShortcutManager::class.java) ?: return
        shortcutManager.removeDynamicShortcuts(
            listOf(LEGACY_CAMPUS_CARD_PAYMENT_SHORTCUT_ID),
        )
    }

    private fun buildShortcutInfo(
        shortcutId: String,
        shortcutIntent: Intent,
        shortLabelRes: Int,
        longLabelRes: Int,
    ): ShortcutInfo {
        return ShortcutInfo.Builder(this, shortcutId)
            .setShortLabel(getString(shortLabelRes))
            .setLongLabel(getString(longLabelRes))
            .setIcon(Icon.createWithResource(this, R.mipmap.ic_launcher))
            .setIntent(shortcutIntent)
            .build()
    }

    private fun createShortcutIntent(shortcutAction: String): Intent {
        return Intent(this, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            data = Uri.parse("$SHORTCUT_SCHEME://$SHORTCUT_HOST/$shortcutAction")
            putExtra(EXTRA_SHORTCUT_ACTION, shortcutAction)
            addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
    }

    private fun extractShortcutAction(intent: Intent?): String? {
        if (intent == null) return null

        val extraAction = intent.getStringExtra(EXTRA_SHORTCUT_ACTION)?.trim()
        if (!extraAction.isNullOrEmpty()) {
            return extraAction
        }

        val data = intent.data ?: return null
        if (data.scheme != SHORTCUT_SCHEME || data.host != SHORTCUT_HOST) {
            return null
        }

        return data.lastPathSegment?.trim()?.takeIf { it.isNotEmpty() }
    }

    private enum class ShortcutRequestResult(val code: String) {
        REQUESTED("requested"),
        UNSUPPORTED("unsupported"),
        REJECTED("rejected"),
    }
}
