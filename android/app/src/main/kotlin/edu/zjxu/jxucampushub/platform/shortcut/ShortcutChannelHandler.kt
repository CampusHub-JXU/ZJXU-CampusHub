package edu.zjxu.jxucampushub.platform.shortcut

import android.app.Activity
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
import edu.zjxu.jxucampushub.MainActivity
import edu.zjxu.jxucampushub.R
import edu.zjxu.jxucampushub.platform.ACTION_HOST
import edu.zjxu.jxucampushub.platform.EXTRA_SHORTCUT_ACTION
import edu.zjxu.jxucampushub.platform.MiuiShortcutPermission
import edu.zjxu.jxucampushub.platform.PinRequestResult
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
                        result.success(MiuiShortcutPermission.openPermissionSettings(activity))
                    }

                    else -> result.notImplemented()
                }
            }
        }
    }

    private fun requestCampusCardPaymentShortcut(): PinRequestResult {
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

    private fun requestShuatiShortcut(): PinRequestResult {
        return requestShortcut(
            action = SHUATI_ACTION,
            shortcutId = SHUATI_PINNED_SHORTCUT_ID,
            shortcutIdsToReplace = listOf(SHUATI_PINNED_SHORTCUT_ID),
            shortLabel = activity.getString(R.string.shortcut_shuati_short_label),
            longLabel = activity.getString(R.string.shortcut_shuati_long_label),
        )
    }

    /** 通用固定快捷方式（PRD §40）：只按 Action ID + 标题重建，不再按功能定制。 */
    private fun requestPinnedShortcut(actionId: String, title: String): PinRequestResult {
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
    ): PinRequestResult {
        val shortcutIntent = createShortcutIntent(action)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N_MR1) {
            val shortcutManager = activity.getSystemService(ShortcutManager::class.java)
                ?: return PinRequestResult.UNSUPPORTED
            val shortcut = buildShortcutInfo(
                action = action,
                shortcutId = shortcutId,
                shortcutIntent = shortcutIntent,
                shortLabel = shortLabel,
                longLabel = longLabel,
            )

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                if (!shortcutManager.isRequestPinShortcutSupported) {
                    return PinRequestResult.UNSUPPORTED
                }
                if (MiuiShortcutPermission.isDenied(activity)) {
                    android.util.Log.w(
                        "Shortcut",
                        "MIUI/HyperOS rejected shortcut permission before pin request: $action",
                    )
                    return PinRequestResult.REJECTED
                }
                shortcutManager.removeDynamicShortcuts(shortcutIdsToReplace)
                updateExistingShortcut(shortcutManager, shortcut)
                return if (shortcutManager.requestPinShortcut(shortcut, null)) {
                    PinRequestResult.REQUESTED
                } else {
                    PinRequestResult.REJECTED
                }
            }

            shortcutManager.removeDynamicShortcuts(shortcutIdsToReplace)
            shortcutManager.addDynamicShortcuts(listOf(shortcut))
            return PinRequestResult.REQUESTED
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
        return PinRequestResult.REQUESTED
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
}
