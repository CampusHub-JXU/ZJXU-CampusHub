package edu.zjxu.jxucampushub

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.Display
import edu.zjxu.jxucampushub.platform.app_icon.AppIconChannelHandler
import edu.zjxu.jxucampushub.platform.calendar.CalendarSyncChannelHandler
import edu.zjxu.jxucampushub.platform.deeplink.DeepLinkChannelHandler
import edu.zjxu.jxucampushub.platform.shortcut.ShortcutChannelHandler
import edu.zjxu.jxucampushub.platform.update.AppUpdateChannelHandler
import edu.zjxu.jxucampushub.platform.update.AppUpdateManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * 只负责平台通道注册与生命周期接线；各通道实现见 platform/ 下对应 handler。
 */
class MainActivity : FlutterActivity() {
    private val shortcutHandler = ShortcutChannelHandler(this)
    private val deepLinkHandler = DeepLinkChannelHandler()
    private val calendarHandler = CalendarSyncChannelHandler(this)
    private val appIconHandler = AppIconChannelHandler(this)
    private lateinit var appUpdateManager: AppUpdateManager

    override fun onCreate(savedInstanceState: Bundle?) {
        // FlutterActivity.onCreate calls configureFlutterEngine before returning.
        appUpdateManager = AppUpdateManager.get(applicationContext)
        super.onCreate(savedInstanceState)
        requestHighRefreshRate()
        shortcutHandler.captureInitialIntent(intent)
        deepLinkHandler.captureInitialIntent(intent)
        shortcutHandler.cleanupLegacyPaymentShortcut()
    }

    /**
     * 禁用 Flutter 框架自带的深链自动路由转发。
     *
     * 虽然 AndroidManifest 在 `.MainActivity` 上声明了
     * `flutter_deeplinking_enabled=false`，但本应用通过多个 `<activity-alias>`
     * 切换桌面图标；Android 上 `FlutterActivity.getMetaData()` 按当前启动的
     * `componentName` 读取 alias 元数据（不继承目标 Activity），缺失时
     * Flutter 3.x 默认返回 true，导致桌面小组件 / 快捷方式触发的
     * `jxucampushub://action/<id>` 被直接塞进 go_router 报 Page Not Found。
     * 在此处显式返回 false，确保所有图标别名在冷/热启动下都统一交由
     * [deepLinkHandler] → `CampusDeepLinkService` 白名单派发。
     */
    override fun shouldHandleDeeplinking(): Boolean = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val messenger = flutterEngine.dartExecutor.binaryMessenger
        shortcutHandler.register(messenger)
        deepLinkHandler.register(messenger)
        calendarHandler.register(messenger)
        AppUpdateChannelHandler(this, appUpdateManager).register(messenger)
    }

    override fun onResume() {
        super.onResume()
        requestHighRefreshRate()
        // 前台恢复：若受管更新已就绪且用户此前点过「更新」，补一次自动安装。
        appUpdateManager.onActivityResumed(this)
        // 同步多任务卡片图标与当前启用的桌面图标（含夜间模式切换后重新生效）。
        appIconHandler.syncTaskDescription()
    }

    /**
     * 在保持当前物理分辨率不变的前提下，请求该分辨率支持的最高刷新率
     * Display.Mode，避免 HyperOS / LTPO 等系统将 Flutter SurfaceView
     * 默认限制在 60Hz。
     */
    private fun requestHighRefreshRate() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        runCatching {
            val activeDisplay: Display? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                display
            } else {
                @Suppress("DEPRECATION")
                windowManager.defaultDisplay
            }
            val currentMode = activeDisplay?.mode ?: return
            val bestMode = activeDisplay.supportedModes
                .filter {
                    it.physicalWidth == currentMode.physicalWidth &&
                        it.physicalHeight == currentMode.physicalHeight
                }
                .maxByOrNull { it.refreshRate }
                ?: return
            val attrs = window.attributes
            if (attrs.preferredDisplayModeId != bestMode.modeId) {
                attrs.preferredDisplayModeId = bestMode.modeId
                window.attributes = attrs
            }
        }
    }

    override fun onPause() {
        appUpdateManager.detachActivity(this)
        super.onPause()
    }

    override fun onStop() {
        // 前台禁用「启动当前任务」的 launcher alias 会被系统退回桌面，
        // 退到后台后再应用挂起的图标切换。
        appIconHandler.onActivityStopped()
        super.onStop()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        // 先让日历通道回填挂起结果，再交回 super 保留其他插件的权限回调行为。
        calendarHandler.onRequestPermissionsResult(requestCode, grantResults)
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)

        if (deepLinkHandler.onNewIntent(intent)) {
            return
        }
        shortcutHandler.onNewIntent(intent)
    }
}
