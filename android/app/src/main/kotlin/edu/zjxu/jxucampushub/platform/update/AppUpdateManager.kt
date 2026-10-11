package edu.zjxu.jxucampushub.platform.update

import android.app.Activity
import android.app.DownloadManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import androidx.core.content.FileProvider
import java.io.File
import java.lang.ref.WeakReference
import java.util.concurrent.Executors

/**
 * 应用内受管 APK 更新的原生权威实现。
 *
 * 职责：
 * - 原生**再次**校验 Dart 传入的规范资产 URL / 文件名 / 字段上限（绝不信任 Dart）；
 * - 经系统 DownloadManager 下载到应用外部私有目录 `Downloads/updates/`（无 Cookie /
 *   认证头），受管 id 持久化为唯一权威；
 * - 单活动请求 + 稳定 `requestKey` 幂等去重（双击 / 弹窗重入 / 进程重启）；
 * - 崩溃恢复：入队前写 pending 日志，`queryActiveUpdate` 时对账（只认自己的
 *   canonical URL + 唯一目标文件），绝不盲目重开；
 * - 校验（sha256 / 包名 / 签名 / versionCode / ABI / minSdk）在后台线程执行，
 *   绝不阻塞通道 / UI；迟到结果按 generation + requestKey 作废；
 * - 取消 / 清理只作用于自己持久化的 downloadId 与受管文件，绝不接受任意 id / path。
 */
internal class AppUpdateManager private constructor(private val appContext: Context) {

    companion object {
        private const val TAG = "AppUpdate"

        @Volatile
        private var instance: AppUpdateManager? = null

        fun get(context: Context): AppUpdateManager {
            instance?.let { return it }
            return synchronized(this) {
                instance ?: AppUpdateManager(context.applicationContext).also { instance = it }
            }
        }
    }

