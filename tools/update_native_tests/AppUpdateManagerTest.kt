package edu.zjxu.jxucampushub.platform.update

import android.app.DownloadManager
import android.content.Context
import android.content.Intent
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Production Store/Manager/Receiver, with desktop substitutes only for Android APIs and APK IO. */
internal fun runManagerTests(root: File) {
    fun manager(context: Context): AppUpdateManager {
        val constructor = AppUpdateManager::class.java.getDeclaredConstructor(Context::class.java)
        constructor.isAccessible = true
        return constructor.newInstance(context)
    }
    var contexts = 0
    fun context() = Context().apply { this.root = File(root, "case_${contexts++}").apply { mkdirs() } }
    fun params() = AppUpdateManager.StartParams(
        version = "1.0", url = "https://github.com/FHfanshu/ZJXU-CampusHub/releases/download/v1.0/app.apk",
        fileName = "app.apk", requestKey = "same-request", sizeBytes = 0L, sha256 = null, abi = null,
    )
    fun CountDownLatch.awaitDone() { check(await(5, TimeUnit.SECONDS)) { "timed out" } }
    fun success(c: Context) = c.downloads.rows.values.last().apply { status = DownloadManager.STATUS_SUCCESSFUL }

    // Sequence survives both cancellation and recreation of Store (process restart).
    val c = context()
    val m = manager(c)
    m.startDownload(params())
    val first = AppUpdateStore(c).read()!!
    check(m.cancelActive()["phase"] == AppUpdatePhase.CANCELED)
    m.startDownload(params())
    val second = AppUpdateStore(c).read()!!
    check(second.generation > first.generation)
    check(second.managedFileName != first.managedFileName)
    check(AppUpdateOwnership.isStale(second.requestKey, second.generation,
        first.requestKey, first.generation))
    val migrated = context()
    migrated.prefs.data["generation"] = 87
    AppUpdateStore(migrated).clear()
    check(AppUpdateStore(migrated).nextGeneration() == 88)

    // Fail sequence or pending journal writes: enqueue is forbidden in either case.
    for (commit in 1..2) {
        val failed = context()
        failed.prefs.failCommitAt = commit
        val failedManager = manager(failed)
        val result = runCatching { failedManager.startDownload(params()) }
        check(result.exceptionOrNull() is AppUpdateException)
        check(failed.downloads.enqueues == 0)
        check(runCatching { failedManager.queryActive() }.isFailure)
        check(failed.downloads.enqueues == 0)
    }

    // The row enqueued before a failed downloadId write must not be left orphaned.
    val orphan = context()
    orphan.prefs.failCommitAt = 3
    check(runCatching { manager(orphan).startDownload(params()) }.exceptionOrNull() is AppUpdateException)
    check(orphan.downloads.enqueues == 1 && orphan.downloads.rows.isEmpty())

    // An unfinished download is never verified and never recorded as a failure.
    val running = context()
    val runManager = manager(running)
    runManager.startDownload(params())
    var verifyCalls = 0
    AppUpdateVerifier.verifyAction = { verifyCalls++; AppUpdateVerifier.Outcome.Verified("1.0", false) }
    val runDone = CountDownLatch(1)
    runManager.requestInstall(null) { check(!it); runDone.countDown() }
    runDone.awaitDone()
    check(verifyCalls == 0 && AppUpdateStore(running).read()!!.failureReason == null)

    // DM failure is mapped before touching the incomplete archive.
    val failure = context()
    val fm = manager(failure)
    fm.startDownload(params())
    failure.downloads.rows.values.single().apply {
        status = DownloadManager.STATUS_FAILED
        reason = DownloadManager.ERROR_INSUFFICIENT_SPACE
    }
    AppUpdateVerifier.verifyAction = { error("failed download must not be verified") }
    val failedDone = CountDownLatch(1)
    fm.onDownloadComplete(1) { failedDone.countDown() }
    failedDone.awaitDone()
    check(fm.queryActive()!!["reason"] == AppUpdateReason.STORAGE_INSUFFICIENT)
    val installDone = CountDownLatch(1)
    fm.requestInstall(null) { check(!it); installDone.countDown() }
    installDone.awaitDone()
    check(fm.queryActive()!!["reason"] == AppUpdateReason.STORAGE_INSUFFICIENT)

    // Hold old verification, cancel+retry same key, then complete the latest while busy.
    val racing = context()
    val rm = manager(racing)
    rm.startDownload(params())
    val old = AppUpdateStore(racing).read()!!
    success(racing)
    val entered = CountDownLatch(1)
    val release = CountDownLatch(1)
    val latestEntered = CountDownLatch(1)
    val latestRelease = CountDownLatch(1)
    AppUpdateVerifier.verifyAction = { file ->
        if (file.name == old.managedFileName) {
            entered.countDown(); release.awaitDone()
        } else {
            // The old successful result must not mark the retry as verified.
            check(!AppUpdateStore(racing).read()!!.verified)
            latestEntered.countDown(); latestRelease.awaitDone()
        }
        AppUpdateVerifier.Outcome.Verified("1.0", false)
    }
    val oldDone = CountDownLatch(1)
    rm.onDownloadComplete(1) { oldDone.countDown() }
    entered.awaitDone()
    check(rm.cancelActive()["phase"] == AppUpdatePhase.CANCELED)
    rm.startDownload(params())
    val latest = success(racing)
    val latestDone = CountDownLatch(1)
    rm.onDownloadComplete(latest.id) { latestDone.countDown() }
    release.countDown()
    latestEntered.awaitDone()
    check(latestDone.count == 1L)
    latestRelease.countDown()
    oldDone.awaitDone(); latestDone.awaitDone()
    check(AppUpdateStore(racing).read()!!.verified)
    check(rm.queryActive()!!["releaseTag"] == "v1.0")

    // Receiver's goAsync lifetime includes actual verifier work, not only scheduling.
    val receiving = context()
    val receiverManager = manager(receiving)
    AppUpdateManager::class.java.getDeclaredField("instance").apply {
        isAccessible = true; set(null, receiverManager)
    }
    receiverManager.startDownload(params())
    success(receiving)
    val verifying = CountDownLatch(1)
    val finish = CountDownLatch(1)
    AppUpdateVerifier.verifyAction = {
        verifying.countDown(); finish.awaitDone()
        AppUpdateVerifier.Outcome.Verified("1.0", false)
    }
    val receiver = AppUpdateDownloadReceiver()
    receiver.onReceive(receiving, Intent(DownloadManager.ACTION_DOWNLOAD_COMPLETE).apply { id = 1 })
    verifying.awaitDone()
    check(receiver.pending!!.finished.count == 1L)
    finish.countDown()
    receiver.pending!!.finished.awaitDone()
    check(AppUpdateStore(receiving).read()!!.verified)
    println("AppUpdate Store/Manager/Receiver: 11 scenarios passed")
}
