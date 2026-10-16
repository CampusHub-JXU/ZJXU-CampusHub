package edu.zjxu.jxucampushub.widget

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import java.time.LocalDateTime
import java.time.ZoneId

/**
 * 桌面组件自走时闹钟（docs/desktop-widget-v2.md §4、§7.4）。
 *
 * 每次渲染后重排：
 * 1. **边界闹钟**（一次性，唤醒）= min(下一个课程 start/end，下一场考试 start/end，下一个本地午夜)。
 *    `canScheduleExactAlarms()` 为真（或 API < 31）用 `setExactAndAllowWhileIdle`，
 *    否则 `setAndAllowWhileIdle`（可能延后几分钟，组件内容晚一点切换，不会错）。
 * 2. **进度闹钟**（一次性，非唤醒 `RTC`）：仅当有进行中的课且放了大组件时，10 分钟后重渲一次
 *    推进进度条；设备睡眠时不唤醒，亮屏后补发。
 * 没有任何实例（或没有可用快照）时两个闹钟都取消。目标都是不导出的
 * [CampusWidgetRefreshReceiver]（显式组件，`FLAG_IMMUTABLE`，各用独立 requestCode）。
 */
internal object CampusWidgetScheduler {
    private const val TAG = "CampusWidgetScheduler"
    private const val REQUEST_BOUNDARY = 7101
    private const val REQUEST_PROGRESS = 7102
    private const val PROGRESS_INTERVAL_MS = 10L * 60L * 1000L

    /**
     * 重排闹钟。参数缺省时自己从存储读取快照 / 查询各尺寸实例数；显式传入的 null 快照表示「没有可用快照」。
     */
    fun rearm(
        context: Context,
        snapshot: CampusWidgetSnapshot? = CampusWidgetStore.loadSnapshot(context).snapshot,
        counts: Map<CampusWidgetKind, Int> = CampusWidgetStore.instanceCounts(context),
    ) {
        val alarms = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return
        val total = counts.values.sum()
        if (total == 0 || snapshot == null || !snapshot.isCurrentSchema) {
            cancel(context, alarms)
            return
        }
        val zone = ZoneId.systemDefault()
        val now = LocalDateTime.now(zone)
        val nowMs = System.currentTimeMillis()

        val boundary = CampusWidgetTimeLogic.nextBoundary(snapshot.days, snapshot.exams, now)
        // 至少 1 秒后，避免闹钟比边界早几毫秒触发时来回空转。
        val boundaryMs = maxOf(boundary.atZone(zone).toInstant().toEpochMilli(), nowMs + 1_000L)
        scheduleBoundary(alarms, boundaryMs, pending(context, REQUEST_BOUNDARY, CampusWidgetRefreshReceiver.ACTION_ALARM_BOUNDARY))

        val needProgress = (counts[CampusWidgetKind.LARGE] ?: 0) > 0 &&
            CampusWidgetTimeLogic.hasOngoingCourse(snapshot.days, now)
        val progressPending = pending(
            context,
            REQUEST_PROGRESS,
            CampusWidgetRefreshReceiver.ACTION_ALARM_PROGRESS,
        )
        if (needProgress) {
            alarms.set(AlarmManager.RTC, nowMs + PROGRESS_INTERVAL_MS, progressPending)
        } else {
            alarms.cancel(progressPending)
        }
    }

    private fun scheduleBoundary(alarms: AlarmManager, triggerMs: Long, pending: PendingIntent) {
        val canExact = Build.VERSION.SDK_INT < Build.VERSION_CODES.S || alarms.canScheduleExactAlarms()
        if (canExact) {
            try {
                alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerMs, pending)
                return
            } catch (error: SecurityException) {
                // 权限被撤销的竞态：退回非精确。
                Log.w(TAG, "exact alarm denied, falling back to inexact")
            }
        }
        alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerMs, pending)
    }

    fun cancel(context: Context) {
        val alarms = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return
        cancel(context, alarms)
    }

    private fun cancel(context: Context, alarms: AlarmManager) {
        alarms.cancel(pending(context, REQUEST_BOUNDARY, CampusWidgetRefreshReceiver.ACTION_ALARM_BOUNDARY))
        alarms.cancel(pending(context, REQUEST_PROGRESS, CampusWidgetRefreshReceiver.ACTION_ALARM_PROGRESS))
    }

    private fun pending(context: Context, requestCode: Int, action: String): PendingIntent {
        val intent = Intent(context, CampusWidgetRefreshReceiver::class.java).setAction(action)
        return PendingIntent.getBroadcast(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}
