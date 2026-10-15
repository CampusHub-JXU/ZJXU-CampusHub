package edu.zjxu.jxucampushub.platform.update

import android.app.DownloadManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 受管下载完成广播接收器（**manifest 注册、受系统签名权限保护**）。
 *
 * - 只处理 `ACTION_DOWNLOAD_COMPLETE`，且只接受与原生持久化受管 id 匹配的下载
 *   （`AppUpdateManager.onDownloadComplete` 内部比对，忽略其它下载 id）；
 * - 绝不在此启动 UI / 后台拉起 Activity；只调度受管校验（有界 goAsync + 单线程
 *   executor），完成后的通知 / 自动安装由 manager 在前台时决定；
 * - 仅靠 MainActivity 动态注册不够（进程死亡后收不到），故必须 manifest 注册。
 */
class AppUpdateDownloadReceiver : BroadcastReceiver() {
    companion object {
        private val executor = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "app-update-receiver").apply { isDaemon = true }
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != DownloadManager.ACTION_DOWNLOAD_COMPLETE) return
        val downloadId = intent.getLongExtra(DownloadManager.EXTRA_DOWNLOAD_ID, -1L)
        if (downloadId < 0L) return

        val appContext = context.applicationContext
        val pending = goAsync()
        // PendingResult.finish() 重复调用会抛 IllegalStateException，故只放行一次。
        val finished = AtomicBoolean(false)
        val finish = { if (finished.compareAndSet(false, true)) pending.finish() }
        executor.execute {
            try {
                AppUpdateManager.get(appContext).onDownloadComplete(downloadId) { finish() }
            } catch (error: Exception) {
                Log.e("AppUpdate", "receiver failed: ${error.javaClass.simpleName}")
                finish()
            }
        }
    }
}
