package edu.zjxu.jxucampushub.platform.shortcut

import android.app.Activity
import android.app.AppOpsManager
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
import android.provider.Settings
import edu.zjxu.jxucampushub.MainActivity
import edu.zjxu.jxucampushub.R
import edu.zjxu.jxucampushub.platform.ACTION_HOST
import edu.zjxu.jxucampushub.platform.EXTRA_SHORTCUT_ACTION
import edu.zjxu.jxucampushub.platform.SHORTCUT_SCHEME
import edu.zjxu.jxucampushub.platform.extractShortcutAction
import edu.zjxu.jxucampushub.platform.requireStringArg
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import kotlin.math.roundToInt

/**
 * 快捷方式通道：固定 / 动态快捷方式管理、MIUI 权限探测与初始动作分发。
 */
class ShortcutChannelHandler(private val activity: Activity) {
    companion object {
        private const val CHANNEL = "edu.zjxu.jxucampushub/shortcut"
        private const val CAMPUS_CARD_PAYMENT_ACTION = "campus-card-payment"
        private const val SHUATI_ACTION = "shuati-practice"
        private const val CAMPUS_CARD_PAYMENT_PINNED_SHORTCUT_ID = "campus_card_payment_pinned_v2"
        private const val SHUATI_PINNED_SHORTCUT_ID = "shuati_practice_pinned"
        private const val LEGACY_CAMPUS_CARD_PAYMENT_SHORTCUT_ID = "campus_card_payment_pinned"
        private const val MIUI_INSTALL_SHORTCUT_OP = 10017
    }

    private var pendingShortcutAction: String? = null
    private var channel: MethodChannel? = null

    fun captureInitialIntent(intent: Intent?) {
        pendingShortcutAction = extractShortcutAction(intent)
    }

