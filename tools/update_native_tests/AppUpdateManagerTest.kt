package edu.zjxu.jxucampushub.platform.update

import android.app.Activity
import android.app.DownloadManager
import android.content.Context
import android.content.Intent
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

internal fun newManager(c: Context): AppUpdateManager = AppUpdateManager::class.java.getDeclaredConstructor(Context::class.java).let {
    it.isAccessible = true; it.newInstance(c)
}
internal fun runManagerTests(root: File) {
    var cases = 0
    fun context() = Context().apply { this.root = File(root, "case_" + cases).apply { mkdirs() } }
    fun case(name: String, body: () -> Unit) {
        cases++
        AppUpdateVerifier.verifyAction = { AppUpdateVerifier.Outcome.Verified("1.0", false) }
        body()
        println("PASS " + name)
    }
    fun await(l: CountDownLatch) { check(l.await(5, TimeUnit.SECONDS)) { "latch timed out" } }
    fun waitUntil(body: () -> Boolean) {
        val end = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
        while (!body()) { check(System.nanoTime() < end) { "condition timed out" }; Thread.sleep(5) }
    }
    // 测试每次新建 Store 实例读取；锁住 prefs 才能与 manager 后台线程的整条写入互斥，避免读到半条记录。
    fun task(c: Context) = synchronized(c.getSharedPreferences("app_update_managed_v2", 0).data) {
        AppUpdateStore(c, (c.applicationInfo.flags and 2) != 0).read()!!
    }
    fun file(c: Context): File = File(c.root, "updates/" + task(c).managedFileName).apply { parentFile.mkdirs(); writeText("apk") }
    fun successful(c: Context) { c.downloads.rows.values.single().status = DownloadManager.STATUS_SUCCESSFUL }
    fun failure(c: Context) { c.downloads.rows.values.single().apply { status = DownloadManager.STATUS_FAILED; reason = DownloadManager.ERROR_HTTP_DATA_ERROR } }
    fun manual() = sampleParams("manual").copy(sources = sampleParams().sources.take(1))

    case("crashPending_scanUnavailable_cancelRetainsIdentity") {
        val c = context(); val m = newManager(c)
        c.downloads.afterEnqueue = { throw AssertionError("process died before id writeback") }
        check(runCatching { m.startDownload(sampleParams()) }.isFailure)
        c.downloads.afterEnqueue = null
        check(task(c).stage == Stage.ENQUEUING && c.downloads.rows.size == 1)
        val identity = task(c)
        val restarted = newManager(c)
        c.downloads.throwQuery = true
        check(restarted.queryActive()!!["phase"] == "reconcileRequired")
        check(task(c).managedFileName == identity.managedFileName)
        val retry = restarted.startDownload(sampleParams())
        check(retry["phase"] == "reconcileRequired" && c.downloads.enqueues == 1)
        val canceled = restarted.cancelActive()
        check(canceled["phase"] == "cleanupPending" && canceled["retired"] == false && canceled["releaseTag"] == "v1.0")
        check(task(c).requestKey == identity.requestKey && task(c).managedFileName == identity.managedFileName)
        c.downloads.throwQuery = false
        check(restarted.queryActive() == null && c.downloads.rows.isEmpty())
    }
    case("crashPending_recoverUnique_noSecondDownload") {
        val c = context(); val s = AppUpdateStore(c); s.read(); s.update { sampleTask(Stage.ENQUEUING) }
        // 相同 URL、不同目标属于 WebView 下载，绝不可认领/移除。
        c.downloads.rows[77] = DownloadManager.Row(77, sampleTask().url, "file:///public/app.apk")
        c.downloads.rows[78] = DownloadManager.Row(78, sampleTask().url, File(c.root, "updates/update_5_app.apk").toURI().toString().replaceFirst("file:/", "file:///"))
        val m = newManager(c)
        c.downloads.nullCursor = true
        check(m.queryActive()!!["phase"] == "reconcileRequired")
        c.downloads.nullCursor = false
        check(m.queryActive() != null && task(c).downloadId == 78L && c.downloads.enqueues == 0)
        check(m.cancelActive()["retired"] == true && c.downloads.rows.keys == setOf(77L))
    }
    case("dmQueryUnavailable_once_neverFailed") {
        val c = context(); val m = newManager(c); m.startDownload(sampleParams())
        val old = task(c)
        for (nullCursor in listOf(false, true)) {
            c.downloads.throwQuery = !nullCursor; c.downloads.nullCursor = nullCursor
            val view = m.queryActive()!!
            check(view["phase"] == "downloading" && "bytesDownloaded" !in view)
            check(task(c) == old)
        }
        c.downloads.throwQuery = false; c.downloads.nullCursor = false
        c.downloads.rows.values.single().status = DownloadManager.STATUS_RUNNING
        check(m.queryActive()!!["phase"] == "downloading" && task(c).stage == Stage.DOWNLOADING)
    }
    case("cancelRemoveFailure_cleanupPending_retiredFalse") {
        val c = context(); val m = newManager(c); m.startDownload(sampleParams()); val old = task(c)
        file(c); c.downloads.removeFails = true
        val view = m.cancelActive()
        check(view["phase"] == "cleanupPending" && view["retired"] == false && view["releaseTag"] == "v1.0")
        check(task(c).downloadId == old.downloadId && !task(c).wantsInstall)
        val path = File(c.root, "updates/" + old.managedFileName)
        check(path.exists())
        m.startDownload(sampleParams().copy(requestKey = "v2:new"))
        check(c.downloads.enqueues == 1 && task(c).downloadId == old.downloadId)
        c.downloads.removeFails = false
        check(m.cancelActive()["retired"] == true && !path.exists())
        check(m.cancelActive()["releaseTag"] == "")
    }
    case("autoR2FailureBroadcast_switchesEdgeOne_withoutDart") {
        val c = context(); val m = newManager(c); m.startDownload(sampleParams()); val old = task(c)
        failure(c)
        var done = false; m.onDownloadComplete(old.downloadId) { done = true }
        val next = task(c)
        check(done && next.source == "edgeone" && next.stage == Stage.DOWNLOADING && next.generation > old.generation)
        check(next.requestKey == old.requestKey && next.tried == listOf("r2", "edgeone") && c.downloads.rows.size == 1)
        check(next.switchReason == "failed" && next.fellBackFrom == "r2")
        failure(c); m.onDownloadComplete(next.downloadId)
        check(m.queryActive()!!["exhausted"] == true)
    }
    case("switchCleanupPending_projectsSwitchingTo_andPollRetries") {
        val c = context(); val m = newManager(c); m.startDownload(sampleParams())
        c.downloads.removeFails = true
        val v = m.switchSource("stalled", task(c).generation)!!
        check(v["phase"] == "cleanupPending" && v["switching"] == true && v["switchingTo"] == "edgeone")
        check(c.downloads.enqueues == 1)
        c.downloads.removeFails = false
        check(m.queryActive()!!["source"] == "edgeone" && c.downloads.rows.size == 1)
    }
    case("lateSwitchSuggestion_neverBurnsNextSource_orFinishedDownload") {
        // 下载其实已完成：先观察 DM，进入校验，不把完成的 APK 当停滞换掉。
        val c = context(); val m = newManager(c); m.startDownload(sampleParams()); file(c); successful(c)
        val gen = task(c).generation
        m.switchSource("stalled", gen)
        check(task(c).source == "r2" && task(c).stage != Stage.CLEANUP_PENDING && c.downloads.enqueues == 1)
        // 已自动换到 EdgeOne 后，针对旧 attempt 的迟到建议作废。
        val c2 = context(); val m2 = newManager(c2); m2.startDownload(sampleParams()); val old = task(c2)
        failure(c2); m2.onDownloadComplete(old.downloadId)
        check(task(c2).source == "edgeone")
        m2.switchSource("stalled", old.generation)
        check(task(c2).source == "edgeone" && task(c2).stage == Stage.DOWNLOADING && c2.downloads.enqueues == 2)
    }
    case("digestFailure_switchesSource") {
        val c = context(); val m = newManager(c); m.startDownload(sampleParams()); file(c); successful(c)
        AppUpdateVerifier.verifyAction = { AppUpdateVerifier.Outcome.Failed("verificationFailed", "sha mismatch") }
        m.onDownloadComplete(task(c).downloadId)
        waitUntil { task(c).source == "edgeone" && task(c).stage == Stage.DOWNLOADING }
        check(task(c).stage == Stage.DOWNLOADING && c.downloads.enqueues == 2 && c.downloads.rows.size == 1)
    }
    for (byCode in listOf(true, false)) case(if (byCode) "installedVersionCode_supersededClears" else "installedVersionName_supersededClears") {
        val c = context(); val m = newManager(c); m.startDownload(sampleParams()); file(c)
        AppUpdateStore(c).update { it!!.copy(stage = Stage.FAILED, failureReason = "network", verifiedVersionCode = if (byCode) 100L else null) }
        if (byCode) c.packageManager.installed.longVersionCode = 100 else c.packageManager.installed.versionName = "1.0+999"
        check(m.queryActive() == null && c.downloads.rows.isEmpty())
    }
    case("installedSuperseded_removeUnconfirmed_retainsIdentity") {
        val c = context(); val m = newManager(c); m.startDownload(sampleParams())
        c.downloads.removeFails = true; c.packageManager.installed.versionName = "2.0"
        check(m.queryActive()!!["phase"] == "cleanupPending")
        check(task(c).cleanupIntent == CleanupIntent.SUPERSEDED)
        c.downloads.removeFails = false; check(m.queryActive() == null)
    }
    case("sequenceSurvivesCancelRestart_andStartIdempotent") {
        val c = context(); val m = newManager(c)
        m.startDownload(sampleParams()); val first = task(c)
        m.startDownload(sampleParams()); check(c.downloads.enqueues == 1)
        m.cancelActive(); newManager(c).startDownload(sampleParams()); val second = task(c)
        check(second.generation > first.generation && second.managedFileName != first.managedFileName)
    }
    case("storageFailure_noEnqueue_orOrphan") {
        for (offset in 1..3) {
            val c = context(); AppUpdateStore(c).read()
            c.prefs.failCommitAt = c.prefs.commits + offset
            val m = newManager(c)
            check(runCatching { m.startDownload(sampleParams()) }.exceptionOrNull() is AppUpdateException)
            check(c.downloads.enqueues == if (offset == 3) 1 else 0)
            check(c.downloads.rows.isEmpty())
            check(runCatching { m.queryActive() }.exceptionOrNull() is AppUpdateException)
        }
    }
    case("unfinishedAndFailedDownload_neverVerifies") {
        val c = context(); val m = newManager(c); m.startDownload(manual())
        var verified = false; AppUpdateVerifier.verifyAction = { verified = true; error("should not verify") }
        m.requestInstall(null) { check(!it) }
        c.downloads.rows.values.single().apply { status = DownloadManager.STATUS_FAILED; reason = DownloadManager.ERROR_INSUFFICIENT_SPACE }
        m.onDownloadComplete(task(c).downloadId)
        check(m.queryActive()!!["reason"] == "storageInsufficient" && !verified)
        check(m.queryActive()!!["releaseTag"] == "v1.0")
    }
    case("lateVerificationAfterCancel_doesNotMutateNewAttempt") {
        val c = context(); val m = newManager(c); m.startDownload(manual()); file(c); successful(c)
        val entered = CountDownLatch(1); val release = CountDownLatch(1); val finished = CountDownLatch(1)
        AppUpdateVerifier.verifyAction = { entered.countDown(); await(release); finished.countDown(); AppUpdateVerifier.Outcome.Verified("1.0", false) }
        m.onDownloadComplete(task(c).downloadId); await(entered)
        m.cancelActive(); m.startDownload(manual()); val next = task(c)
        release.countDown(); await(finished)
        check(task(c) == next && task(c).verifiedVersionCode == null)
    }
    case("receiverFinishesBeforeVerifier_andNotifiesInBackground") {
        val c = context(); val m = newManager(c)
        AppUpdateManager::class.java.getDeclaredField("instance").apply { isAccessible = true; set(null, m) }
        m.startDownload(manual()); file(c); successful(c)
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        AppUpdateVerifier.verifyAction = { entered.countDown(); await(release); AppUpdateVerifier.Outcome.Verified("1.0", false) }
        val before = AppUpdateNotifications.posts
        val receiver = AppUpdateDownloadReceiver()
        receiver.onReceive(c, Intent(DownloadManager.ACTION_DOWNLOAD_COMPLETE).apply { id = task(c).downloadId })
        await(entered); await(receiver.pending!!.finished)
        check(task(c).stage == Stage.AWAITING_VERIFY)
        release.countDown(); waitUntil { task(c).stage == Stage.READY && !task(c).wantsInstall && AppUpdateNotifications.posts > before }
        check(AppUpdateNotifications.posts > before)
    }
    case("permissionResume_installerCancel_staysManual") {
        val c = context(); val m = newManager(c); val a = Activity()
        m.attachActivity(a); m.startDownload(manual()); file(c); successful(c); m.queryActive()
        waitUntil { task(c).stage == Stage.READY && task(c).wantsInstall }
        m.queryActive() // 等待 reducer 的 effect 投递完成，再排主线程屏障。
        val mainDrained = CountDownLatch(1)
        android.os.Handler(android.os.Looper.getMainLooper()).post { mainDrained.countDown() }
        await(mainDrained)
        check(m.queryActive()!!["phase"] == "permissionRequired" && task(c).wantsInstall)
        c.packageManager.installsAllowed = true; m.onActivityResumed(a)
        waitUntil { task(c).stage == Stage.INSTALLER_LAUNCHED && a.launches == 1 }
        m.onActivityResumed(a)
        check(task(c).stage == Stage.READY && !task(c).wantsInstall && a.launches == 1)
        val done = CountDownLatch(1)
        m.requestInstall(a, "v1.0") { check(it); done.countDown() }; await(done)
        check(a.launches == 2)
    }
    case("resumeDuringManualVerification_waitsForRecheck_onceCallback") {
        val c = context(); val m = newManager(c); m.startDownload(sampleParams()); file(c); successful(c)
        m.queryActive(); waitUntil { task(c).stage == Stage.READY && !task(c).wantsInstall }
        c.packageManager.installsAllowed = true
        val a = Activity(); m.attachActivity(a)
        val entered = CountDownLatch(1); val release = CountDownLatch(1); val done = CountDownLatch(1)
        var callbacks = 0
        AppUpdateVerifier.verifyAction = { entered.countDown(); await(release); AppUpdateVerifier.Outcome.Verified("1.0", false) }
        m.requestInstall(a) { check(it); callbacks++; done.countDown() }
        await(entered); m.onActivityResumed(a)
        val barrier = CountDownLatch(1)
        android.os.Handler(android.os.Looper.getMainLooper()).post { barrier.countDown() }
        await(barrier); check(a.launches == 0)
        release.countDown(); await(done)
        check(a.launches == 1 && callbacks == 1)
    }
    case("manualRecheckDigestFailure_doesNotSwitch") {
        val c = context(); val m = newManager(c); m.startDownload(sampleParams()); file(c); successful(c)
        m.queryActive(); waitUntil { task(c).stage == Stage.READY && !task(c).wantsInstall }
        val old = task(c)
        AppUpdateVerifier.verifyAction = { AppUpdateVerifier.Outcome.Failed("verificationFailed", "changed file") }
        val done = CountDownLatch(1)
        m.requestInstall(Activity()) { check(!it); done.countDown() }; await(done)
        check(task(c).stage == Stage.FAILED && task(c).generation == old.generation && c.downloads.enqueues == 1)
    }
    case("installerException_keepsReadyManual") {
        val c = context(); val m = newManager(c); m.startDownload(manual()); file(c); successful(c)
        m.queryActive(); waitUntil { task(c).stage == Stage.READY && !task(c).wantsInstall }
        val a = Activity().apply { launchAction = { error("installer rejected") } }
        c.packageManager.installsAllowed = true; m.attachActivity(a)
        val done = CountDownLatch(1)
        m.requestInstall(a) { check(!it); done.countDown() }; await(done)
        check(task(c).stage == Stage.READY && !task(c).wantsInstall && a.launches == 0)
    }
    case("oldActivityDuringVerification_neverLaunches") {
        val c = context(); val m = newManager(c); val a = Activity()
        c.packageManager.installsAllowed = true; m.attachActivity(a)
        m.startDownload(manual()); file(c); successful(c)
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        AppUpdateVerifier.verifyAction = { entered.countDown(); await(release); AppUpdateVerifier.Outcome.Verified("1.0", false) }
        m.queryActive(); await(entered); m.detachActivity(a); m.attachActivity(Activity()); release.countDown()
        waitUntil { task(c).stage == Stage.READY && !task(c).wantsInstall }
        check(a.launches == 0)
    }
    case("debugTestSource_requiresApplicationFlag") {
        val p = manual().copy(sources = listOf(SourceUrl("test", "http://10.0.2.2:8000/v1.0/app.apk")))
        val c = context(); check(runCatching { newManager(c).startDownload(p) }.exceptionOrNull() is AppUpdateException)
        c.applicationInfo.flags = android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE
        check(newManager(c).startDownload(p)["source"] == "test")
    }
    case("dmAbsent_verifiesMissingFile_andUnavailableDoesNot") {
        val c = context(); val m = newManager(c); m.startDownload(manual())
        var calls = 0
        AppUpdateVerifier.verifyAction = { calls++; AppUpdateVerifier.Outcome.Failed("verificationFailed", "missing") }
        c.downloads.rows.clear(); m.queryActive()
        waitUntil { task(c).stage == Stage.FAILED }
        check(calls == 1)
    }
    case("foreignTrackedRow_cancelRefuses_andBadParamsNoMutation") {
        val c = context(); val m = newManager(c); m.startDownload(sampleParams()); val before = task(c)
        c.downloads.rows[before.downloadId] = DownloadManager.Row(before.downloadId, before.url, "file:///public/app.apk")
        check(m.cancelActive()["retired"] == false && c.downloads.rows.size == 1)
        val after = task(c)
        check(runCatching { m.startDownload(sampleParams().copy(releaseTag = "other")) }.exceptionOrNull() is AppUpdateException)
        check(runCatching { m.switchSource("failed", 0) }.exceptionOrNull() is AppUpdateException)
        check(task(c) == after)
    }
    println("AppUpdate Manager/Receiver: " + cases + " scenarios passed")
}