    private val store = AppUpdateStore(appContext)
    private val executor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "app-update-verify").apply { isDaemon = true }
    }
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var activityRef: WeakReference<Activity>? = null

    @Volatile
    private var verifying = false

    // ---- 生命周期接线（MainActivity） ----

    fun attachActivity(activity: Activity) {
        activityRef = WeakReference(activity)
    }

    fun detachActivity(activity: Activity) {
        if (activityRef?.get() === activity) activityRef = null
    }

    /** 前台恢复：若受管更新已就绪且用户此前点过「更新」，补一次自动安装。 */
    fun onActivityResumed(activity: Activity) {
        attachActivity(activity)
        maybeAutoOpenOrNotify()
    }

    // ---- 通道方法 ----

    fun isSupported(): Boolean =
        appContext.getSystemService(DownloadManager::class.java) != null

    /**
     * 入队一次受管下载；幂等复用同一 `requestKey` 的活动请求。
     *
     * @throws AppUpdateException 输入不合法 / 资产 URL 不可信（原生再次校验）。
     */
    fun startDownload(params: StartParams): Map<String, Any?> {
        val asset = AppUpdateContract.parseCanonicalAssetUrl(params.url)
            ?: throw AppUpdateException(
                AppUpdateErrors.UNTRUSTED_ASSET,
                "untrusted asset url",
            )
        if (params.fileName.isNullOrEmpty() || params.fileName != asset.fileName) {
            throw AppUpdateException(AppUpdateErrors.INVALID_ARGS, "fileName mismatch")
        }
        val version = params.version?.trim().orEmpty()
        if (version.isEmpty() || version.length > AppUpdateContract.MAX_VERSION_LENGTH) {
            throw AppUpdateException(AppUpdateErrors.INVALID_ARGS, "invalid version")
        }
        val requestKey = params.requestKey?.trim().orEmpty()
        if (requestKey.isEmpty() ||
            requestKey.length > AppUpdateContract.MAX_REQUEST_KEY_LENGTH
        ) {
            throw AppUpdateException(AppUpdateErrors.INVALID_ARGS, "invalid requestKey")
        }
        val sizeBytes = params.sizeBytes ?: 0L
        if (sizeBytes < 0L || sizeBytes > AppUpdateContract.MAX_APK_BYTES) {
            throw AppUpdateException(AppUpdateErrors.INVALID_ARGS, "invalid sizeBytes")
        }
        val abi = params.abi?.trim()?.takeIf {
            it.isNotEmpty() && it.length <= AppUpdateContract.MAX_ABI_LENGTH
        }

        val existing = store.read()
        if (existing != null &&
            existing.requestKey == requestKey &&
            existing.failureReason == null
        ) {
            // 同一活动请求：复用，不重复入队（双击 / 弹窗重入 / 进程重启）。
            queryActive()?.let { return it }
        }

        val generation = store.nextGeneration()
        val managedFileName = "${AppUpdateContract.MANAGED_FILE_PREFIX}${generation}_${asset.fileName}"

        // 清理上一代自有受管文件（只删自己前缀 + 自己目录内的文件）。
        existing?.let { deleteManagedFile(it) }

        // 先写 pending 日志再入队：崩溃在两步之间时留下可对账的痕迹。
        val journal = AppUpdateStore.Record(
            requestKey = requestKey,
            version = version,
            url = asset.url,
            fileName = asset.fileName,
            managedFileName = managedFileName,
            sizeBytes = sizeBytes,
            sha256 = AppUpdateContract.normalizeSha256(params.sha256),
            abi = abi,
            downloadId = 0L,
            generation = generation,
            pendingEnqueue = true,
            userWantsInstall = true,
            verified = false,
            installerOpened = false,
            permissionRequired = false,
            failureReason = null,
        )
        store.update { journal }

        val downloadId = try {
            enqueue(asset, managedFileName)
        } catch (error: Exception) {
            Log.e(TAG, "enqueue failed: ${error.javaClass.simpleName}")
            store.update {
                it?.copy(pendingEnqueue = false, failureReason = AppUpdateReason.NATIVE_ERROR)
            }
            return stateMap(
                phase = AppUpdatePhase.FAILED,
                reason = AppUpdateReason.NATIVE_ERROR,
                version = version,
                requestKey = requestKey,
                assetFileName = asset.fileName,
            )
        }

        store.update {
            it?.copy(downloadId = downloadId, pendingEnqueue = false)
        }
        return queryActive() ?: stateMap(
            phase = AppUpdatePhase.ENQUEUED,
            version = version,
            requestKey = requestKey,
            assetFileName = asset.fileName,
        )
    }

    fun queryActive(): Map<String, Any?>? {
        var record = store.read() ?: return null
        if (record.pendingEnqueue && record.downloadId == 0L) {
            record = reconcilePending(record) ?: return null
        }
        return computePhase(record)
    }

    fun cancelActive(): Map<String, Any?> {
        val record = store.read()
        if (record != null) {
            if (record.downloadId != 0L) {
                try {
                    appContext.getSystemService(DownloadManager::class.java)?.remove(record.downloadId)
                } catch (error: Exception) {
                    Log.e(TAG, "remove failed: ${error.javaClass.simpleName}")
                }
            }
            deleteManagedFile(record)
            store.clear()
        }
        return stateMap(AppUpdatePhase.CANCELED)
    }

    /** 调起安装：校验后若缺「未知来源」权限则进入 permissionRequired，否则发起安装器。 */
    fun requestInstall(activity: Activity?, callback: (Boolean) -> Unit) {
        val record = store.read()
        if (record == null) {
            callback(false)
            return
        }
        executor.execute {
            val outcome = verifyRecord(record)
            mainHandler.post { finishInstallAttempt(activity, outcome, callback) }
        }
    }

    fun openInstallPermissionSettings(activity: Activity?): Boolean {
        if (activity == null) return false
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true
        return try {
            activity.startActivity(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:${appContext.packageName}"),
                ),
            )
            true
        } catch (error: Exception) {
            Log.e(TAG, "openInstallSettings failed: ${error.javaClass.simpleName}")
            false
        }
    }

    // ---- 下载完成 / 安装 Activity 回调 ----

    /** 广播完成回调：只接受自己持久化的受管 id，忽略其它下载。 */
    fun onDownloadComplete(downloadId: Long) {
        val record = store.read() ?: return
        if (record.downloadId != downloadId) return
        scheduleVerification(record.requestKey, record.generation)
    }

    /** 安装 Activity 校验后发起安装；[requestKey] 必须与持久化记录一致。 */
    fun verifyAndInstall(activity: Activity, requestKey: String?, callback: (Boolean) -> Unit) {
        val record = store.read()
        if (record == null || requestKey.isNullOrEmpty() || requestKey != record.requestKey) {
            callback(false)
            return
        }
        executor.execute {
            val outcome = verifyRecord(record)
            mainHandler.post { finishInstallAttempt(activity, outcome, callback) }
        }
    }

    // ---- 内部实现 ----

    private fun finishInstallAttempt(
        activity: Activity?,
        outcome: AppUpdateVerifier.Outcome,
        callback: (Boolean) -> Unit,
    ) {
        when (outcome) {
            is AppUpdateVerifier.Outcome.Failed -> {
                store.update {
                    it?.copy(verified = false, failureReason = outcome.reason)
                }
                callback(false)
            }
            is AppUpdateVerifier.Outcome.Verified -> {
                store.update { it?.copy(verified = true, failureReason = null) }
                if (!canRequestPackageInstalls()) {
                    store.update { it?.copy(permissionRequired = true) }
                    callback(false)
                    return
                }
                val launched = activity != null && launchInstaller(activity)
                if (launched) {
                    // 用户意图已消费：安装器只自动打开一次，取消后仍可手动重试。
                    store.update {
                        it?.copy(
                            installerOpened = true,
                            permissionRequired = false,
                            userWantsInstall = false,
                        )
                    }
                }
                callback(launched)
            }
        }
    }

    private fun verifyRecord(record: AppUpdateStore.Record): AppUpdateVerifier.Outcome =
        AppUpdateVerifier.verify(
            context = appContext,
            file = managedFile(record),
            expectedSizeBytes = record.sizeBytes,
            expectedSha256 = record.sha256,
            expectedVersion = record.version,
        )

    /** 记录已被替换 / 清除（requestKey 或 generation 不匹配）时为 true。 */
    private fun isStale(
        current: AppUpdateStore.Record?,
        requestKey: String,
        generation: Int,
    ): Boolean =
        current == null ||
            current.requestKey != requestKey ||
            current.generation != generation

    private fun enqueue(asset: AppUpdateContract.CanonicalAsset, managedFileName: String): Long {
        val dm = appContext.getSystemService(DownloadManager::class.java)
            ?: throw AppUpdateException(AppUpdateErrors.STORAGE, "download manager unavailable")

        val managedDir = File(
            appContext.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS),
            AppUpdateContract.MANAGED_SUBDIR,
        )
        if (!managedDir.exists() && !managedDir.mkdirs()) {
            throw AppUpdateException(AppUpdateErrors.STORAGE, "cannot create managed dir")
        }

        val request = DownloadManager.Request(Uri.parse(asset.url)).apply {
            setTitle(asset.fileName)
            setDescription(asset.fileName)
            setMimeType("application/vnd.android.package-archive")
            // 只显示进度；完成通知由本通道自己的 receiver / 通知发出。
            setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE)
            // 应用外部私有目录；绝不写公共目录，绝不注入 Cookie / 认证头。
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                setDestinationInExternalFilesDir(
                    appContext,
                    Environment.DIRECTORY_DOWNLOADS,
                    "${AppUpdateContract.MANAGED_SUBDIR}/$managedFileName",
                )
            } else {
                setDestinationUri(Uri.fromFile(File(managedDir, managedFileName)))
            }
            setAllowedOverMetered(true)
            setAllowedOverRoaming(false)
        }
        return dm.enqueue(request)
    }

    private fun reconcilePending(record: AppUpdateStore.Record): AppUpdateStore.Record? {
        val owned = findOwnedDownloadId(record.url)
        if (owned != null) {
            return store.update { it?.copy(downloadId = owned, pendingEnqueue = false) }
        }
        // 无对应 DM 行：说明入队与持久化之间进程被杀，重新入队一次（只认自己的
        // canonical URL + 唯一目标文件），绝不盲目开新的无关请求。
        return try {
            val id = enqueue(
                AppUpdateContract.CanonicalAsset(
                    url = record.url,
                    tag = "",
                    fileName = record.fileName,
                ),
                record.managedFileName,
            )
            store.update { it?.copy(downloadId = id, pendingEnqueue = false) }
        } catch (error: Exception) {
            Log.e(TAG, "reconcile failed: ${error.javaClass.simpleName}")
            store.update {
                it?.copy(pendingEnqueue = false, failureReason = AppUpdateReason.NATIVE_ERROR)
            }
        }
    }

    /** 遍历本 App 的 DM 记录，按 canonical URL 精确匹配自己的下载。 */
    private fun findOwnedDownloadId(url: String): Long? {
        val dm = appContext.getSystemService(DownloadManager::class.java) ?: return null
        return try {
            dm.query(DownloadManager.Query()).use { cursor ->
                if (cursor == null) return null
                val idColumn = cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_ID)
                val uriColumn = cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_URI)
                var scanned = 0
                while (cursor.moveToNext() && scanned < 500) {
                    scanned++
                    if (cursor.getString(uriColumn) == url) return cursor.getLong(idColumn)
                }
                null
            }
        } catch (error: Exception) {
            Log.e(TAG, "findOwned failed: ${error.javaClass.simpleName}")
            null
        }
    }

    private fun computePhase(record: AppUpdateStore.Record): Map<String, Any?> {
        if (record.permissionRequired) {
            return stateMap(
                phase = AppUpdatePhase.PERMISSION_REQUIRED,
                version = record.version,
                requestKey = record.requestKey,
                assetFileName = record.fileName,
            )
        }
        if (record.installerOpened) {
            return stateMap(
                phase = AppUpdatePhase.INSTALLER_OPENED,
                version = record.version,
                requestKey = record.requestKey,
                assetFileName = record.fileName,
            )
        }
        if (record.failureReason != null && !record.verified) {
            return stateMap(
                phase = AppUpdatePhase.FAILED,
                reason = record.failureReason,
                version = record.version,
                requestKey = record.requestKey,
                assetFileName = record.fileName,
            )
        }
        if (record.downloadId == 0L) {
            return if (record.verified) {
                readyState(record)
            } else {
                stateMap(
                    phase = AppUpdatePhase.ENQUEUED,
                    version = record.version,
                    requestKey = record.requestKey,
                    assetFileName = record.fileName,
                )
            }
        }

        val status = dmStatus(record.downloadId)
        if (status == null) {
            return if (record.verified) {
                readyState(record)
            } else {
                markFailed(record, AppUpdateReason.VERIFICATION_FAILED)
            }
        }
        return when (status.status) {
            DownloadManager.STATUS_PENDING -> stateMap(
                phase = AppUpdatePhase.ENQUEUED,
                bytes = status.bytes,
                total = status.total,
                version = record.version,
                requestKey = record.requestKey,
                assetFileName = record.fileName,
            )
            DownloadManager.STATUS_RUNNING -> stateMap(
                phase = AppUpdatePhase.DOWNLOADING,
                bytes = status.bytes,
                total = status.total,
                version = record.version,
                requestKey = record.requestKey,
                assetFileName = record.fileName,
            )
            DownloadManager.STATUS_PAUSED -> stateMap(
                phase = AppUpdatePhase.PAUSED,
                bytes = status.bytes,
                total = status.total,
                version = record.version,
                requestKey = record.requestKey,
                assetFileName = record.fileName,
            )
            DownloadManager.STATUS_SUCCESSFUL -> {
                if (record.verified) {
                    readyState(record)
                } else {
                    scheduleVerification(record.requestKey, record.generation)
                    stateMap(
                        phase = AppUpdatePhase.VERIFYING,
                        version = record.version,
                        requestKey = record.requestKey,
                        assetFileName = record.fileName,
                    )
                }
            }
            DownloadManager.STATUS_FAILED -> markFailed(record, dmFailureReason(record.downloadId))
            else -> markFailed(record, AppUpdateReason.UNKNOWN)
        }
    }

    private fun markFailed(record: AppUpdateStore.Record, reason: String): Map<String, Any?> {
        store.update { current ->
            if (current == null ||
                current.requestKey != record.requestKey ||
                current.generation != record.generation
            ) {
                current
            } else {
                current.copy(failureReason = reason)
            }
        }
        return stateMap(
            phase = AppUpdatePhase.FAILED,
            reason = reason,
            version = record.version,
            requestKey = record.requestKey,
            assetFileName = record.fileName,
        )
    }

    private fun readyState(record: AppUpdateStore.Record): Map<String, Any?> = stateMap(
        phase = AppUpdatePhase.READY_TO_INSTALL,
        version = record.version,
        requestKey = record.requestKey,
        assetFileName = record.fileName,
    )

    private fun scheduleVerification(requestKey: String, generation: Int) {
        if (verifying) return
        verifying = true
        executor.execute {
            try {
                val record = store.read()
                if (record == null ||
                    record.requestKey != requestKey ||
                    record.generation != generation
                ) {
                    return@execute
                }
                when (val outcome = verifyRecord(record)) {
                    is AppUpdateVerifier.Outcome.Verified -> store.update { current ->
                        if (isStale(current, requestKey, generation)) {
                            current
                        } else {
                            current!!.copy(verified = true, failureReason = null)
                        }
                    }
                    is AppUpdateVerifier.Outcome.Failed -> store.update { current ->
                        if (isStale(current, requestKey, generation)) {
                            current
                        } else {
                            current!!.copy(verified = false, failureReason = outcome.reason)
                        }
                    }
                }
            } finally {
                verifying = false
                mainHandler.post { maybeAutoOpenOrNotify() }
            }
        }
    }

    private fun maybeAutoOpenOrNotify() {
        val record = store.read() ?: return
        if (!record.verified || record.installerOpened || record.permissionRequired) return

        val activity = activityRef?.get()
        if (record.userWantsInstall && activity != null && launchInstaller(activity)) {
            store.update { current ->
                if (isStale(current, record.requestKey, record.generation)) {
                    current
                } else {
                    current!!.copy(
                        installerOpened = true,
                        userWantsInstall = false,
                        permissionRequired = false,
                    )
                }
            }
            return
        }
        // 后台 / 无法自动打开：只发完成通知，绝不后台拉起 Activity。
        AppUpdateNotifications.postCompletion(appContext, record.requestKey)
    }

    private fun launchInstaller(activity: Activity): Boolean {
        val record = store.read() ?: return false
        val file = managedFile(record)
        if (!file.isFile) return false
        return try {
            val uri = FileProvider.getUriForFile(
                appContext,
                AppUpdateContract.fileProviderAuthority(appContext.packageName),
                file,
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            activity.startActivity(intent)
            true
        } catch (error: Exception) {
            Log.e(TAG, "launchInstaller failed: ${error.javaClass.simpleName}")
            false
        }
    }

    private fun canRequestPackageInstalls(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            appContext.packageManager.canRequestPackageInstalls()
        } else {
            true
        }

    private data class DmStatus(val status: Int, val bytes: Long, val total: Long)

    private fun dmStatus(id: Long): DmStatus? {
        val dm = appContext.getSystemService(DownloadManager::class.java) ?: return null
        return try {
            dm.query(DownloadManager.Query().setFilterById(id)).use { cursor ->
                if (cursor == null || !cursor.moveToFirst()) return null
                DmStatus(
                    status = cursor.getInt(
                        cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS),
                    ),
                    bytes = cursor.getLong(
                        cursor.getColumnIndexOrThrow(
                            DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR,
                        ),
                    ),
                    total = cursor.getLong(
                        cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES),
                    ),
                )
            }
        } catch (error: Exception) {
            Log.e(TAG, "dmStatus failed: ${error.javaClass.simpleName}")
            null
        }
    }

    private fun dmFailureReason(id: Long): String {
        val dm = appContext.getSystemService(DownloadManager::class.java)
            ?: return AppUpdateReason.NATIVE_ERROR
        return try {
            dm.query(DownloadManager.Query().setFilterById(id)).use { cursor ->
                if (cursor == null || !cursor.moveToFirst()) return AppUpdateReason.UNKNOWN
                when (cursor.getInt(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON))) {
                    DownloadManager.ERROR_INSUFFICIENT_SPACE ->
                        AppUpdateReason.STORAGE_INSUFFICIENT
                    DownloadManager.ERROR_HTTP_DATA_ERROR,
                    DownloadManager.ERROR_UNHANDLED_HTTP_CODE,
                    DownloadManager.ERROR_TOO_MANY_REDIRECTS,
                    -> AppUpdateReason.NETWORK
                    else -> AppUpdateReason.NATIVE_ERROR
                }
            }
        } catch (error: Exception) {
            Log.e(TAG, "dmFailureReason failed: ${error.javaClass.simpleName}")
            AppUpdateReason.NATIVE_ERROR
        }
    }

    private fun managedFile(record: AppUpdateStore.Record): File = File(
        File(appContext.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS), AppUpdateContract.MANAGED_SUBDIR),
        record.managedFileName,
    )

    private fun deleteManagedFile(record: AppUpdateStore.Record) {
        // 只删自己前缀、自己受管目录内的文件，绝不遍历其它下载。
        if (!record.managedFileName.startsWith(AppUpdateContract.MANAGED_FILE_PREFIX)) return
        val file = managedFile(record)
        if (file.isFile) file.delete()
    }

    private fun stateMap(
        phase: String,
        bytes: Long? = null,
        total: Long? = null,
        reason: String? = null,
        version: String? = null,
        requestKey: String? = null,
        assetFileName: String? = null,
    ): Map<String, Any?> {
        val map = HashMap<String, Any?>()
        map["phase"] = phase
        if (bytes != null && bytes >= 0L) map["bytesDownloaded"] = bytes
        if (total != null && total > 0L) map["totalBytes"] = total
        if (reason != null) map["reason"] = reason
        if (!version.isNullOrEmpty()) map["version"] = version
        if (!requestKey.isNullOrEmpty()) map["requestKey"] = requestKey
        if (!assetFileName.isNullOrEmpty()) map["assetFileName"] = assetFileName
        return map
    }

    internal data class StartParams(
        val version: String?,
        val url: String?,
        val fileName: String?,
        val requestKey: String?,
        val sizeBytes: Long?,
        val sha256: String?,
        val abi: String?,
    )
}
