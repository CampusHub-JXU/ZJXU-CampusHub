package edu.zjxu.campus_captcha_ocr

import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/**
 * 单实例「最多一个未完成识别」准入槽（纯 Kotlin，无 Android 依赖 → JVM 单测）。
 *
 * - 已有在途请求时 [tryAcquire] 返回 null，调用方必须**立即**回 `busy`：
 *   不排队、不保留输入字节（[Request] 不持有任何图像数据）。
 * - Dart 侧超时不代表原生已停止：请求会一直占用槽位，直到原生完成 / 失败 / detach；
 *   期间的新调用一律 `busy`，不得因为 Dart 超时就把槽位当作空闲。
 * - detach 时 [deactivateCurrent] 失活并清空当前请求；此后到达的完成 / 失败回调
 *   因 [Request.claimReply] 返回 false 而**不回调**（迟到不回调）。
 * - [release] 只允许当前占用者释放：旧请求的迟到释放不会清掉后来取得的新请求。
 */
internal class RecognitionAdmission {

    /** 单个在途识别。不持有 bytes / bitmap / 引擎引用。 */
    class Request internal constructor() {

        @Volatile
        private var active: Boolean = true

        private val replied = AtomicBoolean(false)

        val isActive: Boolean
            get() = active

        /** detach 时失活；失活后 [claimReply] 一律 false。 */
        internal fun markInactive() {
            active = false
        }

        /**
         * 认领唯一一次回调：只有第一个调用者、且请求仍在途、且未 detach 时返回 true。
         * 返回 false 表示不得回调（已回复过 / 已失活 / 已 detach）。
         */
        fun claimReply(detached: Boolean): Boolean = replied.compareAndSet(false, true) && active && !detached
    }

    private val slot = AtomicReference<Request?>(null)

    /** 占用槽位；已有在途请求时返回 null（调用方立即回 busy，不排队）。 */
    fun tryAcquire(): Request? {
        val request = Request()
        return if (slot.compareAndSet(null, request)) request else null
    }

    /** 释放槽位；只有当前占用者能释放，迟到释放不会清掉新请求。 */
    fun release(request: Request) {
        slot.compareAndSet(request, null)
    }

    /** detach：失活并清空当前请求，返回被失活者（空闲时为 null）。 */
    fun deactivateCurrent(): Request? {
        val current = slot.getAndSet(null) ?: return null
        current.markInactive()
        return current
    }

    val hasActiveRequest: Boolean
        get() = slot.get() != null
}
