package edu.zjxu.jxucampushub

import android.app.AppOpsManager
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.math.roundToInt

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
        private const val MIUI_INSTALL_SHORTCUT_OP = 10017
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
        if (packageManager.getLaunchIntentForPackage("com.tencent.mm") == null) {
            android.util.Log.w("WeChat", "WeChat is not installed")
            return false
        }

        val uri = Uri.parse(url)
        val attempts = listOf(
            Intent(Intent.ACTION_VIEW, uri).apply {
                setPackage("com.tencent.mm")
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
            setClassName("com.tencent.mm", className)
            addCategory(Intent.CATEGORY_BROWSABLE)
            putExtra("rawUrl", url)
        }
    }

    private fun tryStartWeChatIntent(intent: Intent, label: String): Boolean {
        return try {
            startActivity(intent)
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
                action = action,
                shortcutId = shortcutId,
                shortcutIntent = shortcutIntent,
                shortLabelRes = shortLabelRes,
                longLabelRes = longLabelRes,
            )

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                if (!shortcutManager.isRequestPinShortcutSupported) {
                    return ShortcutRequestResult.UNSUPPORTED
                }
                if (isMiuiShortcutPermissionDenied()) {
                    android.util.Log.w(
                        "Shortcut",
                        "MIUI/HyperOS rejected shortcut permission before pin request: $action",
                    )
                    return ShortcutRequestResult.REJECTED
                }
                shortcutManager.removeDynamicShortcuts(shortcutIdsToReplace)
                updateExistingShortcut(shortcutManager, shortcut)
                return if (shortcutManager.requestPinShortcut(shortcut, null)) {
                    ShortcutRequestResult.REQUESTED
                } else {
                    ShortcutRequestResult.REJECTED
                }
            }

            shortcutManager.removeDynamicShortcuts(shortcutIdsToReplace)
            shortcutManager.addDynamicShortcuts(listOf(shortcut))
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
                    if (action == SHUATI_ACTION) {
                        Intent.EXTRA_SHORTCUT_ICON
                    } else {
                        Intent.EXTRA_SHORTCUT_ICON_RESOURCE
                    },
                    if (action == SHUATI_ACTION) {
                        createShuatiShortcutIconBitmap()
                    } else {
                        Intent.ShortcutIconResource.fromContext(this@MainActivity, R.mipmap.ic_launcher)
                    },
                )
                putExtra("duplicate", false)
            },
        )
        return ShortcutRequestResult.REQUESTED
    }

    private fun updateExistingShortcut(
        shortcutManager: ShortcutManager,
        shortcut: ShortcutInfo,
    ) {
        try {
            shortcutManager.updateShortcuts(listOf(shortcut))
        } catch (error: Throwable) {
            android.util.Log.d(
                "Shortcut",
                "Unable to update existing shortcut icon: ${error.javaClass.simpleName}",
            )
        }
    }

    private fun isMiuiShortcutPermissionDenied(): Boolean {
        if (!isMiuiLikeDevice()) {
            return false
        }

        val mode = readMiuiAppOpMode(MIUI_INSTALL_SHORTCUT_OP) ?: return false
        return mode != AppOpsManager.MODE_ALLOWED && mode != AppOpsManager.MODE_DEFAULT
    }

    private fun isMiuiLikeDevice(): Boolean {
        val manufacturer = Build.MANUFACTURER.lowercase()
        val brand = Build.BRAND.lowercase()
        return manufacturer.contains("xiaomi") ||
            manufacturer.contains("redmi") ||
            manufacturer.contains("poco") ||
            brand.contains("xiaomi") ||
            brand.contains("redmi") ||
            brand.contains("poco")
    }

    private fun readMiuiAppOpMode(opCode: Int): Int? {
        return try {
            val appOps = getSystemService(AppOpsManager::class.java) ?: return null
            val method = AppOpsManager::class.java.getMethod(
                "checkOpNoThrow",
                Int::class.javaPrimitiveType,
                Int::class.javaPrimitiveType,
                String::class.java,
            )
            method.invoke(appOps, opCode, applicationInfo.uid, packageName) as? Int
        } catch (error: Throwable) {
            android.util.Log.d(
                "Shortcut",
                "Unable to read MIUI shortcut app-op: ${error.javaClass.simpleName}",
            )
            null
        }
    }

    private fun openShortcutPermissionSettings(): Boolean {
        for (intent in miuiPermissionSettingsIntents()) {
            if (tryStartActivity(intent)) {
                return true
            }
        }

        val appDetailsIntent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
            data = Uri.parse("package:$packageName")
        }
        return tryStartActivity(appDetailsIntent)
    }

    private fun miuiPermissionSettingsIntents(): List<Intent> {
        val actions = listOf(
            "miui.intent.action.APP_PERM_EDITOR",
            "miui.intent.action.APP_PERM_EDITOR_PRIVATE",
        )
        val classes = listOf(
            "com.miui.permcenter.permissions.PermissionsEditorActivity",
            "com.miui.permcenter.permissions.AppPermissionsEditorActivity",
        )
        val intents = mutableListOf<Intent>()

        for (action in actions) {
            for (className in classes) {
                intents += Intent(action).apply {
                    setClassName("com.miui.securitycenter", className)
                    addMiuiPackageExtras()
                }
            }
            intents += Intent(action).apply {
                setPackage("com.miui.securitycenter")
                addMiuiPackageExtras()
            }
        }

        return intents
    }

    private fun Intent.addMiuiPackageExtras() {
        putExtra("extra_pkgname", packageName)
        putExtra("packageName", packageName)
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
        action: String,
        shortcutId: String,
        shortcutIntent: Intent,
        shortLabelRes: Int,
        longLabelRes: Int,
    ): ShortcutInfo {
        return ShortcutInfo.Builder(this, shortcutId)
            .setShortLabel(getString(shortLabelRes))
            .setLongLabel(getString(longLabelRes))
            .setIcon(buildShortcutIcon(action))
            .setIntent(shortcutIntent)
            .build()
    }

    private fun buildShortcutIcon(action: String): Icon {
        if (action == SHUATI_ACTION) {
            return Icon.createWithBitmap(createShuatiShortcutIconBitmap())
        }
        return Icon.createWithResource(this, R.mipmap.ic_launcher)
    }

    private fun createShuatiShortcutIconBitmap(): Bitmap {
        val density = resources.displayMetrics.density
        val size = (108 * density).roundToInt().coerceAtLeast(108)
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)

        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        val cornerRadius = size * 0.2f
        val iconBounds = RectF(0f, 0f, size.toFloat(), size.toFloat())
        paint.color = Color.rgb(37, 99, 235)
        canvas.drawRoundRect(iconBounds, cornerRadius, cornerRadius, paint)

        paint.color = Color.WHITE
        paint.textAlign = Paint.Align.CENTER
        paint.typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        paint.textSize = size * 0.56f
        val textBaseline = size / 2f - (paint.descent() + paint.ascent()) / 2f
        canvas.drawText("刷", size / 2f, textBaseline, paint)

        val badgeSize = (size * 0.36f).roundToInt()
        val badgeMargin = (size * 0.06f).roundToInt()
        val badgeLeft = size - badgeSize - badgeMargin
        val badgeTop = size - badgeSize - badgeMargin
        val badgeCenterX = badgeLeft + badgeSize / 2f
        val badgeCenterY = badgeTop + badgeSize / 2f
        val badgeRadius = badgeSize / 2f

        paint.style = Paint.Style.FILL
        paint.color = Color.argb(45, 0, 0, 0)
        canvas.drawCircle(
            badgeCenterX,
            badgeCenterY + badgeSize * 0.05f,
            badgeRadius * 1.08f,
            paint,
        )
        paint.color = Color.WHITE
        canvas.drawCircle(badgeCenterX, badgeCenterY, badgeRadius, paint)

        val appIconInset = (badgeSize * 0.14f).roundToInt()
        val appIconBounds = Rect(
            badgeLeft + appIconInset,
            badgeTop + appIconInset,
            badgeLeft + badgeSize - appIconInset,
            badgeTop + badgeSize - appIconInset,
        )
        val appIcon = applicationInfo.loadIcon(packageManager)
        appIcon.setBounds(appIconBounds)
        appIcon.draw(canvas)

        return bitmap
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
