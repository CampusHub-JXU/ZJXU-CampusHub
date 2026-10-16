package edu.zjxu.jxucampushub.platform.update

import android.app.Activity
import android.app.DownloadManager
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo
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
 * 状态机的 IO 执行器。所有入口、同步 effect 及结果回灌由 mutationLock 串行化；
 * 先持久化再执行副作用。大文件校验只在单线程 executor，安装器只在主线程。
 * 下载仍写私有 Download/updates，不注入凭据；不接受外部路径或 downloadId。
 */
internal class AppUpdateManager private constructor(private val appContext: Context) {
    companion object {
        private const val TAG = "AppUpdate"
        private const val MAX_SCAN_ROWS = 500
        @Volatile private var instance: AppUpdateManager? = null
        fun get(context: Context): AppUpdateManager = instance ?: synchronized(this) {
            instance ?: AppUpdateManager(context.applicationContext).also { instance = it }
        }
    }
    private val allowTestOrigin = (appContext.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
    private val store = AppUpdateStore(appContext, allowTestOrigin)
    private val mutationLock = Any()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "app-update-verify").apply { isDaemon = true }
    }
    @Volatile private var activityRef: WeakReference<Activity>? = null
    private val verificationJobs = mutableSetOf<Pair<String, Int>>()
    private val installTargets = mutableMapOf<Pair<String, Int>, WeakReference<Activity>?>()
    private val installCallbacks = mutableMapOf<Pair<String, Int>, MutableList<(Boolean) -> Unit>>()

    fun attachActivity(activity: Activity) { activityRef = WeakReference(activity) }
    fun detachActivity(activity: Activity) { if (activityRef?.get() === activity) activityRef = null }
    fun isSupported(): Boolean = appContext.getSystemService(DownloadManager::class.java) != null

    /** 所有入口先恢复 pending 身份并检查已安装版本，永不凭一次查询故障丢身份。 */
    private fun enter(): View {
        // 先判定是否已被安装：已过期的待对账任务直接退役，不能先重新入队一次下载。
        val installed = try {
            val info = appContext.packageManager.getPackageInfo(appContext.packageName, 0)
            Event.Installed(versionCode(info), info.versionName)
        } catch (_: Exception) { Event.Installed(null, null) }
        var view = dispatch(installed)
        val t = store.read()
        if (t != null && t.stage in listOf(Stage.ENQUEUING, Stage.RECONCILE_REQUIRED)) {
            view = dispatch(Event.ReconcileScan(scanOwnedDownloads(t),
                managedFile(t).exists() || !canReenqueue(t)))
        }
        return view
    }

    private fun canReenqueue(t: Task): Boolean = t.sources.any { it.source == t.source && it.url == t.url } &&
        AppUpdateContract.parseCanonicalAssetUrl(t.url, allowTestOrigin)?.let {
            it.tag == t.releaseTag && it.fileName == t.fileName && it.source == t.source
        } == true && AppUpdateOwnership.isManagedFileName(t.managedFileName)

    fun startDownload(params: StartParams): Map<String, Any?> {
        val checked = validate(params)
        return synchronized(mutationLock) {
            enter()
            val old = store.read()
            val generation = if (old != null && old.requestKey == checked.requestKey && old.stage != Stage.FAILED)
                old.generation else store.nextGeneration()
            stateMap(dispatch(Event.Start(checked, generation)))!!
        }
    }

    fun queryActive(): Map<String, Any?>? = synchronized(mutationLock) {
        enter()
        var t = store.read() ?: return@synchronized null
        if (t.stage == Stage.CLEANUP_PENDING) {
            // 每次轮询只重试一次清理，不在同一调用内忙循环。
            executeRetire(Effect.Retire(t.generation), t)
            t = store.read() ?: return@synchronized null
        }
        stateMap(dispatch(Event.Observe(dmStatus(t.downloadId))))
    }
    fun cancelActive(): Map<String, Any?> = synchronized(mutationLock) {
        enter()
        val old = store.read()
        val view = dispatch(Event.Cancel)
        stateMap(view.copy(retired = view.task == null, releaseTag = old?.releaseTag.orEmpty()))!!
    }
    fun switchSource(reason: String, attempt: Int): Map<String, Any?>? {
        if (reason !in AppUpdateContract.SWITCH_REQUEST_REASONS)
            throw AppUpdateException(AppUpdateErrors.INVALID_ARGS, "invalid switch reason")
        return synchronized(mutationLock) {
            enter()
            // 先观察 DM：建议发出后下载可能已完成 / 已失败（已自动换源），不能把它当停滞再换一次。
            store.read()?.takeIf { it.stage == Stage.DOWNLOADING }?.let { dispatch(Event.Observe(dmStatus(it.downloadId))) }
            stateMap(dispatch(Event.SwitchRequested(reason, attempt)))
        }
    }
    fun onActivityResumed(activity: Activity) = safely {
        synchronized(mutationLock) {
            attachActivity(activity)
            enter()
            dispatch(Event.Resumed(canRequestPackageInstalls(), isForegroundInstallTarget(activity)))
        }
    }

    fun requestInstall(activity: Activity?, expectedReleaseTag: String? = null, callback: (Boolean) -> Unit) {
        requestInstallMatching(activity, null, expectedReleaseTag, callback)
    }
    fun verifyAndInstall(activity: Activity, requestKey: String?, callback: (Boolean) -> Unit) {
        if (requestKey.isNullOrEmpty()) { mainHandler.post { callback(false) }; return }
        requestInstallMatching(activity, requestKey, null, callback)
    }
    private fun requestInstallMatching(activity: Activity?, key: String?, tag: String?, callback: (Boolean) -> Unit) {
        // 存储失败、取消和主线程回调可能交错；公共 callback 也只完成一次。
        val completed = java.util.concurrent.atomic.AtomicBoolean(false)
        val reply: (Boolean) -> Unit = { value -> if (completed.compareAndSet(false, true)) callback(value) }
        try {
            synchronized(mutationLock) {
                enter()
                val t = store.read()
                if (t == null || (key != null && t.requestKey != key) || (tag != null && t.releaseTag != tag) ||
                    t.stage !in listOf(Stage.READY, Stage.INSTALLER_LAUNCHED)) {
                    mainHandler.post { reply(false) }
                    return
                }
                val identity = t.requestKey to t.generation
                installCallbacks.getOrPut(identity) { mutableListOf() }.add(reply)
                installTargets[identity] = activity?.let { WeakReference(it) }
                dispatch(Event.InstallRequested(manual = true))
            }
        } catch (_: AppUpdateException) { mainHandler.post { reply(false) } }
    }

    /** goAsync 只覆盖同步观察/转移；耗时校验另交 executor，广播无需等待。 */
    fun onDownloadComplete(downloadId: Long, onFinished: () -> Unit = {}) {
        try {
            synchronized(mutationLock) {
                enter()
                val record = store.read() ?: return
                if (record.downloadId != downloadId || trackedRowOwnership(record) != RowOwnership.OWNED) return
                dispatch(Event.Observe(dmStatus(downloadId)))
            }
        } finally { onFinished() }
    }

    /** 必须在 mutationLock 内调用；每个 effect 的同步结果继续交回纯 reducer。 */
    private fun dispatch(event: Event): View {
        val before = store.read()
        val transition = AppUpdateMachine.reduce(before, event)
        if (before != transition.task) store.update { transition.task }
        // 只记阶段名 / 世代 / 事件类型，不含 URL、文件名或请求键。
        if (before?.stage != transition.task?.stage) {
            Log.i(TAG, "stage ${before?.stage} -> ${transition.task?.stage} (gen ${transition.task?.generation ?: before?.generation}, event ${event.javaClass.simpleName})")
        }
        var view = transition.view
        for (effect in transition.effects) {
            val t = store.read() ?: continue
            view = when (effect) {
                is Effect.Enqueue -> {
                    val asset = AppUpdateContract.parseCanonicalAssetUrl(effect.url, allowTestOrigin)
                    val id = try {
                        check(canReenqueue(t) && asset != null)
                        enqueue(asset!!, effect.managedFileName)
                    } catch (error: Exception) {
                        Log.e(TAG, "enqueue failed: " + error.message)
                        null
                    }
                    if (id == null) dispatch(Event.EnqueueFailed(effect.gen)) else try {
                        dispatch(Event.Enqueued(effect.gen, id))
                    } catch (error: AppUpdateException) {
                        // pending 日志仍可恢复；尽力移除刚创建的精确 id，绝不继续入队。
                        try { appContext.getSystemService(DownloadManager::class.java)?.remove(id) } catch (_: Exception) { }
                        throw error
                    }
                }
                is Effect.Retire -> executeRetire(effect, t)
                Effect.Scan -> dispatch(Event.ReconcileScan(scanOwnedDownloads(t), managedFile(t).exists() || !canReenqueue(t)))
                is Effect.Verify -> { scheduleVerification(t); AppUpdateMachine.view(store.read()) }
                is Effect.LaunchInstaller -> { scheduleInstaller(t); AppUpdateMachine.view(store.read()) }
                is Effect.Notify -> {
                    try { AppUpdateNotifications.postCompletion(appContext, t.requestKey) } catch (e: Exception) {
                        Log.e(TAG, "notify failed: " + e.message)
                    }
                    AppUpdateMachine.view(store.read())
                }
            }
        }
        // 被取消/换源的挂起手动调用也必须恰好回复一次。
        val current = store.read()
        installCallbacks.keys.toList().filter { it != current?.let { c -> c.requestKey to c.generation } }
            .forEach { completeInstall(it, false) }
        return view
    }

    private fun executeRetire(effect: Effect.Retire, record: Task): View {
        val confirmed = retireOwned(record)
        val generation = if (confirmed && record.cleanupIntent == CleanupIntent.SWITCH) store.nextGeneration() else record.generation
        var view = dispatch(Event.RetireResult(effect.gen, confirmed, generation))
        if (confirmed && effect.restart != null && store.read() == null) view = dispatch(effect.restart)
        return view
    }

    /** 同代轮询合并，异代排队；校验前后都核对身份，取消后永不回填/拉起安装器。 */
    private fun scheduleVerification(record: Task) {
        val identity = record.requestKey to record.generation
        if (!verificationJobs.add(identity)) return
        if (!installTargets.containsKey(identity)) installTargets[identity] = activityRef?.get()?.let { WeakReference(it) }
        executor.execute {
            var result: Verification? = null
            try {
                val eligible = synchronized(mutationLock) {
                    val current = store.read()
                    !isStale(current, record.requestKey, record.generation) &&
                        current!!.stage in listOf(Stage.AWAITING_VERIFY, Stage.READY, Stage.INSTALLER_LAUNCHED)
                }
                if (eligible) {
                    val dm = dmStatus(record.downloadId)
                    if (dm == DmObs.Successful || dm == DmObs.Absent || record.downloadId == 0L) {
                        val outcome = AppUpdateVerifier.verify(appContext, managedFile(record), record.sizeBytes, record.sha256, record.version)
                        result = when (outcome) {
                            is AppUpdateVerifier.Outcome.Failed -> Verification.Failed(outcome.reason)
                            is AppUpdateVerifier.Outcome.Verified -> {
                                val info = appContext.packageManager.getPackageArchiveInfo(managedFile(record).absolutePath, 0)
                                if (info == null) Verification.Failed(AppUpdateReason.VERIFICATION_FAILED)
                                else Verification.Verified(versionCode(info))
                            }
                        }
                    } else if (dm is DmObs.Failed) result = Verification.Failed(dm.reason)
                }
            } catch (error: Exception) {
                Log.e(TAG, "verification failed: " + error.message)
                // IO/包信息异常不能绕过安装闸门。
                result = Verification.Failed(AppUpdateReason.VERIFICATION_FAILED)
            }
            synchronized(mutationLock) {
                verificationJobs.remove(identity)
                try {
                    val current = store.read()
                    if (result != null && !isStale(current, record.requestKey, record.generation)) {
                        dispatch(Event.VerifyResult(record.generation, result!!))
                    }
                    val after = store.read()
                    if (result !is Verification.Verified || isStale(after, record.requestKey, record.generation) || after?.wantsInstall != true) {
                        completeInstall(identity, false)
                        installTargets.remove(identity)
                    }
                } catch (_: AppUpdateException) { completeInstall(identity, false) }
            }
        }
    }

    private fun scheduleInstaller(record: Task) {
        val identity = record.requestKey to record.generation
        val target = if (installTargets.containsKey(identity)) installTargets[identity]?.get() else activityRef?.get()
        mainHandler.post {
            synchronized(mutationLock) {
                try {
                    // READY 安装前复核在途时，Resumed 不可抢先绕过 Verify。
                    if (identity in verificationJobs) return@synchronized
                    val current = store.read()
                    if (isStale(current, record.requestKey, record.generation) || current?.stage != Stage.READY || !current.wantsInstall) {
                        completeInstall(identity, false)
                        return@synchronized
                    }
                    val foreground = isForegroundInstallTarget(target)
                    val permissionMissing = !canRequestPackageInstalls()
                    val launched = foreground && !permissionMissing && target != null && launchInstaller(target, current)
                    dispatch(Event.InstallLaunch(record.generation, launched, permissionMissing, foreground))
                    completeInstall(identity, launched && !isStale(store.read(), record.requestKey, record.generation))
                } catch (_: AppUpdateException) { completeInstall(identity, false) }
                finally { installTargets.remove(identity) }
            }
        }
    }
    private fun completeInstall(identity: Pair<String, Int>, launched: Boolean) {
        val callbacks = installCallbacks.remove(identity).orEmpty()
        if (callbacks.isNotEmpty()) mainHandler.post { callbacks.forEach { it(launched) } }
    }
    private fun safely(action: () -> Unit) {
        try { action() } catch (error: AppUpdateException) { Log.e(TAG, "update store unavailable: " + error.message) }
    }
    private fun isStale(current: Task?, key: String, generation: Int) = AppUpdateOwnership.isStale(
        current?.requestKey, current?.generation ?: 0, key, generation)
    private fun versionCode(info: PackageInfo): Long = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode
        else @Suppress("DEPRECATION") info.versionCode.toLong()

    /** 无行与查询不可用分开：Unavailable 保留 DOWNLOADING，绝不制造永久 FAILED。 */
    private fun dmStatus(id: Long): DmObs {
        val dm = appContext.getSystemService(DownloadManager::class.java) ?: return DmObs.Unavailable
        return try {
            dm.query(DownloadManager.Query().setFilterById(id)).use { c ->
                if (c == null) return DmObs.Unavailable
                if (!c.moveToFirst()) return DmObs.Absent
                val b = c.getLong(c.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR))
                val t = c.getLong(c.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES))
                when (c.getInt(c.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))) {
                    DownloadManager.STATUS_PENDING -> DmObs.Pending(b, t)
                    DownloadManager.STATUS_RUNNING -> DmObs.Running(b, t)
                    DownloadManager.STATUS_PAUSED -> DmObs.Paused(b, t)
                    DownloadManager.STATUS_SUCCESSFUL -> DmObs.Successful
                    DownloadManager.STATUS_FAILED -> DmObs.Failed(dmFailureReason(id))
                    else -> DmObs.Unavailable
                }
            }
        } catch (error: Exception) { Log.e(TAG, "dmStatus failed: " + error.message); DmObs.Unavailable }
    }

    private fun validate(p: StartParams): StartParams {
        if (p.version.isBlank() || p.version.length > AppUpdateContract.MAX_VERSION_LENGTH ||
            p.requestKey.isBlank() || p.requestKey.length > AppUpdateContract.MAX_REQUEST_KEY_LENGTH ||
            !p.requestKey.startsWith("v2:") || p.mode !in listOf("manual", "auto") ||
            p.sources.size !in 1..3 || p.sources.map { it.source }.distinct().size != p.sources.size ||
            p.sizeBytes !in 0..AppUpdateContract.MAX_APK_BYTES ||
            (p.abi != null && (p.abi.isBlank() || p.abi.length > AppUpdateContract.MAX_ABI_LENGTH)) ||
            (p.unavailablePreferred != null && p.unavailablePreferred != AppUpdateContract.SOURCE_R2)) {
            throw AppUpdateException(AppUpdateErrors.INVALID_ARGS, "invalid update request")
        }
        val sources = p.sources.map { s ->
            val asset = AppUpdateContract.parseCanonicalAssetUrl(s.url, allowTestOrigin)
            if (asset == null || asset.tag != p.releaseTag || asset.fileName != p.fileName || asset.source != s.source)
                throw AppUpdateException(AppUpdateErrors.UNTRUSTED_ASSET, "untrusted asset")
            SourceUrl(asset.source, asset.url)
        }
        val sha = AppUpdateContract.normalizeSha256(p.sha256)
        if (p.sha256 != null && sha == null) throw AppUpdateException(AppUpdateErrors.INVALID_ARGS, "invalid sha256")
        return p.copy(version = p.version.trim(), requestKey = p.requestKey.trim(), sources = sources, sha256 = sha)
    }

    /** 投影不读写任务；每个 map（包含 canceled）均带 releaseTag。 */
    private fun stateMap(view: View): Map<String, Any?>? {
        val t = view.task
        if (t == null) return if (view.canceled) mapOf("phase" to AppUpdatePhase.CANCELED,
            "releaseTag" to view.releaseTag, "retired" to true) else null
        val dm = view.dm
        val phase = when (t.stage) {
            Stage.ENQUEUING -> AppUpdatePhase.ENQUEUED
            Stage.DOWNLOADING -> when (dm) {
                is DmObs.Pending -> AppUpdatePhase.ENQUEUED
                is DmObs.Paused -> AppUpdatePhase.PAUSED
                else -> AppUpdatePhase.DOWNLOADING
            }
            Stage.AWAITING_VERIFY -> AppUpdatePhase.VERIFYING
            Stage.READY -> if (canRequestPackageInstalls()) AppUpdatePhase.READY_TO_INSTALL else AppUpdatePhase.PERMISSION_REQUIRED
            Stage.INSTALLER_LAUNCHED -> AppUpdatePhase.INSTALLER_OPENED
            Stage.FAILED -> AppUpdatePhase.FAILED
            Stage.RECONCILE_REQUIRED -> AppUpdatePhase.RECONCILE_REQUIRED
            Stage.CLEANUP_PENDING -> AppUpdatePhase.CLEANUP_PENDING
        }
        val switching = t.stage == Stage.CLEANUP_PENDING && t.cleanupIntent == CleanupIntent.SWITCH
        val map = linkedMapOf<String, Any?>("phase" to phase, "version" to t.version, "releaseTag" to t.releaseTag,
            "requestKey" to t.requestKey, "assetFileName" to t.fileName, "source" to t.source, "mode" to t.mode,
            "attempt" to t.generation, "triedSources" to t.tried,
            "canSwitch" to (t.stage == Stage.DOWNLOADING && t.mode == "auto" && AppUpdateMachine.nextSource(t) != null),
            "switchReason" to t.switchReason, "fellBackFrom" to t.fellBackFrom, "switching" to switching,
            "exhausted" to (t.mode == "auto" && t.tried.size > 1 && t.stage == Stage.FAILED))
        if (switching) map["switchingTo"] = AppUpdateMachine.nextSource(t)?.source
        if (t.stage == Stage.FAILED) map["reason"] = t.failureReason
        if (view.retired != null) map["retired"] = view.retired
        if (t.stage == Stage.DOWNLOADING) {
            val progress = when (dm) {
                is DmObs.Pending -> dm.bytes to dm.total
                is DmObs.Running -> dm.bytes to dm.total
                is DmObs.Paused -> dm.bytes to dm.total
                else -> null
            }
            if (progress != null) {
                if (progress.first >= 0) map["bytesDownloaded"] = progress.first
                if (progress.second > 0) map["totalBytes"] = progress.second
            }
        }
        return map
    }

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


    private enum class RowOwnership { OWNED, ABSENT, FOREIGN, UNKNOWN }

    /**
     * 按持久化 id 精确查询该行的归属：
     * - OWNED：行存在且 URL + 本地目标与自有受管文件完全一致；
     * - ABSENT：行已不存在；
     * - FOREIGN：行存在但不属于自己（绝不操作）；
     * - UNKNOWN：查询失败（绝不操作）。
     */
    private fun trackedRowOwnership(record: Task): RowOwnership {
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
    private fun scanOwnedDownloads(record: Task): AppUpdateOwnership.Scan {
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


    /** Activity 引用只在 onResume 附加，在 onPause 撤销。 */
    private fun isForegroundInstallTarget(activity: Activity?): Boolean =
        activity != null && AppUpdateOwnership.canLaunchInstaller(
            isAttached = activityRef?.get() === activity,
            isFinishing = activity.isFinishing,
            isDestroyed = activity.isDestroyed,
        )

    /** 用给定记录（调用方已校验代际）发起安装，避免状态在读取与拉起之间漂移。 */
    private fun launchInstaller(activity: Activity, record: Task): Boolean {
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
            Log.i(TAG, "installer launched (gen ${record.generation})")
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

    private fun managedFile(record: Task): File =
        File(managedDir(), record.managedFileName)

    private fun deleteManagedFile(record: Task) {
        // 只删自己前缀、自己受管目录内的文件，绝不遍历其它下载。
        if (!record.managedFileName.startsWith(AppUpdateContract.MANAGED_FILE_PREFIX)) return
        val safePath = AppUpdateOwnership.canonicalManagedPath(managedDirPath(), record.managedFileName) ?: return
        val file = managedFile(record)
        // 防止损坏记录路径/符号链接越出私有目录；只有精确目标可删。
        if (file.canonicalFile.parentFile != managedDir().canonicalFile || file.canonicalPath != safePath) return
        if (file.isFile) file.delete()
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


    private fun retireOwned(record: Task): Boolean {
        val dm = appContext.getSystemService(DownloadManager::class.java)
        val targetId: Long? = when {
            record.downloadId != 0L -> when (trackedRowOwnership(record)) {
                RowOwnership.OWNED -> record.downloadId
                RowOwnership.ABSENT -> null
                RowOwnership.FOREIGN, RowOwnership.UNKNOWN -> return false
            }
            else -> when (val scan = scanOwnedDownloads(record)) {
                is AppUpdateOwnership.Scan.Unique -> scan.downloadId
                AppUpdateOwnership.Scan.NotFound -> null
                is AppUpdateOwnership.Scan.Ambiguous,
                AppUpdateOwnership.Scan.Incomplete,
                AppUpdateOwnership.Scan.Unavailable,
                -> return false
            }
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
            cursor != null && !cursor.moveToFirst()
        }
    } catch (error: Exception) {
        Log.e(TAG, "confirmRemoved failed: ${error.javaClass.simpleName}")
        false
    }


}
