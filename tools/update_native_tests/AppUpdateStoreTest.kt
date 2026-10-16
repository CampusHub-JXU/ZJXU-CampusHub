package edu.zjxu.jxucampushub.platform.update

import android.content.Context

internal fun runStoreTests() {
    data class Migration(val name: String, val id: Long, val flags: Map<String, Any?>, val expected: Stage)
    val rows = listOf(
        Migration("pending", 0, mapOf("pending_enqueue" to true), Stage.ENQUEUING),
        Migration("unresolved", 0, mapOf("failure_reason" to "nativeError"), Stage.FAILED),
        Migration("installer", 3, mapOf("installer_opened" to true, "verified" to true), Stage.INSTALLER_LAUNCHED),
        Migration("verified", 3, mapOf("verified" to true), Stage.READY),
        Migration("failed", 3, mapOf("failure_reason" to "network"), Stage.FAILED),
        Migration("downloading", 3, emptyMap(), Stage.DOWNLOADING),
        Migration("other", 0, emptyMap(), Stage.RECONCILE_REQUIRED),
    )
    for (row in rows) {
        val c = Context()
        val old = c.getSharedPreferences("app_update_managed_v1", 0)
        val t = sampleTask()
        old.data.putAll(mapOf("request_key" to t.requestKey, "version" to t.version, "url" to t.url,
            "file_name" to t.fileName, "managed_file_name" to t.managedFileName, "download_id" to row.id,
            "generation" to 5, "attempt_sequence" to 40, "user_wants_install" to true) + row.flags)
        c.prefs.data["attempt_sequence"] = 50
        val store = AppUpdateStore(c)
        val migrated = store.read()!!
        check(migrated.stage == row.expected) { row.name + " -> " + migrated.stage }
        check(migrated.mode == "manual" && migrated.releaseTag == "v1.0" && migrated.wantsInstall)
        check(migrated.sources == listOf(SourceUrl("r2", t.url)) && migrated.tried == listOf("r2"))
        check(migrated.verifiedVersionCode == null && old.data.isEmpty())
        check(AppUpdateStore(c).read() == migrated)
        store.clear()
        check(store.nextGeneration() == 51)
    }
    // 编码各部分损坏都隔离候选，但不丢失待退役 URL/文件/id。
    val corruptions = listOf(
        "sources" to "r2\tbad\textra", "sources" to "r2\turl\n", "sources" to "bogus\turl",
        "tried" to "r2,r2", "tried" to "unknown", "tried" to "r2,", "mode" to "unknown",
        "stage" to "UNKNOWN", "source" to "bogus", "cleanup_intent" to "bogus",
    )
    for ((field, value) in corruptions) {
        val c = Context()
        val store = AppUpdateStore(c)
        store.read()
        store.update { sampleTask(if (field == "cleanup_intent") Stage.CLEANUP_PENDING else Stage.DOWNLOADING) }
        c.prefs.data[field] = value
        val recovered = AppUpdateStore(c).read()!!
        check(recovered.stage == Stage.RECONCILE_REQUIRED) { field }
        check(recovered.downloadId == 9L && recovered.url == sampleTask().url && recovered.managedFileName == "update_5_app.apk")
        store.update { recovered.copy(stage = Stage.CLEANUP_PENDING, cleanupIntent = CleanupIntent.CANCEL) }
        check(store.read()!!.stage == Stage.CLEANUP_PENDING)
    }
    for (field in listOf("sources", "stage", "request_key", "generation", "migrated")) {
        val c = Context()
        val s = AppUpdateStore(c)
        s.read(); s.update { sampleTask() }
        c.prefs.data[field] = if (field == "generation" || field == "migrated") "bad type" else 123
        val recovered = AppUpdateStore(c).read()!!
        check(recovered.stage == (if (field == "migrated") Stage.DOWNLOADING else Stage.RECONCILE_REQUIRED) && recovered.downloadId == 9L) { field }
    }
    val missing = Context()
    AppUpdateStore(missing).read()
    missing.prefs.data.putAll(mapOf("request_key" to "broken", "sources" to "nonsense"))
    check(AppUpdateStore(missing).read() == null)
    // URL 解析失败迁移必须保留身份，releaseTag 为空串。
    val bad = Context()
    bad.getSharedPreferences("app_update_managed_v1", 0).data.putAll(mapOf(
        "request_key" to "old", "url" to "bad", "managed_file_name" to "update_2_app.apk", "generation" to 2))
    val retained = AppUpdateStore(bad).read()!!
    check(retained.stage == Stage.RECONCILE_REQUIRED && retained.releaseTag == "")
    // 任一 commit 失败都禁用本实例（包括 v2 写失败及清 v1 失败）。
    for (oldFailure in listOf(false, true)) {
        val c = Context()
        if (oldFailure) c.getSharedPreferences("app_update_managed_v1", 0).failCommitAt = 1 else c.prefs.failCommitAt = 1
        val s = AppUpdateStore(c)
        check(runCatching { s.read() }.exceptionOrNull() is AppUpdateException)
        check(runCatching { s.nextGeneration() }.exceptionOrNull() is AppUpdateException)
        if (oldFailure) check(c.prefs.getBoolean("migrated", false))
    }
    val sequence = Context()
    val s = AppUpdateStore(sequence)
    s.read(); s.update { sampleTask() }
    val commits = sequence.prefs.commits
    s.update { it!!.copy(wantsInstall = false) }
    check(sequence.prefs.commits == commits + 1)
    s.clear(); check(s.nextGeneration() == 6)
    println("AppUpdateStore: 7 migration rows + corrupt encodings/atomicity/failures passed")
}
