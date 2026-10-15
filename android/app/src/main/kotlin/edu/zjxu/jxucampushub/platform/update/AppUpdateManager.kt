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
 * - 经系统 DownloadManager 下载到应用外部私有目录
 *   `getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)/updates/`（即
 *   `.../files/Download/updates/`，无 Cookie / 认证头），受管 id 持久化为唯一权威；
 *   该路径与 `res/xml/update_file_paths.xml` 的 FileProvider 白名单逐字一致——
 *   FileProvider 按前缀匹配，白名单漂移会让 `getUriForFile` 抛
 *   `IllegalArgumentException` 并静默废掉应用内安装（v0.11.1 及更早的故障）；
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

    private val verificationLock = Any()
    private var verifying = false
    private var activeVerification: Pair<String, Int>? = null
    private var pendingVerification: Pair<String, Int>? = null
    private val verificationCompletions = mutableListOf<() -> Unit>()

    // ---- 生命周期接线（MainActivity） ----

    fun attachActivity(activity: Activity) {
        activityRef = WeakReference(activity)
    }

    fun detachActivity(activity: Activity) {
        if (activityRef?.get() === activity) activityRef = null
    }

    /** 前台恢复：若受管更新已就绪且用户此前点过「更新」，补一次自动安装。 */
    fun onActivityResumed(activity: Activity) = withStoreFailureFallback {
        synchronized(mutationLock) {
            attachActivity(activity)
            val record = store.read()
            if (record != null) {
                val resumed = AppUpdateOwnership.installStateAfterResume(
                    verified = record.verified,
                    permissionGranted = canRequestPackageInstalls(),
                    installerOpened = record.installerOpened,
                    userWantsInstall = record.userWantsInstall,
                )
                store.update { current ->
                    if (isStale(current, record.requestKey, record.generation)) {
                        current
                    } else {
                        current!!.copy(
                            permissionRequired = resumed.permissionRequired,
                            installerOpened = false,
                            userWantsInstall = resumed.userWantsInstall,
                        )
                    }
                }
            }
        }
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
     * 持久化（尝试序号 / pending 日志）任一步失败都抛出 [AppUpdateException] 且不入队；
     * 入队后回写 downloadId 失败时尽力移除刚入队的行，避免留下无法恢复的孤儿下载。
     *
     * @throws AppUpdateException 输入不合法 / 资产 URL 不可信（原生再次校验）/ 持久化失败。
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

            try {
                store.update {
                    it?.copy(downloadId = downloadId, pendingEnqueue = false)
                }
            } catch (error: AppUpdateException) {
                // 回写失败后进程重启将无法恢复该行：尽力移除，避免孤儿下载。
                removeQuietly(downloadId)
                throw error
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

    /**
     * 用户取消：**只有权威退役确认后**才清除记录并返回 canceled。
     *
     * 复用与替换请求完全相同的 [retireOwned]（确认归属 → remove → 确认已移除 → 删自有文件）；
     * 若归属不明 / 查询不可用 / remove 失败 / 确认仍有行，则**保留 exact 记录**（含 id /
     * generation，可重试取消）、不删文件、不谎报 canceled。用户已明确要求取消，故消费自动
     * 安装意图（`userWantsInstall=false`，避免随后自动拉起安装器），并返回既有
     * `failed` / `nativeError` 类型化失败——绝不静默清除（否则可能丢弃仍在进行的受管请求）。
     * 无记录时无活动请求，幂等返回 canceled。
     */
    fun cancelActive(): Map<String, Any?> = synchronized(mutationLock) {
        val record = store.read()
        val disposition = AppUpdateOwnership.cancelDisposition(
            hasRecord = record != null,
            retireConfirmed = record != null && retireOwned(record),
        )
        when (disposition) {
            AppUpdateOwnership.CancelDisposition.IDEMPOTENT_CANCELED ->
                stateMap(AppUpdatePhase.CANCELED)

            AppUpdateOwnership.CancelDisposition.CLEARED_CANCELED -> {
                store.clear()
                stateMap(AppUpdatePhase.CANCELED)
            }

            AppUpdateOwnership.CancelDisposition.RETAIN_FAILED -> {
                // 保留 exact 记录（含 id / generation），只消费自动安装意图。
                store.update { current ->
                    if (record == null || isStale(current, record.requestKey, record.generation)) {
                        current
                    } else {
                        current!!.copy(userWantsInstall = false)
                    }
                }
                stateMap(
                    phase = AppUpdatePhase.FAILED,
                    reason = AppUpdateReason.NATIVE_ERROR,
                    version = record?.version,
                    requestKey = record?.requestKey,
                    assetFileName = record?.fileName,
                )
            }
        }
    }

    /** 调起安装：校验后若缺「未知来源」权限则进入 permissionRequired，否则发起安装器。 */
    fun requestInstall(
        activity: Activity?,
        expectedReleaseTag: String? = null,
        callback: (Boolean) -> Unit,
    ) = withStoreFailureFallback({ callback(false) }) {
        val record = store.read()
        if (record == null || (expectedReleaseTag != null &&
                AppUpdateContract.parseCanonicalAssetUrl(record.url)?.tag != expectedReleaseTag)) {
            callback(false)
            return@withStoreFailureFallback
        }
        executor.execute {
            val outcome = verifyRecord(record)
            mainHandler.post {
                if (outcome == null) {
                    callback(false)
                } else {
                    finishInstallAttempt(activity, record.requestKey, record.generation, outcome, callback)
                }
            }
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
    fun onDownloadComplete(downloadId: Long, onFinished: () -> Unit = {}) {
        synchronized(mutationLock) {
            val record = store.read()
            if (record == null || record.downloadId != downloadId ||
                trackedRowOwnership(record) != RowOwnership.OWNED
            ) {
                onFinished()
                return
            }
            if (dmStatus(downloadId)?.status == DownloadManager.STATUS_SUCCESSFUL) {
                scheduleVerification(record.requestKey, record.generation, onFinished)
            } else {
                // 失败广播也会到达；先保留 DM 的具体原因，不拿残缺文件当 APK 校验。
                computePhase(record)
                onFinished()
            }
        }
    }

    /** 安装 Activity 校验后发起安装；[requestKey] 必须与持久化记录一致。 */
    fun verifyAndInstall(activity: Activity, requestKey: String?, callback: (Boolean) -> Unit) =
        withStoreFailureFallback({ callback(false) }) {
        val record = store.read()
        if (record == null || requestKey.isNullOrEmpty() || requestKey != record.requestKey) {
            callback(false)
            return@withStoreFailureFallback
        }
        executor.execute {
            val outcome = verifyRecord(record)
            mainHandler.post {
                if (outcome == null) {
                    callback(false)
                } else {
                    finishInstallAttempt(activity, record.requestKey, record.generation, outcome, callback)
                }
            }
        }
    }

    // ---- 内部实现 ----

    /**
     * 安装校验结果回填 + 发起安装。
     *
     * 全程以 (requestKey, generation) 守卫：任何在途取消 / 新请求都会让迟到结果作废，
     * 绝不在**更新后的记录**上回填 verified / failureReason / permissionRequired /
     * installerOpened，也绝不在记录已变时返回「已发起安装」（`callback(true)`）。
     * 与 [mutationLock] 同锁，保证检查与写入相对 start / cancel 原子。
     */
    private fun finishInstallAttempt(
        activity: Activity?,
        requestKey: String,
        generation: Int,
        outcome: AppUpdateVerifier.Outcome,
        callback: (Boolean) -> Unit,
    ) = withStoreFailureFallback({ callback(false) }) {
        synchronized(mutationLock) {
            when (outcome) {
                is AppUpdateVerifier.Outcome.Failed -> {
                    store.update { current ->
                        if (isStale(current, requestKey, generation)) {
                            current
                        } else {
                            current!!.copy(verified = false, failureReason = outcome.reason)
                        }
                    }
                    callback(false)
                }

                is AppUpdateVerifier.Outcome.Verified -> {
                    val verified = store.update { current ->
                        if (isStale(current, requestKey, generation)) {
                            current
                        } else {
                            current!!.copy(verified = true, failureReason = null)
                        }
                    }
                    if (isStale(verified, requestKey, generation)) {
                        // 记录已被取消 / 替换：迟到校验结果作废，绝不回填、绝不发起安装。
                        callback(false)
                        return@synchronized
                    }
                    if (!canRequestPackageInstalls()) {
                        store.update { current ->
                            if (isStale(current, requestKey, generation)) {
                                current
                            } else {
                                current!!.copy(permissionRequired = true)
                            }
                        }
                        callback(false)
                        return@synchronized
                    }
                    // 用**最新匹配记录**发起安装（状态可能已变），而非旧结果记录。
                    val matched = store.read()
                    if (isStale(matched, requestKey, generation)) {
                        callback(false)
                        return@synchronized
                    }
                    if (!isForegroundInstallTarget(activity)) {
                        // 校验期间退到后台 / Activity 已替换：保留 APK，回前台只手动重试。
                        store.update { current ->
                            if (isStale(current, requestKey, generation)) {
                                current
                            } else {
                                current!!.copy(userWantsInstall = false)
                            }
                        }
                        callback(false)
                        return@synchronized
                    }
                    val launched = activity != null && launchInstaller(activity, matched!!)
                    if (launched) {
                        store.update { current ->
                            if (isStale(current, requestKey, generation)) {
                                current
                            } else {
                                current!!.copy(
                                    installerOpened = true,
                                    permissionRequired = false,
                                    userWantsInstall = false,
                                )
                            }
                        }
                    }
                    // 发起后再确认记录仍属本次请求；若期间被替换，绝不把结果回填 / 返回成功。
                    val after = store.read()
                    if (isStale(after, requestKey, generation)) {
                        callback(false)
                        return@synchronized
                    }
                    callback(launched)
                }
            }
        }
    }

    private inline fun withStoreFailureFallback(
        onFailure: () -> Unit = {},
        action: () -> Unit,
    ) {
        try { action() } catch (error: AppUpdateException) {
            Log.e(TAG, "update store unavailable: ${error.javaClass.simpleName}")
            onFailure()
        }
    }

    /**
     * 先看 DownloadManager 状态再校验文件：下载失败映射为具体原因（如空间不足），
     * 不拿残缺文件当 APK 校验；下载尚未完成返回 null（调用方不得记录失败）。
     * 行已不存在（状态未知）时仍交给文件校验兜底。
     */
    private fun verifyRecord(record: AppUpdateStore.Record): AppUpdateVerifier.Outcome? {
        if (record.downloadId != 0L) {
            val status = dmStatus(record.downloadId)
            when (status?.status) {
                null, DownloadManager.STATUS_SUCCESSFUL -> Unit
                DownloadManager.STATUS_FAILED -> return AppUpdateVerifier.Outcome.Failed(
                    dmFailureReason(record.downloadId),
                    "download failed",
                )
                else -> return null
            }
        }
        return AppUpdateVerifier.verify(
            context = appContext,
            file = managedFile(record),
            expectedSizeBytes = record.sizeBytes,
            expectedSha256 = record.sha256,
            expectedVersion = record.version,
        )
    }

    /**
     * 记录已被替换 / 清除（requestKey 或 generation 不匹配）时为 true。
     * 委托 [AppUpdateOwnership.isStale] 的纯逻辑，保证守卫与可执行用例同源。
     */
    private fun isStale(
        current: AppUpdateStore.Record?,
        requestKey: String,
        generation: Int,
    ): Boolean =
        AppUpdateOwnership.isStale(
            currentRequestKey = current?.requestKey,
            currentGeneration = current?.generation ?: 0,
            expectedRequestKey = requestKey,
            expectedGeneration = generation,
        )

    private fun enqueue(asset: AppUpdateContract.CanonicalAsset, managedFileName: String): Long {
        val dm = appContext.getSystemService(DownloadManager::class.java)
            ?: throw AppUpdateException(AppUpdateErrors.STORAGE, "download manager unavailable")

        val managedDir = managedDir()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // Q+ 由 DownloadProvider 通过 setDestinationInExternalFilesDir 自行创建
            // 目录：应用进程自己 mkdirs 出来的 `updates` 目录对 DownloadProvider 不可写
            // （API 35 模拟器实测 `Failed to generate filename: Permission denied`，
            // 下载永远停在暂停 / 0 B）。仅清掉旧版本遗留的**空**目录，绝不动非空目录。
            if (managedDir.isDirectory && managedDir.list()?.isEmpty() == true) {
                managedDir.delete()
            }
        } else if (!managedDir.exists() && !managedDir.mkdirs()) {
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

    private fun removeQuietly(downloadId: Long) {
        try {
            appContext.getSystemService(DownloadManager::class.java)?.remove(downloadId)
        } catch (error: Exception) {
            Log.e(TAG, "remove orphan failed: ${error.javaClass.simpleName}")
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

    private fun scheduleVerification(
        requestKey: String,
        generation: Int,
        onFinished: (() -> Unit)? = null,
    ) {
        synchronized(verificationLock) {
            onFinished?.let { verificationCompletions.add(it) }
            val requested = requestKey to generation
            // 正在校验同一代时合并轮询；不同代完成广播必须在本轮结束后补查。
            if (activeVerification != requested) pendingVerification = requested
            if (verifying) return
            verifying = true
        }
        executor.execute {
            while (true) {
                val (requested, completions) = synchronized(verificationLock) {
                    val next = pendingVerification
                    pendingVerification = null
                    activeVerification = next
                    if (next == null) {
                        verifying = false
                        null to verificationCompletions.toList().also {
                            verificationCompletions.clear()
                        }
                    } else {
                        next to emptyList<() -> Unit>()
                    }
                }
                if (requested == null) {
                    mainHandler.post {
                        try {
                            maybeAutoOpenOrNotify()
                        } finally {
                            completions.forEach { it() }
                        }
                    }
                    break
                }
                val (key, attempt) = requested
                try {
                    val record = store.read()
                    if (isStale(record, key, attempt)) continue
                    val outcome = verifyRecord(record!!) ?: continue
                    store.update { current ->
                        if (isStale(current, key, attempt)) {
                            current
                        } else {
                            when (outcome) {
                                is AppUpdateVerifier.Outcome.Verified ->
                                    current!!.copy(verified = true, failureReason = null)
                                is AppUpdateVerifier.Outcome.Failed ->
                                    current!!.copy(verified = false, failureReason = outcome.reason)
                            }
                        }
                    }
                } catch (error: Exception) {
                    Log.e(TAG, "verification failed: ${error.javaClass.simpleName}")
                }
            }
        }
    }

    private fun maybeAutoOpenOrNotify() {
        // 主线程调用：持久化不可用时静默放弃，绝不让异常击穿到主线程。
        withStoreFailureFallback { maybeAutoOpenOrNotifyLocked() }
    }

    private fun maybeAutoOpenOrNotifyLocked() {
        synchronized(mutationLock) {
            val record = store.read() ?: return
            if (!record.verified || record.installerOpened) return

            val activity = activityRef?.get()
            if (record.userWantsInstall && activity != null &&
                isForegroundInstallTarget(activity)
            ) {
                // 自动与手动路径都必须在发起前检查权限，不能把系统授权页当成安装器已打开。
                if (!canRequestPackageInstalls()) {
                    store.update { current ->
                        if (isStale(current, record.requestKey, record.generation)) {
                            current
                        } else {
                            current!!.copy(permissionRequired = true)
                        }
                    }
                    return
                }
                // 先消费一次性意图，防止 startActivity 引发的生命周期回调重复发起。
                store.update { current ->
                    if (isStale(current, record.requestKey, record.generation)) {
                        current
                    } else {
                        current!!.copy(userWantsInstall = false, permissionRequired = false)
                    }
                }
                if (launchInstaller(activity, record)) {
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
            }
            // 后台 / 无法自动打开：只发完成通知，绝不后台拉起 Activity。
            AppUpdateNotifications.postCompletion(appContext, record.requestKey)
        }
    }

    /** Activity 引用只在 onResume 附加，在 onPause 撤销。 */
    private fun isForegroundInstallTarget(activity: Activity?): Boolean =
        activity != null && AppUpdateOwnership.canLaunchInstaller(
            isAttached = activityRef?.get() === activity,
            isFinishing = activity.isFinishing,
            isDestroyed = activity.isDestroyed,
        )

    /** 用给定记录（调用方已校验代际）发起安装，避免状态在读取与拉起之间漂移。 */
    private fun launchInstaller(activity: Activity, record: AppUpdateStore.Record): Boolean {
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
            // 只记类名会丢掉具体原因（FileProvider 白名单漂移时就是
            // IllegalArgumentException），而这个 catch 是安装器拉不起来的
            // 唯一线索：必须带上 message。
            Log.e(
                TAG,
                "launchInstaller failed: ${error.javaClass.simpleName}: ${error.message}",
            )
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
        if (!requestKey.isNullOrEmpty()) {
            map["requestKey"] = requestKey
            store.read()?.takeIf { it.requestKey == requestKey }?.let { record ->
                AppUpdateContract.parseCanonicalAssetUrl(record.url)?.let { asset ->
                    map["releaseTag"] = asset.tag
                }
            }
        }
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
