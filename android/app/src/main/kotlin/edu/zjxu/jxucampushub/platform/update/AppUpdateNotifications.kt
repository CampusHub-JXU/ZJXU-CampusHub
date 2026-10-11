package edu.zjxu.jxucampushub.platform.update

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build

/**
 * 受管更新完成通知。
 *
 * - 复用 / 新建固定通知渠道 `app_update`；
 * - content intent 是**显式**、不可变（`FLAG_IMMUTABLE`）的 PendingIntent，直达
 *   非导出的 [AppUpdateInstallActivity]，只携带不透明 `requestKey`（真正的文件 /
 *   状态仍以原生持久化记录为准，Extras 一律重校验）；
 * - Android 13 通知权限被拒时安静降级，绝不后台拉起 Activity；
 * - 绝不发 trampoline（通知点击直接进 Activity，而非 broadcast）。
 */
internal object AppUpdateNotifications {
    fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(AppUpdateContract.NOTIFICATION_CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(
                AppUpdateContract.NOTIFICATION_CHANNEL_ID,
                AppUpdateContract.NOTIFICATION_CHANNEL_NAME,
                NotificationManager.IMPORTANCE_DEFAULT,
            ),
        )
    }

    fun postCompletion(context: Context, requestKey: String) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (!manager.areNotificationsEnabled()) return

        ensureChannel(context)

        val intent = Intent(context, AppUpdateInstallActivity::class.java).apply {
            setPackage(context.packageName)
            putExtra(AppUpdateContract.EXTRA_REQUEST_KEY, requestKey)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        val pending = PendingIntent.getActivity(
            context,
            AppUpdateContract.NOTIFICATION_ID_COMPLETION,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, AppUpdateContract.NOTIFICATION_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
        val notification = builder
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentTitle("下载完成")
            .setContentText("点击继续校验并安装更新")
            .setAutoCancel(true)
            .setContentIntent(pending)
            .build()

        manager.notify(AppUpdateContract.NOTIFICATION_ID_COMPLETION, notification)
    }
}
