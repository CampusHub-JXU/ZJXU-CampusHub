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
 * - 崩溃恢复：入队前写 pending 日志，`queryActiveUpdate` 时对账。归属判定必须
 *   **URL 精确 + 本地目标文件精确**（见 [AppUpdateOwnership]）：绝不按 URL 单独
 *   认领（会误伤通用 WebView 附件下载），无法权威对账时**绝不**盲目重开；
 * - 校验（sha256 / 包名 / 签名 / versionCode / ABI / minSdk）在后台线程执行，
 *   绝不阻塞通道 / UI；迟到结果按 generation + requestKey 作废；
 * - 取消 / 清理只作用于自己持久化的 downloadId 与受管文件，绝不接受任意 id / path。
 */
internal class AppUpdateManager private constructor(private val appContext: Context) {

    companion object {
        private const val TAG = "AppUpdate"

        /** 归属扫描的行数上限；达到上限仍未扫完 → 结论不权威（不重新入队）。 */
        private const val MAX_SCAN_ROWS = 500

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

    /**
     * 串行化 start / reconcile / cancel 的读-检查-入队（含 DM 行退役），避免
     * 跨 Store / DownloadManager 的检查-动作竞态。校验回调仍靠 generation +
     * requestKey 比对作废，不在此锁内做长任务。
     */
    private val mutationLock = Any()

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
     * 单活动请求不变量：替换旧记录前，必须先**权威退役**旧的自己行
     * （确认归属 → `DownloadManager.remove` → 确认已移除）。退役失败 / 归属
     * 不明时**绝不**丢弃旧记录或盲目入队新请求，而是返回当前原生权威状态。
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

        return synchronized(mutationLock) {
            val existing = store.read()
            if (existing != null &&
                existing.requestKey == requestKey &&
                existing.failureReason == null
            ) {
                // 同一活动请求：复用，不重复入队（双击 / 弹窗重入 / 进程重启）。
                queryActive()?.let { return@synchronized it }
            }

            if (existing != null && !retireOwned(existing)) {
                // 旧的自己行无法被权威退役（归属不明 / 移除未确认）：不动旧记录、
                // 不新建入队，返回当前原生权威状态（UI 需先取消当前请求）。
                return@synchronized computePhase(existing)
            }

            val generation = store.nextGeneration()
            val managedFileName =
                "${AppUpdateContract.MANAGED_FILE_PREFIX}${generation}_${asset.fileName}"

            // retireOwned 已删除上一代自有受管文件（若有），此处不再重复删除。

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
                return@synchronized stateMap(
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
            queryActive() ?: stateMap(
                phase = AppUpdatePhase.ENQUEUED,
                version = version,
                requestKey = requestKey,
                assetFileName = asset.fileName,
            )
        }
    }

    fun queryActive(): Map<String, Any?>? = synchronized(mutationLock) {
        var record = store.read() ?: return@synchronized null
        if (record.pendingEnqueue && record.downloadId == 0L) {
            record = reconcilePending(record) ?: return@synchronized null
        }
        computePhase(record)
    }

    fun cancelActive(): Map<String, Any?> = synchronized(mutationLock) {
        val record = store.read()
        if (record != null) {
            // 只移除**确认属于自己**的那一行；归属不明 / 不匹配时绝不删无关行。
            if (record.downloadId != 0L && trackedRowOwnership(record) == RowOwnership.OWNED) {
                try {
                    appContext.getSystemService(DownloadManager::class.java)
                        ?.remove(record.downloadId)
                } catch (error: Exception) {
                    Log.e(TAG, "remove failed: ${error.javaClass.simpleName}")
                }
            }
            deleteManagedFile(record)
            store.clear()
        }
        stateMap(AppUpdatePhase.CANCELED)
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

        val managedDir = managedDir()
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

    // ---- 崩溃对账 / 归属判定 ----

    /**
     * 入队与持久化之间进程被杀后的对账。
     *
     * - 唯一匹配 → 认领该行；
     * - 多行匹配 / 扫描不完整 / 查询不可用 → **绝不**重新入队，保守标记失败（可重试）；
     * - 有界扫描完整且无匹配 → 仅当自有目标文件也不存在时，才可断定「从未入队」并
     *   重新入队；若残留自有目标文件（崩溃在 DM 写文件之后）→ 保守失败，不覆盖 / 不新建。
     */
    private fun reconcilePending(record: AppUpdateStore.Record): AppUpdateStore.Record? =
        when (val scan = scanOwnedDownloads(record)) {
            is AppUpdateOwnership.Scan.Unique ->
                store.update { it?.copy(downloadId = scan.downloadId, pendingEnqueue = false) }
            is AppUpdateOwnership.Scan.Ambiguous,
            AppUpdateOwnership.Scan.Incomplete,
            AppUpdateOwnership.Scan.Unavailable,
            -> markReconcileUnresolved(record)
            AppUpdateOwnership.Scan.NotFound -> reconcileNotFound(record)
        }

    private fun markReconcileUnresolved(record: AppUpdateStore.Record): AppUpdateStore.Record? =
        store.update { current ->
            if (current == null || current.generation != record.generation) {
                current
            } else {
                // 保守失败（nativeError 是既有 UI 字段，不新造字段）：用户可在 UI 重试 /
                // 取消，重试走 startDownload 的替换路径。
                current.copy(pendingEnqueue = false, failureReason = AppUpdateReason.NATIVE_ERROR)
            }
        }

    private fun reconcileNotFound(record: AppUpdateStore.Record): AppUpdateStore.Record? {
        val file = managedFile(record)
        if (file.exists()) {
            // 崩溃在 DM 写文件之后但 DM 行已不在：目标已存在，绝不覆盖 / 盲目新建。
            return markReconcileUnresolved(record)
        }
        return try {
            val id = enqueue(canonicalAssetOf(record), record.managedFileName)
            store.update { it?.copy(downloadId = id, pendingEnqueue = false) }
        } catch (error: Exception) {
            Log.e(TAG, "reconcile failed: ${error.javaClass.simpleName}")
            store.update {
                it?.copy(pendingEnqueue = false, failureReason = AppUpdateReason.NATIVE_ERROR)
            }
        }
    }

    private fun canonicalAssetOf(record: AppUpdateStore.Record): AppUpdateContract.CanonicalAsset =
        AppUpdateContract.CanonicalAsset(
            url = record.url,
            tag = "",
            fileName = record.fileName,
        )

    /**
     * 权威退役旧的自己行：确认归属 → `DownloadManager.remove` → 确认已移除，之后
     * 才删除自有受管文件。任何一步无法确认（归属不明 / 移除失败 / 无法确认移除）
     * 都返回 false，调用方必须保留旧记录、绝不入队新请求。
     */
    private fun retireOwned(record: AppUpdateStore.Record): Boolean {
        val dm = appContext.getSystemService(DownloadManager::class.java)
        val targetId: Long? = when {
            record.downloadId != 0L -> when (trackedRowOwnership(record)) {
                RowOwnership.OWNED -> record.downloadId
                RowOwnership.ABSENT -> null
                RowOwnership.FOREIGN, RowOwnership.UNKNOWN -> return false
            }
            record.pendingEnqueue -> when (val scan = scanOwnedDownloads(record)) {
                is AppUpdateOwnership.Scan.Unique -> scan.downloadId
                AppUpdateOwnership.Scan.NotFound -> null
                is AppUpdateOwnership.Scan.Ambiguous,
                AppUpdateOwnership.Scan.Incomplete,
                AppUpdateOwnership.Scan.Unavailable,
                -> return false
            }
            else -> null
        }

        if (targetId != null) {
            if (dm == null) return false
            try {
                dm.remove(targetId)
            } catch (error: Exception) {
                Log.e(TAG, "retire remove failed: ${error.javaClass.simpleName}")
                return false
            }
            if (!confirmRemoved(dm, targetId)) return false
        }

        // DM 行已确认退役（或确认不存在）→ 只删自己前缀、自己目录内的受管文件。
        deleteManagedFile(record)
        return true
    }

    private fun confirmRemoved(dm: DownloadManager, id: Long): Boolean = try {
        dm.query(DownloadManager.Query().setFilterById(id)).use { cursor ->
            cursor == null || !cursor.moveToFirst()
        }
    } catch (error: Exception) {
        Log.e(TAG, "confirmRemoved failed: ${error.javaClass.simpleName}")
        false
    }

    private enum class RowOwnership { OWNED, ABSENT, FOREIGN, UNKNOWN }

    /**
     * 按持久化 id 精确查询该行的归属：
     * - OWNED：行存在且 URL + 本地目标与自有受管文件完全一致；
     * - ABSENT：行已不存在；
     * - FOREIGN：行存在但不属于自己（绝不操作）；
     * - UNKNOWN：查询失败（绝不操作）。
     */
    private fun trackedRowOwnership(record: AppUpdateStore.Record): RowOwnership {
        val dm = appContext.getSystemService(DownloadManager::class.java)
            ?: return RowOwnership.UNKNOWN
        return try {
            dm.query(DownloadManager.Query().setFilterById(record.downloadId)).use { cursor ->
                if (cursor == null) return RowOwnership.UNKNOWN
                if (!cursor.moveToFirst()) return RowOwnership.ABSENT
                val id = cursor.getLong(
                    cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_ID),
                )
                val url = cursor.getString(
                    cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_URI),
                )
                val local = cursor.getString(
                    cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_LOCAL_URI),
                )
                val owned = AppUpdateOwnership.matches(
                    row = AppUpdateOwnership.DmRow(id = id, url = url, localUri = local),
                    expectedUrl = record.url,
                    managedDirPath = managedDirPath(),
                    managedFileName = record.managedFileName,
                )
                if (owned) RowOwnership.OWNED else RowOwnership.FOREIGN
            }
        } catch (error: Exception) {
            Log.e(TAG, "trackedRowOwnership failed: ${error.javaClass.simpleName}")
            RowOwnership.UNKNOWN
        }
    }

    /**
     * 有界扫描本 App 的 DM 行（上限 [MAX_SCAN_ROWS]），交给纯逻辑
     * [AppUpdateOwnership.classify] 做 URL + 本地目标精确归属判定。
     */
    private fun scanOwnedDownloads(record: AppUpdateStore.Record): AppUpdateOwnership.Scan {
        val dm = appContext.getSystemService(DownloadManager::class.java)
            ?: return AppUpdateOwnership.Scan.Unavailable
        val dirPath = managedDirPath()
        return try {
            dm.query(DownloadManager.Query()).use { cursor ->
                if (cursor == null) return AppUpdateOwnership.Scan.Unavailable
                val idColumn = cursor.getColumnIndex(DownloadManager.COLUMN_ID)
                val uriColumn = cursor.getColumnIndex(DownloadManager.COLUMN_URI)
                val localColumn = cursor.getColumnIndex(DownloadManager.COLUMN_LOCAL_URI)
                if (idColumn < 0 || uriColumn < 0 || localColumn < 0) {
                    return AppUpdateOwnership.Scan.Unavailable
                }
                val rows = ArrayList<AppUpdateOwnership.DmRow>(64)
                var scanned = 0
                var capReached = false
                while (cursor.moveToNext()) {
                    if (scanned >= MAX_SCAN_ROWS) {
                        capReached = true
                        break
                    }
                    scanned++
                    rows.add(
                        AppUpdateOwnership.DmRow(
                            id = cursor.getLong(idColumn),
                            url = cursor.getString(uriColumn),
                            localUri = cursor.getString(localColumn),
                        ),
                    )
                }
                AppUpdateOwnership.classify(
                    rows = rows,
                    expectedUrl = record.url,
                    managedDirPath = dirPath,
                    managedFileName = record.managedFileName,
                    capReached = capReached,
                )
            }
        } catch (error: Exception) {
            Log.e(TAG, "scanOwned failed: ${error.javaClass.simpleName}")
            AppUpdateOwnership.Scan.Unavailable
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

    private fun managedDir(): File = File(
        appContext.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS),
        AppUpdateContract.MANAGED_SUBDIR,
    )

    private fun managedDirPath(): String =
        try {
            managedDir().canonicalPath
        } catch (_: Exception) {
            managedDir().absolutePath
        }

    private fun managedFile(record: AppUpdateStore.Record): File =
        File(managedDir(), record.managedFileName)

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
