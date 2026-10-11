package edu.zjxu.jxucampushub

import android.content.Intent
import android.os.Bundle
import edu.zjxu.jxucampushub.platform.calendar.CalendarSyncChannelHandler
import edu.zjxu.jxucampushub.platform.deeplink.DeepLinkChannelHandler
import edu.zjxu.jxucampushub.platform.download.DownloadChannelHandler
import edu.zjxu.jxucampushub.platform.shortcut.ShortcutChannelHandler
import edu.zjxu.jxucampushub.platform.system_settings.SystemSettingsChannelHandler
import edu.zjxu.jxucampushub.platform.update.AppUpdateChannelHandler
import edu.zjxu.jxucampushub.platform.update.AppUpdateManager
import edu.zjxu.jxucampushub.platform.wechat.WeChatChannelHandler
import edu.zjxu.jxucampushub.platform.widget.WidgetChannelHandler
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * 只负责平台通道注册与生命周期接线；各通道实现见 platform/ 下对应 handler。
 */
class MainActivity : FlutterActivity() {
    private val shortcutHandler = ShortcutChannelHandler(this)
    private val deepLinkHandler = DeepLinkChannelHandler()
    private val calendarHandler = CalendarSyncChannelHandler(this)
    private lateinit var appUpdateManager: AppUpdateManager

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        shortcutHandler.captureInitialIntent(intent)
        deepLinkHandler.captureInitialIntent(intent)
        shortcutHandler.cleanupLegacyPaymentShortcut()
        appUpdateManager = AppUpdateManager.get(applicationContext)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val messenger = flutterEngine.dartExecutor.binaryMessenger
        WeChatChannelHandler(this).register(messenger)
        shortcutHandler.register(messenger)
        deepLinkHandler.register(messenger)
        WidgetChannelHandler(this).register(messenger)
        DownloadChannelHandler(this).register(messenger)
        SystemSettingsChannelHandler(this).register(messenger)
        calendarHandler.register(messenger)
        AppUpdateChannelHandler(this, appUpdateManager).register(messenger)
    }

    override fun onResume() {
        super.onResume()
        // 前台恢复：若受管更新已就绪且用户此前点过「更新」，补一次自动安装。
        appUpdateManager.onActivityResumed(this)
    }

    override fun onPause() {
        appUpdateManager.detachActivity(this)
        super.onPause()
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
