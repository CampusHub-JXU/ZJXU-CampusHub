package edu.zjxu.jxucampushub.platform.update

import android.content.Context
import android.content.SharedPreferences

/**
 * v2 单任务日志。一次 commit 写全量任务及独立序号；清空任务也不回收代际。
 * commit(false) 已可能改变内存，本实例从此禁用，绝不按未落盘状态继续副作用。
 */
internal class AppUpdateStore(context: Context, private val allowTestOrigin: Boolean = false) {
    private val prefs = context.applicationContext.getSharedPreferences("app_update_managed_v2", Context.MODE_PRIVATE)
    private val legacy = context.applicationContext.getSharedPreferences("app_update_managed_v1", Context.MODE_PRIVATE)
    private val lock = Any()
    private var persistenceFailed = false
    private var initialized = false

    fun read(): Task? = synchronized(lock) { healthy(); migrate(); readLocked() }
    fun update(transform: (Task?) -> Task?): Task? = synchronized(lock) {
        healthy(); migrate()
        val next = transform(readLocked())
        writeLocked(next)
        next
    }
    fun clear() { update { null } }
    fun nextGeneration(): Int = synchronized(lock) {
        healthy(); migrate()
        val sequence = maxOf(prefs.intValue("attempt_sequence", 0), prefs.intValue("generation", 0))
        if (sequence == Int.MAX_VALUE) throw AppUpdateException(AppUpdateErrors.STORAGE, "attempt sequence exhausted")
        committed(prefs.edit().putInt("attempt_sequence", sequence + 1).commit())
        sequence + 1
    }

    private fun healthy() {
        if (persistenceFailed) throw AppUpdateException(AppUpdateErrors.STORAGE, "managed update store unavailable")
    }
    private fun committed(ok: Boolean) {
        if (!ok) {
            persistenceFailed = true
            throw AppUpdateException(AppUpdateErrors.STORAGE, "managed update persistence failed")
        }
    }

    /** 新档落盘成功才清旧档；旧档清除失败同样禁用本实例，重启仍以 v2 为准。 */
    private fun migrate() {
        if (initialized) return
        if (!prefs.booleanValue("migrated", false)) {
            val old = when {
                hasIdentity(prefs) -> decode(prefs, legacy = false)
                hasIdentity(legacy) -> decode(legacy, legacy = true)
                else -> null
            }
            val sequence = maxOf(prefs.intValue("attempt_sequence", 0), prefs.intValue("generation", 0),
                legacy.intValue("attempt_sequence", 0), legacy.intValue("generation", 0))
            writeLocked(old, sequence)
        }
        // 也重试进程死于 v2 commit 与清除 v1 之间的清旧档操作。
        committed(legacy.edit().clear().commit())
        initialized = true
    }

    private fun readLocked(): Task? {
        if (!hasIdentity(prefs) && prefs.stringValue("request_key", null) == null) return null
        val task = decode(prefs, legacy = false)
        if (task == null) writeLocked(null)
        else if (!validEncoding(prefs, task)) {
            val repaired = task.copy(stage = Stage.RECONCILE_REQUIRED, cleanupIntent = null, failureReason = null)
            // 损坏记录不丢可退役身份；清空候选使 manager 无法据损坏列表重新入队。
            val safe = repaired.copy(sources = emptyList(), tried = emptyList())
            if (task != safe || prefs.stringValue("sources", null) != "") writeLocked(safe)
            return safe
        }
        return task
    }

    private fun decode(p: SharedPreferences, legacy: Boolean): Task? {
        fun s(key: String) = p.stringValue(key, "").orEmpty()
        val url = s("url")
        val managed = s("managed_file_name")
        val id = p.longValue("download_id", 0)
        // 连可供权威退役的目标都没有时，记录没有保留价值。
        if (url.isEmpty() && managed.isEmpty() && id == 0L) return null
        val asset = AppUpdateContract.parseCanonicalAssetUrl(url, allowTestOrigin)
        val source = if (legacy) asset?.source.orEmpty() else s("source")
        val failure = p.stringValue("failure_reason", null)
        var stage = if (legacy) when {
            p.booleanValue("pending_enqueue", false) && id == 0L -> Stage.ENQUEUING
            // v1 的入队失败与对账失败都是这个形态；迁成 FAILED 等用户重试（重试 / 取消前
            // retireOwned 对 downloadId==0 的任务仍会扫描退役），不在升级后不请自来地重新下载。
            id == 0L && failure == AppUpdateReason.NATIVE_ERROR -> Stage.FAILED
            p.booleanValue("installer_opened", false) -> Stage.INSTALLER_LAUNCHED
            p.booleanValue("verified", false) -> Stage.READY
            failure != null -> Stage.FAILED
            id != 0L -> Stage.DOWNLOADING
            else -> Stage.RECONCILE_REQUIRED
        } else runCatching { Stage.valueOf(s("stage")) }.getOrDefault(Stage.RECONCILE_REQUIRED)
        if (asset == null) stage = Stage.RECONCILE_REQUIRED
        val sources = if (legacy) listOf(SourceUrl(source, url)) else s("sources").split('\n').mapNotNull {
            val parts = it.split('\t')
            if (parts.size == 2) SourceUrl(parts[0], parts[1]) else null
        }
        val intent = runCatching { CleanupIntent.valueOf(s("cleanup_intent")) }.getOrNull()
        return Task(s("request_key"), s("version"), if (legacy) asset?.tag.orEmpty() else s("release_tag"),
            s("file_name"), p.longValue("size_bytes", 0), p.stringValue("sha256", null), p.stringValue("abi", null),
            if (legacy) "manual" else s("mode"), sources,
            if (legacy) listOf(source) else s("tried").split(',').filter { it.isNotEmpty() },
            p.intValue("generation", 0), source, url, managed, id, stage,
            if (stage == Stage.FAILED) failure else null,
            if (stage == Stage.CLEANUP_PENDING) intent else null,
            p.stringValue("switch_reason", null)?.takeIf { it in AppUpdateContract.SWITCH_REASONS },
            p.stringValue("fell_back_from", null)?.takeIf { it in AppUpdateContract.SOURCES },
            p.booleanValue(if (legacy) "user_wants_install" else "wants_install", false),
            if (!legacy && p.longValue("verified_version_code", -1) >= 0) p.longValue("verified_version_code", -1) else null)
    }

