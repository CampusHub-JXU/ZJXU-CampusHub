package edu.zjxu.jxucampushub.platform.update

/** 原生唯一生命周期模型；不依赖 Android，不在 reducer 中读系统或执行 IO。 */
internal enum class Stage {
    ENQUEUING, DOWNLOADING, AWAITING_VERIFY, READY, INSTALLER_LAUNCHED,
    FAILED, RECONCILE_REQUIRED, CLEANUP_PENDING,
}
internal enum class CleanupIntent { CANCEL, SUPERSEDED, SWITCH }
internal data class SourceUrl(val source: String, val url: String)
internal data class StartParams(
    val version: String, val releaseTag: String, val fileName: String, val requestKey: String,
    val mode: String, val sources: List<SourceUrl>, val sizeBytes: Long = 0,
    val sha256: String? = null, val abi: String? = null, val unavailablePreferred: String? = null,
)
internal data class Task(
    val requestKey: String, val version: String, val releaseTag: String, val fileName: String,
    val sizeBytes: Long, val sha256: String?, val abi: String?, val mode: String,
    val sources: List<SourceUrl>, val tried: List<String>, val generation: Int,
    val source: String, val url: String, val managedFileName: String, val downloadId: Long,
    val stage: Stage, val failureReason: String? = null, val cleanupIntent: CleanupIntent? = null,
    val switchReason: String? = null, val fellBackFrom: String? = null,
    val wantsInstall: Boolean = true, val verifiedVersionCode: Long? = null,
)
internal sealed class DmObs {
    data class Pending(val bytes: Long, val total: Long) : DmObs()
    data class Running(val bytes: Long, val total: Long) : DmObs()
    data class Paused(val bytes: Long, val total: Long) : DmObs()
    object Successful : DmObs()
    data class Failed(val reason: String) : DmObs()
    object Absent : DmObs()
    object Unavailable : DmObs()
}
internal sealed class Verification {
    data class Verified(val versionCode: Long) : Verification()
    data class Failed(val reason: String) : Verification()
}
internal sealed class Event {
    data class Start(val params: StartParams, val newGeneration: Int) : Event()
    data class Observe(val dm: DmObs) : Event()
    data class ReconcileScan(val scan: AppUpdateOwnership.Scan, val fileExists: Boolean) : Event()
    data class Enqueued(val gen: Int, val id: Long) : Event()
    data class EnqueueFailed(val gen: Int) : Event()
    data class VerifyResult(val gen: Int, val result: Verification) : Event()
    data class InstallRequested(val manual: Boolean) : Event()
    data class InstallLaunch(val gen: Int, val launched: Boolean,
        val permissionMissing: Boolean, val foreground: Boolean) : Event()
    data class Resumed(val permissionGranted: Boolean, val foreground: Boolean) : Event()
    data class Installed(val code: Long?, val name: String?) : Event()
    object Cancel : Event()
    // attempt = Dart 判定停滞时看到的代际；换源已发生后迟到的建议必须作废，不能再烧掉下一条线路。
    data class SwitchRequested(val reason: String, val attempt: Int) : Event()
    // 新代际由 Store 分配，纯函数测试可显式给定；绝不回收旧 attempt。
    data class RetireResult(val gen: Int, val confirmed: Boolean, val newGeneration: Int = gen + 1) : Event()
}
internal sealed class Effect {
    data class Enqueue(val gen: Int, val url: String, val managedFileName: String) : Effect()
    // restart 仅在本次同步清理成功后消费；失败不暗中排队另一个用户任务。
    data class Retire(val gen: Int, val restart: Event.Start? = null) : Effect()
    object Scan : Effect()
    data class Verify(val gen: Int) : Effect()
    data class LaunchInstaller(val gen: Int) : Effect()
    data class Notify(val gen: Int) : Effect()
}
internal data class View(val task: Task?, val dm: DmObs? = null,
    val canceled: Boolean = false, val retired: Boolean? = null, val releaseTag: String = task?.releaseTag.orEmpty())
