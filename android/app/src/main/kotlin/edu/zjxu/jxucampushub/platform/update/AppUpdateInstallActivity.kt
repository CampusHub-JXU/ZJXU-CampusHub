package edu.zjxu.jxucampushub.platform.update

import android.app.Activity
import android.os.Bundle
import android.util.Log

/**
 * 非导出安装中转 Activity（完成通知 / 前台自动打开进入）。
 *
 * 只接受与受管记录匹配的 requestKey；校验和安装由 manager 执行。
 * 缺未知来源权限时打开系统设置，返回后重新校验；拒绝授权不循环打开设置。
 */
class AppUpdateInstallActivity : Activity() {
    private val manager by lazy { AppUpdateManager.get(applicationContext) }
    private var resumed = false
    private var verifying = false
    private var permissionSettingsOpened = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        permissionSettingsOpened = savedInstanceState?.getBoolean("permissionSettingsOpened") ?: false
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putBoolean("permissionSettingsOpened", permissionSettingsOpened)
        super.onSaveInstanceState(outState)
    }

    override fun onResume() {
        super.onResume()
        resumed = true
        manager.attachActivity(this)
        if (verifying) return
        verifying = true
        val requestKey = intent?.getStringExtra(AppUpdateContract.EXTRA_REQUEST_KEY)
        manager.verifyAndInstall(this, requestKey) { launched ->
            verifying = false
            if (isFinishing || isDestroyed) return@verifyAndInstall
            if (!launched) {
                val state = try {
                    manager.queryActive()
                } catch (error: AppUpdateException) {
                    Log.w("AppUpdate", "cannot read managed update: ${error.category}")
                    null
                }
                if (!permissionSettingsOpened &&
                    state?.get("requestKey") == requestKey &&
                    state?.get("phase") == AppUpdatePhase.PERMISSION_REQUIRED &&
                    resumed
                ) {
                    permissionSettingsOpened = true
                    if (manager.openInstallPermissionSettings(this)) return@verifyAndInstall
                }
                Log.w("AppUpdate", "installer not launched from install activity")
            }
            finish()
        }
    }

    override fun onPause() {
        resumed = false
        manager.detachActivity(this)
        super.onPause()
    }
}