    private fun validEncoding(p: SharedPreferences, t: Task): Boolean {
        // 隔离损坏列表后仍允许持久化 CANCEL/SUPERSEDED 清理意图，不能读回时抹掉。
        if (t.sources.isEmpty() && t.tried.isEmpty() &&
            t.stage in listOf(Stage.RECONCILE_REQUIRED, Stage.CLEANUP_PENDING)) {
            return t.stage != Stage.CLEANUP_PENDING || t.cleanupIntent != null
        }
        if (t.sources.isEmpty() || t.sources.size > 3 || t.sources.map { it.source }.distinct().size != t.sources.size) return false
        if (t.mode !in listOf("manual", "auto") || t.generation <= 0 || t.requestKey.isBlank()) return false
        if (!AppUpdateOwnership.isManagedFileName(t.managedFileName)) return false
        if (p.stringValue("sources", "") != t.sources.joinToString("\n") { it.source + "\t" + it.url }) return false
        if (t.sources.any {
                val a = AppUpdateContract.parseCanonicalAssetUrl(it.url, allowTestOrigin)
                a == null || a.source != it.source || a.tag != t.releaseTag || a.fileName != t.fileName
            }) return false
        if (t.sources.none { it.source == t.source && it.url == t.url }) return false
        if (t.tried.isEmpty() || t.tried.distinct() != t.tried || t.source !in t.tried ||
            t.tried.any { it !in t.sources.map { s -> s.source } }) return false
        if (p.stringValue("tried", "") != t.tried.joinToString(",")) return false
        if (runCatching { Stage.valueOf(p.stringValue("stage", "").orEmpty()) }.isFailure) return false
        if (t.stage == Stage.FAILED && t.failureReason == null) return false
        return t.stage != Stage.CLEANUP_PENDING || t.cleanupIntent != null
    }

    private fun hasIdentity(p: SharedPreferences): Boolean = p.longValue("download_id", 0) != 0L ||
        !p.stringValue("url", null).isNullOrEmpty() || !p.stringValue("managed_file_name", null).isNullOrEmpty()

    // 偏好键类型损坏不能击穿恢复；能读到的身份继续保留，不能猜任意路径/id。
    private fun SharedPreferences.stringValue(key: String, default: String?): String? =
        try { getString(key, default) } catch (_: ClassCastException) { default }
    private fun SharedPreferences.longValue(key: String, default: Long): Long =
        try { getLong(key, default) } catch (_: ClassCastException) { default }
    private fun SharedPreferences.intValue(key: String, default: Int): Int =
        try { getInt(key, default) } catch (_: ClassCastException) { default }
    private fun SharedPreferences.booleanValue(key: String, default: Boolean): Boolean =
        try { getBoolean(key, default) } catch (_: ClassCastException) { default }

    private fun writeLocked(t: Task?, minimumSequence: Int = 0) {
        val sequence = maxOf(minimumSequence, prefs.intValue("attempt_sequence", 0), prefs.intValue("generation", 0), t?.generation ?: 0)
        val e = prefs.edit().clear().putBoolean("migrated", true).putInt("attempt_sequence", sequence)
        if (t != null) e.putString("request_key", t.requestKey).putString("version", t.version)
            .putString("release_tag", t.releaseTag).putString("file_name", t.fileName)
            .putLong("size_bytes", t.sizeBytes).putString("sha256", t.sha256).putString("abi", t.abi)
            .putString("mode", t.mode).putString("sources", t.sources.joinToString("\n") { it.source + "\t" + it.url })
            .putString("tried", t.tried.joinToString(",")).putInt("generation", t.generation)
            .putString("source", t.source).putString("url", t.url).putString("managed_file_name", t.managedFileName)
            .putLong("download_id", t.downloadId).putString("stage", t.stage.name)
            .putString("failure_reason", t.failureReason).putString("cleanup_intent", t.cleanupIntent?.name)
            .putString("switch_reason", t.switchReason).putString("fell_back_from", t.fellBackFrom)
            .putBoolean("wants_install", t.wantsInstall).putLong("verified_version_code", t.verifiedVersionCode ?: -1)
        committed(e.commit())
    }
}