    /** 清理旧版一卡通付款快捷方式（历史遗留 ID）。 */
    fun cleanupLegacyPaymentShortcut() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N_MR1) {
            return
        }

        val shortcutManager = activity.getSystemService(ShortcutManager::class.java) ?: return
        shortcutManager.removeDynamicShortcuts(
            listOf(LEGACY_CAMPUS_CARD_PAYMENT_SHORTCUT_ID),
        )
    }

    fun onNewIntent(intent: Intent) {
        val action = extractShortcutAction(intent) ?: return
        val current = channel
        if (current == null) {
            pendingShortcutAction = action
            return
        }

        current.invokeMethod("onShortcutAction", action)
    }

    fun register(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, CHANNEL).apply {
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

                    "requestPinnedShortcut" -> {
                        val actionId = call.requireStringArg("actionId", result)
                            ?: return@setMethodCallHandler
                        val title = call.argument<String>("title") ?: actionId
                        result.success(requestPinnedShortcut(actionId, title).code)
                    }

                    "syncDynamicShortcuts" -> {
                        val ids = call.argument<List<String>>("ids") ?: emptyList()
                        val titles = call.argument<List<String>>("titles") ?: emptyList()
                        result.success(syncDynamicShortcuts(ids, titles))
                    }

                    "openShortcutPermissionSettings" -> {
                        result.success(openShortcutPermissionSettings())
                    }

                    else -> result.notImplemented()
                }
            }
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
            shortLabel = activity.getString(R.string.shortcut_campus_card_payment_short_label),
            longLabel = activity.getString(R.string.shortcut_campus_card_payment_long_label),
        )
    }

    private fun requestShuatiShortcut(): ShortcutRequestResult {
        return requestShortcut(
            action = SHUATI_ACTION,
            shortcutId = SHUATI_PINNED_SHORTCUT_ID,
            shortcutIdsToReplace = listOf(SHUATI_PINNED_SHORTCUT_ID),
            shortLabel = activity.getString(R.string.shortcut_shuati_short_label),
            longLabel = activity.getString(R.string.shortcut_shuati_long_label),
        )
    }

    /** 通用固定快捷方式（PRD §40）：只按 Action ID + 标题重建，不再按功能定制。 */
    private fun requestPinnedShortcut(actionId: String, title: String): ShortcutRequestResult {
        val shortcutId = "pinned_" + actionId.replace(Regex("[^A-Za-z0-9_]"), "_")
        return requestShortcut(
            action = actionId,
            shortcutId = shortcutId,
            shortcutIdsToReplace = listOf(shortcutId),
            shortLabel = title,
            longLabel = title,
        )
    }

    /** 动态快捷方式（长按图标菜单）：按提交的 Action ID 重建。 */
    private fun syncDynamicShortcuts(ids: List<String>, titles: List<String>): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N_MR1) return false
        val shortcutManager = activity.getSystemService(ShortcutManager::class.java) ?: return false
        if (ids.isEmpty()) {
            shortcutManager.removeAllDynamicShortcuts()
            return true
        }

        val infos = ids.mapIndexed { index, actionId ->
            val title = titles.getOrNull(index) ?: actionId
            ShortcutInfo.Builder(activity, "dyn_" + actionId.replace(Regex("[^A-Za-z0-9_]"), "_"))
                .setShortLabel(title)
                .setLongLabel(title)
                .setIcon(buildShortcutIcon(actionId))
                .setIntent(createShortcutIntent(actionId))
                .build()
        }

        return try {
            shortcutManager.setDynamicShortcuts(infos)
            true
        } catch (e: Exception) {
            android.util.Log.e("Shortcut", "syncDynamicShortcuts failed: ${e.message}")
            false
        }
    }

    private fun requestShortcut(
        action: String,
        shortcutId: String,
        shortcutIdsToReplace: List<String>,
        shortLabel: String,
        longLabel: String,
    ): ShortcutRequestResult {
        val shortcutIntent = createShortcutIntent(action)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N_MR1) {
            val shortcutManager = activity.getSystemService(ShortcutManager::class.java)
                ?: return ShortcutRequestResult.UNSUPPORTED
            val shortcut = buildShortcutInfo(
                action = action,
                shortcutId = shortcutId,
                shortcutIntent = shortcutIntent,
                shortLabel = shortLabel,
                longLabel = longLabel,
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
        activity.sendBroadcast(
            Intent("com.android.launcher.action.INSTALL_SHORTCUT").apply {
                putExtra(Intent.EXTRA_SHORTCUT_INTENT, shortcutIntent)
                putExtra(
                    Intent.EXTRA_SHORTCUT_NAME,
                    shortLabel,
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
                        Intent.ShortcutIconResource.fromContext(activity, R.mipmap.ic_launcher)
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
            val appOps = activity.getSystemService(AppOpsManager::class.java) ?: return null
            val method = AppOpsManager::class.java.getMethod(
                "checkOpNoThrow",
                Int::class.javaPrimitiveType,
                Int::class.javaPrimitiveType,
                String::class.java,
            )
            method.invoke(appOps, opCode, activity.applicationInfo.uid, activity.packageName) as? Int
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
            data = Uri.parse("package:${activity.packageName}")
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
        putExtra("extra_pkgname", activity.packageName)
        putExtra("packageName", activity.packageName)
    }

    private fun tryStartActivity(intent: Intent): Boolean {
        return try {
            activity.startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun buildShortcutInfo(
        action: String,
        shortcutId: String,
        shortcutIntent: Intent,
        shortLabel: String,
        longLabel: String,
    ): ShortcutInfo {
        return ShortcutInfo.Builder(activity, shortcutId)
            .setShortLabel(shortLabel)
            .setLongLabel(longLabel)
            .setIcon(buildShortcutIcon(action))
            .setIntent(shortcutIntent)
            .build()
    }

    private fun buildShortcutIcon(action: String): Icon {
        if (action == SHUATI_ACTION) {
            return Icon.createWithBitmap(createShuatiShortcutIconBitmap())
        }
        return Icon.createWithResource(activity, R.mipmap.ic_launcher)
    }

    private fun createShuatiShortcutIconBitmap(): Bitmap {
        val density = activity.resources.displayMetrics.density
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
        val appIcon = activity.applicationInfo.loadIcon(activity.packageManager)
        appIcon.setBounds(appIconBounds)
        appIcon.draw(canvas)

        return bitmap
    }

    private fun createShortcutIntent(shortcutAction: String): Intent {
        return Intent(activity, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            // 新格式：jxucampushub://action/<action-id>（PRD §8 主格式）。
            data = Uri.parse("$SHORTCUT_SCHEME://$ACTION_HOST/$shortcutAction")
            putExtra(EXTRA_SHORTCUT_ACTION, shortcutAction)
            addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
    }

    private enum class ShortcutRequestResult(val code: String) {
        REQUESTED("requested"),
        UNSUPPORTED("unsupported"),
        REJECTED("rejected"),
    }
}