internal data class Transition(val task: Task?, val effects: List<Effect>, val view: View)

/**
 * 所有迟到结果先核对 generation；非法 stage × event 组合保持任务与副作用不变。
 * CLEANUP_PENDING 保留完整旧身份，只有权威退役确认后才清空或换源。
 */
internal object AppUpdateMachine {
    fun view(task: Task?, dm: DmObs? = null) = View(task, dm)

    fun reduce(task: Task?, event: Event): Transition {
        fun out(t: Task? = task, vararg effects: Effect, dm: DmObs? = null,
            canceled: Boolean = false, retired: Boolean? = null, tag: String = t?.releaseTag.orEmpty()) =
            Transition(t, effects.toList(), View(t, dm, canceled, retired, tag))
        fun enqueue(t: Task) = out(t, Effect.Enqueue(t.generation, t.url, t.managedFileName))
        fun cleanup(intent: CleanupIntent, restart: Event.Start? = null): Transition {
            val t = task!!.copy(stage = Stage.CLEANUP_PENDING, cleanupIntent = intent,
                failureReason = null, wantsInstall = false)
            return out(t, Effect.Retire(t.generation, restart))
        }
        fun sourceFailure(reason: String, switchReason: String): Transition {
            val t = task!!
            return if (t.mode == "auto" && nextSource(t) != null) {
                val next = t.copy(stage = Stage.CLEANUP_PENDING, cleanupIntent = CleanupIntent.SWITCH,
                    failureReason = null, switchReason = switchReason, fellBackFrom = t.source)
                out(next, Effect.Retire(t.generation))
            } else out(t.copy(stage = Stage.FAILED, cleanupIntent = null, failureReason = reason))
        }
        val gen = when (event) {
            is Event.Enqueued -> event.gen
            is Event.EnqueueFailed -> event.gen
            is Event.VerifyResult -> event.gen
            is Event.InstallLaunch -> event.gen
            is Event.RetireResult -> event.gen
            is Event.SwitchRequested -> event.attempt
            else -> null
        }
        if (gen != null && gen != task?.generation) return out()
        if (event is Event.Start) {
            if (task == null) {
                val p = event.params
                val s = p.sources.first()
                return enqueue(Task(p.requestKey, p.version, p.releaseTag, p.fileName,
                    p.sizeBytes, p.sha256, p.abi, p.mode, p.sources, listOf(s.source), event.newGeneration,
                    s.source, s.url, "update_" + event.newGeneration + "_" + p.fileName, 0, Stage.ENQUEUING,
                    fellBackFrom = p.unavailablePreferred))
            }
            if (task.requestKey == event.params.requestKey && task.stage != Stage.FAILED) {
                return out(task.copy(wantsInstall = true))
            }
            return cleanup(CleanupIntent.CANCEL, event)
        }
        if (event == Event.Cancel) {
            if (task == null) return out(canceled = true, retired = true)
            return cleanup(CleanupIntent.CANCEL)
        }
        if (task == null) return out()
        return when (event) {
            is Event.Observe -> when (task.stage) {
                Stage.AWAITING_VERIFY -> out(task, Effect.Verify(task.generation))
                Stage.DOWNLOADING -> when (val dm = event.dm) {
                    DmObs.Successful, DmObs.Absent -> out(task.copy(stage = Stage.AWAITING_VERIFY), Effect.Verify(task.generation))
                    is DmObs.Failed -> sourceFailure(dm.reason, "failed")
                    else -> out(dm = dm)
                }
                else -> out()
            }
            is Event.ReconcileScan -> if (task.stage !in listOf(Stage.ENQUEUING, Stage.RECONCILE_REQUIRED)) out() else when (val scan = event.scan) {
                is AppUpdateOwnership.Scan.Unique -> out(task.copy(stage = Stage.DOWNLOADING, downloadId = scan.downloadId))
                AppUpdateOwnership.Scan.NotFound -> if (!event.fileExists) enqueue(task.copy(stage = Stage.ENQUEUING))
                    else out(task.copy(stage = Stage.RECONCILE_REQUIRED))
                else -> out(task.copy(stage = Stage.RECONCILE_REQUIRED))
            }
            is Event.Enqueued -> if (task.stage == Stage.ENQUEUING) out(task.copy(stage = Stage.DOWNLOADING, downloadId = event.id)) else out()
            is Event.EnqueueFailed -> if (task.stage == Stage.ENQUEUING) out(task.copy(stage = Stage.FAILED, failureReason = "nativeError")) else out()
            is Event.VerifyResult -> if (task.stage !in listOf(Stage.AWAITING_VERIFY, Stage.READY, Stage.INSTALLER_LAUNCHED)) out() else when (val r = event.result) {
                is Verification.Verified -> {
                    val t = task.copy(stage = Stage.READY, verifiedVersionCode = r.versionCode)
                    if (t.wantsInstall) out(t, Effect.LaunchInstaller(t.generation)) else out(t)
                }
                is Verification.Failed -> if (task.stage == Stage.AWAITING_VERIFY && r.reason in listOf("verificationFailed", "network")) sourceFailure(r.reason, "failed")
                    else out(task.copy(stage = Stage.FAILED, failureReason = r.reason))
            }
            is Event.InstallRequested -> if (task.stage in listOf(Stage.READY, Stage.INSTALLER_LAUNCHED))
                out(task.copy(wantsInstall = task.wantsInstall || event.manual), Effect.Verify(task.generation)) else out()
            is Event.InstallLaunch -> if (task.stage != Stage.READY) out() else when {
                event.launched -> out(task.copy(stage = Stage.INSTALLER_LAUNCHED, wantsInstall = false))
                !event.foreground -> out(task.copy(wantsInstall = false), Effect.Notify(task.generation))
                event.permissionMissing -> out(task.copy(wantsInstall = true))
                else -> out(task.copy(wantsInstall = false))
            }
            is Event.Resumed -> when {
                task.stage == Stage.INSTALLER_LAUNCHED -> out(task.copy(stage = Stage.READY, wantsInstall = false))
                // 广播不等校验；进程若在校验中被杀，回前台补发一次（executor 按身份去重）。
                task.stage == Stage.AWAITING_VERIFY -> out(task, Effect.Verify(task.generation))
                task.stage == Stage.READY && task.wantsInstall && event.permissionGranted && event.foreground -> out(task, Effect.LaunchInstaller(task.generation))
                else -> out()
            }
            is Event.Installed -> {
                // 已校验且读得到已安装 versionCode 时只按 versionCode 判定；否则才退回 versionName。
                val superseded = if (task.verifiedVersionCode != null && event.code != null) event.code >= task.verifiedVersionCode
                    else event.name != null && !AppUpdateVersions.isVersionNewer(task.version, event.name)
                if (superseded) cleanup(CleanupIntent.SUPERSEDED) else out()
            }
            is Event.SwitchRequested -> if (task.stage == Stage.DOWNLOADING && task.mode == "auto" && nextSource(task) != null &&
                event.reason in setOf("connectTimeout", "stalled", "slow", "paused")) sourceFailure("network", event.reason) else out()
            is Event.RetireResult -> if (task.stage != Stage.CLEANUP_PENDING) out() else if (!event.confirmed) out(retired = false) else when (task.cleanupIntent) {
                CleanupIntent.SWITCH -> {
                    val source = nextSource(task) ?: return out()
                    enqueue(task.copy(stage = Stage.ENQUEUING, cleanupIntent = null, generation = event.newGeneration,
                        source = source.source, url = source.url, tried = task.tried + source.source,
                        downloadId = 0, managedFileName = "update_" + event.newGeneration + "_" + task.fileName, verifiedVersionCode = null))
                }
                CleanupIntent.CANCEL -> out(null, canceled = true, retired = true, tag = task.releaseTag)
                CleanupIntent.SUPERSEDED -> out(null)
                null -> out()
            }
            else -> out()
        }
    }

    fun nextSource(task: Task): SourceUrl? = task.sources.firstOrNull { it.source !in task.tried }
}
