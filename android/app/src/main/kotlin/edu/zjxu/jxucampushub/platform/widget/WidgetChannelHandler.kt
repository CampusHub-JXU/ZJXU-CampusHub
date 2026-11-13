package edu.zjxu.jxucampushub.platform.widget

import android.app.Activity
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Intent
import android.content.res.ColorStateList
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.ProgressBar
import android.widget.RemoteViews
import android.widget.TextView
import edu.zjxu.jxucampushub.R
import edu.zjxu.jxucampushub.widget.CampusWidgetTheme
import java.io.ByteArrayOutputStream
import edu.zjxu.jxucampushub.platform.MiuiShortcutPermission
import edu.zjxu.jxucampushub.platform.PinRequestResult
import edu.zjxu.jxucampushub.platform.invalidArgs
import edu.zjxu.jxucampushub.widget.CampusWidgetKind
import edu.zjxu.jxucampushub.widget.CampusWidgetPinReceiver
import edu.zjxu.jxucampushub.widget.CampusWidgetStore
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.util.concurrent.Executors

/**
 * 桌面组件通道：只接收无凭据快照并请求固定组件。
 *
 * `requestPin` 参数 `size` ∈ small / medium / large，返回
 * `requested` / `unsupported` / `rejected` / `error`。`requested` 只表示请求已交给
 * launcher；组件落在哪一页 / 哪个格子由 launcher 决定，本 App 无法控制。
 */
class WidgetChannelHandler(private val activity: Activity) {
    companion object {
        private const val CHANNEL = "edu.zjxu.jxucampushub/widget"
        private const val TAG = "WidgetChannel"
    }

