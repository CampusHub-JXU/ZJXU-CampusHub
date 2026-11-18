package edu.zjxu.jxucampushub

import android.content.Intent
import android.os.Bundle
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
        shortcutHandler.captureInitialIntent(intent)
        deepLinkHandler.captureInitialIntent(intent)
        shortcutHandler.cleanupLegacyPaymentShortcut()
    }

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
        // 前台恢复：若受管更新已就绪且用户此前点过「更新」，补一次自动安装。
        appUpdateManager.onActivityResumed(this)
        // 同步多任务卡片图标与当前启用的桌面图标（含夜间模式切换后重新生效）。
        appIconHandler.syncTaskDescription()
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
