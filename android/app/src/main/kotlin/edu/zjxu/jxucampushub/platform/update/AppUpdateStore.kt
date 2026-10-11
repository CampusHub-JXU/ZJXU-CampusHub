package edu.zjxu.jxucampushub.platform.update

import android.content.Context
import android.content.SharedPreferences

/**
 * 受管更新的**唯一**原生权威持久化（SharedPreferences 私有档）。
 *
 * 不变量：
 * - 只有原生持有受管请求记录；Dart 侧状态只是投影，**不**做双 JsonCache；
 * - 单活动请求：同一时刻最多一条记录，`requestKey` 稳定用于幂等去重；
 * - `generation` 单调递增，用于作废迟到的校验 / 安装 / 清理；
 * - 关键写入使用 `commit()`（同步）以缩小「入队与持久化之间崩溃」的窗口；
 * - 记录只保存协议字段，**不含**任何账号 / Cookie / 凭据。
 */
internal class AppUpdateStore(context: Context) {
    private val prefs: SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    private val lock = Any()

    internal data class Record(
        val requestKey: String,
        val version: String,
        val url: String,
        val fileName: String,
        val managedFileName: String,
        val sizeBytes: Long,
        val sha256: String?,
        val abi: String?,
        val downloadId: Long,
        val generation: Int,
        val pendingEnqueue: Boolean,
        val userWantsInstall: Boolean,
        val verified: Boolean,
        val installerOpened: Boolean,
        val permissionRequired: Boolean,
        val failureReason: String?,
    )

    fun read(): Record? = synchronized(lock) { readLocked() }

    /** 读-改-写；[transform] 返回 null 表示清除记录。 */
    fun update(transform: (Record?) -> Record?): Record? = synchronized(lock) {
        val next = transform(readLocked())
        if (next == null) {
            prefs.edit().clear().commit()
        } else {
            writeLocked(next)
        }
        next
    }

    fun clear() {
        synchronized(lock) { prefs.edit().clear().commit() }
    }

    /** 下一个 generation（不写入，只计算）。 */
    fun nextGeneration(): Int = (read()?.generation ?: 0) + 1

    private fun readLocked(): Record? {
        val requestKey = prefs.getString(KEY_REQUEST_KEY, null) ?: return null
        if (requestKey.isBlank()) return null
        return Record(
            requestKey = requestKey,
            version = prefs.getString(KEY_VERSION, "").orEmpty(),
            url = prefs.getString(KEY_URL, "").orEmpty(),
            fileName = prefs.getString(KEY_FILE_NAME, "").orEmpty(),
            managedFileName = prefs.getString(KEY_MANAGED_FILE_NAME, "").orEmpty(),
            sizeBytes = prefs.getLong(KEY_SIZE_BYTES, 0L),
            sha256 = prefs.getString(KEY_SHA256, null),
            abi = prefs.getString(KEY_ABI, null),
            downloadId = prefs.getLong(KEY_DOWNLOAD_ID, 0L),
            generation = prefs.getInt(KEY_GENERATION, 0),
            pendingEnqueue = prefs.getBoolean(KEY_PENDING, false),
            userWantsInstall = prefs.getBoolean(KEY_USER_WANTS_INSTALL, false),
            verified = prefs.getBoolean(KEY_VERIFIED, false),
            installerOpened = prefs.getBoolean(KEY_INSTALLER_OPENED, false),
            permissionRequired = prefs.getBoolean(KEY_PERMISSION_REQUIRED, false),
            failureReason = prefs.getString(KEY_FAILURE_REASON, null),
        )
    }

    private fun writeLocked(record: Record) {
        prefs.edit()
            .putString(KEY_REQUEST_KEY, record.requestKey)
            .putString(KEY_VERSION, record.version)
            .putString(KEY_URL, record.url)
            .putString(KEY_FILE_NAME, record.fileName)
            .putString(KEY_MANAGED_FILE_NAME, record.managedFileName)
            .putLong(KEY_SIZE_BYTES, record.sizeBytes)
            .putString(KEY_SHA256, record.sha256)
            .putString(KEY_ABI, record.abi)
            .putLong(KEY_DOWNLOAD_ID, record.downloadId)
            .putInt(KEY_GENERATION, record.generation)
            .putBoolean(KEY_PENDING, record.pendingEnqueue)
            .putBoolean(KEY_USER_WANTS_INSTALL, record.userWantsInstall)
            .putBoolean(KEY_VERIFIED, record.verified)
            .putBoolean(KEY_INSTALLER_OPENED, record.installerOpened)
            .putBoolean(KEY_PERMISSION_REQUIRED, record.permissionRequired)
            .putString(KEY_FAILURE_REASON, record.failureReason)
            .commit()
    }

    private companion object {
        const val PREFS_NAME = "app_update_managed_v1"
        const val KEY_REQUEST_KEY = "request_key"
        const val KEY_VERSION = "version"
        const val KEY_URL = "url"
        const val KEY_FILE_NAME = "file_name"
        const val KEY_MANAGED_FILE_NAME = "managed_file_name"
        const val KEY_SIZE_BYTES = "size_bytes"
        const val KEY_SHA256 = "sha256"
        const val KEY_ABI = "abi"
        const val KEY_DOWNLOAD_ID = "download_id"
        const val KEY_GENERATION = "generation"
        const val KEY_PENDING = "pending_enqueue"
        const val KEY_USER_WANTS_INSTALL = "user_wants_install"
        const val KEY_VERIFIED = "verified"
        const val KEY_INSTALLER_OPENED = "installer_opened"
        const val KEY_PERMISSION_REQUIRED = "permission_required"
        const val KEY_FAILURE_REASON = "failure_reason"
    }
}