    // 单线程串行：pushSnapshot（SharedPreferences + 全部实例 RemoteViews 渲染 + 闹钟重排）与
    // getStatus（AppWidgetManager IPC）不占主线程；保持提交顺序，回复回主线程。
    private val ioExecutor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "widget-channel-io").apply { isDaemon = true }
    }

    private fun runOffMain(result: MethodChannel.Result, work: () -> Any?) {
        ioExecutor.execute {
            val outcome = runCatching(work)
            activity.runOnUiThread {
                outcome.fold(
                    onSuccess = { result.success(it) },
                    onFailure = { error ->
                        android.util.Log.w(TAG, "channel work failed: ${error.javaClass.simpleName}")
                        result.error("native_error", error.javaClass.simpleName, null)
                    },
                )
            }
        }
    }

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "pushSnapshot" -> {
                    val snapshot = call.argument<Map<String, Any?>>("snapshot")
                    if (snapshot == null) {
                        result.invalidArgs("snapshot is required")
                        return@setMethodCallHandler
                    }
                    val json = JSONObject(snapshot).toString()
                    runOffMain(result) { CampusWidgetStore.store(activity, json); null }
                }

                "requestPin" -> {
                    val kind = CampusWidgetKind.fromCode(call.argument<String>("size"))
                    if (kind == null) {
                        result.invalidArgs("size must be small, medium or large")
                        return@setMethodCallHandler
                    }
                    result.success(requestCampusWidgetPin(kind).code)
                }

                "isSupported" -> {
                    result.success(
                        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                            AppWidgetManager.getInstance(activity)
                                .isRequestPinAppWidgetSupported,
                    )
                }

                "getStatus" -> runOffMain(result) { readStatus() }

                "getPreview" -> {
                    val kind = CampusWidgetKind.fromCode(call.argument<String>("size"))
                    val widthPx = call.argument<Int>("widthPx")
                    if (kind == null || widthPx == null || widthPx <= 0) {
                        result.invalidArgs("size must be small, medium or large; widthPx > 0")
                        return@setMethodCallHandler
                    }
                    runOffMain(result) { renderPreviewPng(kind, widthPx) }
                }

                else -> result.notImplemented()
            }
        }
    }

    /**
     * 设置页用的只读状态：是否支持一键固定、每种尺寸已放置的实例数、原生最近一次
     * 收到快照的时间（毫秒；从未收到为 null）。读取失败的项按 0 / null 兜底。
     */
    private fun readStatus(): Map<String, Any?> {
        val manager = AppWidgetManager.getInstance(activity)
        val installed = CampusWidgetKind.values().associate { kind ->
            kind.code to runCatching {
                manager.getAppWidgetIds(ComponentName(activity, kind.providerClass)).size
            }.getOrDefault(0)
        }
        val pinSupported = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            runCatching { manager.isRequestPinAppWidgetSupported }.getOrDefault(false)
        val lastSnapshotAt = CampusWidgetStore.lastSnapshotAtMs(activity)
        return mapOf(
            "pinSupported" to pinSupported,
            "installed" to installed,
            "lastSnapshotAtMs" to lastSnapshotAt,
        )
    }

    /**
     * 把 launcher 组件选择器同款的 `previewLayout` 离屏渲染成 PNG（设置页预览用）。
     *
     * 视图只含 LinearLayout/TextView/ProgressBar/ImageView，`RemoteViews.apply` +
     * measure/layout/draw 不要求主线程。宽度按 Dart 传入的展示宽 [widthPx]（物理像素），
     * 高度按 `appwidget-provider` minHeight/minWidth 比例——字号保持真实 sp 规格，
     * 不做缩放失真；强调色用 [CampusWidgetTheme] 取与真实组件一致的值（快照
     * `theme.accent*` → 已保存 → `campus_widget_accent` 资源兜底），XML 里打
     * `accent_text` / `accent_bg` / `accent_progress` tag 的元素被改写。失败返回 null，
     * Dart 侧隐藏预览区，不阻塞页面。
     */
    private fun renderPreviewPng(kind: CampusWidgetKind, widthPx: Int): ByteArray? {
        val (layoutId, minW, minH) = when (kind) {
            CampusWidgetKind.SMALL ->
                Triple(R.layout.campus_widget_small_preview, 110, 110)
            CampusWidgetKind.MEDIUM ->
                Triple(R.layout.campus_widget_medium_preview, 250, 110)
            CampusWidgetKind.LARGE ->
                Triple(R.layout.campus_widget_large_preview, 250, 250)
        }
        return runCatching {
            val host = FrameLayout(activity)
            val view = RemoteViews(activity.packageName, layoutId).apply(activity, host)
            applyPreviewAccent(view)
            val heightPx = (widthPx.toLong() * minH / minW).toInt()
            view.measure(
                View.MeasureSpec.makeMeasureSpec(widthPx, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(heightPx, View.MeasureSpec.EXACTLY),
            )
            view.layout(0, 0, view.measuredWidth, view.measuredHeight)
            val bitmap = Bitmap.createBitmap(
                view.measuredWidth,
                view.measuredHeight,
                Bitmap.Config.ARGB_8888,
            )
            view.draw(Canvas(bitmap))
            ByteArrayOutputStream().also { stream ->
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
            }.toByteArray()
        }.onFailure { error ->
            android.util.Log.w(TAG, "renderPreviewPng failed: ${error.javaClass.simpleName}")
        }.getOrNull()
    }

    /** 预览的强调色改成与真实组件一致（主题色派生）；tint 用强调色 + 8%/14% 透明度。 */
    private fun applyPreviewAccent(root: View) {
        val palette = CampusWidgetTheme.palette(activity, null)
        val accent = palette.accent.pick(palette.night)
        val tint = palette.tint.pick(palette.night)
        val tintRadius = activity.resources.getDimension(R.dimen.campus_widget_inner_radius)
        applyAccentRecursive(root, accent, tint, tintRadius)
    }

    private fun applyAccentRecursive(view: View, accent: Int, tint: Int, tintRadius: Float) {
        when (view.tag) {
            "accent_text" -> (view as? TextView)?.setTextColor(accent)
            "accent_progress" -> (view as? ProgressBar)?.progressTintList =
                ColorStateList.valueOf(accent)
            "accent_bg" -> (view as? ImageView)?.setImageDrawable(
                GradientDrawable().apply {
                    shape = GradientDrawable.RECTANGLE
                    setColor(tint)
                    cornerRadius = tintRadius
                },
            )
        }
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                applyAccentRecursive(view.getChildAt(i), accent, tint, tintRadius)
            }
        }
    }

    private fun requestCampusWidgetPin(kind: CampusWidgetKind): PinRequestResult {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return PinRequestResult.UNSUPPORTED
        return try {
            val manager = AppWidgetManager.getInstance(activity)
            if (!manager.isRequestPinAppWidgetSupported) return PinRequestResult.UNSUPPORTED
            val accepted = manager.requestPinAppWidget(
                ComponentName(activity, kind.providerClass),
                null,
                pinSuccessCallback(kind),
            )
            if (accepted) {
                PinRequestResult.REQUESTED
            } else {
                // MIUI/HyperOS 的「桌面快捷方式」权限（app-op 10017）是否也限制组件固定未经验证，
                // 因此只作诊断日志，不再提前拦截；Dart 侧对 rejected 给出通用引导。
                if (MiuiShortcutPermission.isDenied(activity)) {
                    android.util.Log.w(TAG, "widget pin rejected with MIUI shortcut permission denied: ${kind.code}")
                }
                PinRequestResult.REJECTED
            }
        } catch (error: Exception) {
            android.util.Log.w(TAG, "requestPinAppWidget failed: ${error.javaClass.simpleName}")
            PinRequestResult.ERROR
        }
    }

    /** 用户在桌面确认添加后，launcher 触发该广播（显式组件、不可变）。 */
    private fun pinSuccessCallback(kind: CampusWidgetKind): PendingIntent {
        val intent = Intent(activity, CampusWidgetPinReceiver::class.java).apply {
            action = CampusWidgetPinReceiver.ACTION_PIN_RESULT
            putExtra(CampusWidgetPinReceiver.EXTRA_SIZE, kind.code)
        }
        return PendingIntent.getBroadcast(
            activity,
            kind.ordinal,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}
