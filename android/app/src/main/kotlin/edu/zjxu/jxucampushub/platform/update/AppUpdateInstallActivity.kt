package edu.zjxu.jxucampushub.platform.update

import android.app.Activity
import android.os.Bundle
import android.util.Log

/**
 * 非导出安装中转 Activity（完成通知 / 前台自动打开进入）。
 *
 * - 不信任 Intent 中的任意 path / id：只取不透明 `requestKey`，与原生持久化记录
 *   核对一致后才校验文件并调起系统安装器；
 * - 校验（size / sha256 / 包名 / 签名 / versionCode / ABI）在后台线程执行，
 *   完成后立即 finish，绝不驻留；
 * - 缺「未知来源」权限时静默结束（状态由 manager 记为 permissionRequired），
 *   用户在应用内可再次打开权限设置页。
 */
class AppUpdateInstallActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val requestKey = intent?.getStringExtra(AppUpdateContract.EXTRA_REQUEST_KEY)
        val manager = AppUpdateManager.get(applicationContext)
        manager.verifyAndInstall(this, requestKey) { launched ->
            if (!launched) {
                Log.w("AppUpdate", "installer not launched from install activity")
            }
            finish()
        }
    }
}
