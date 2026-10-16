package edu.zjxu.jxucampushub.platform.update

internal fun sampleParams(mode: String = "auto") = StartParams("1.0", "v1.0", "app.apk", "v2:1:unknown:app.apk:nosha", mode,
    listOf(SourceUrl("r2", "https://download.fhfanshu.xyz/v1.0/app.apk"),
        SourceUrl("edgeone", "https://edgeone.gh-proxy.org/https://github.com/FHfanshu/ZJXU-CampusHub/releases/download/v1.0/app.apk")))
internal fun sampleTask(stage: Stage = Stage.DOWNLOADING): Task =
    AppUpdateMachine.reduce(null, Event.Start(sampleParams(), 5)).task!!.copy(stage = stage,
        downloadId = if (stage == Stage.ENQUEUING || stage == Stage.RECONCILE_REQUIRED) 0 else 9,
        failureReason = if (stage == Stage.FAILED) "network" else null,
        cleanupIntent = if (stage == Stage.CLEANUP_PENDING) CleanupIntent.CANCEL else null)

internal fun runMachineTests() {
    // 每行覆盖全部八个 stage；独立写出目标 stage 与 effect，空白 = 原任务不变。
    // 列序 E,D,V,R,I,F,Q,C。不以 reducer 自身结果生成期望。
    data class Row(val event: Event, val stages: String, val effects: String)
    val rows = listOf(
        Row(Event.Start(sampleParams(), 6), "= = = = = C = =", "- - - - - T - -"),
        Row(Event.Start(sampleParams().copy(requestKey = "other"), 6), "C C C C C C C C", "T T T T T T T T"),
        Row(Event.Observe(DmObs.Pending(1, 2)), "= = = = = = = =", "- - V - - - - -"),
        Row(Event.Observe(DmObs.Running(1, 2)), "= = = = = = = =", "- - V - - - - -"),
        Row(Event.Observe(DmObs.Paused(1, 2)), "= = = = = = = =", "- - V - - - - -"),
        Row(Event.Observe(DmObs.Successful), "= V = = = = = =", "- V V - - - - -"),
        Row(Event.Observe(DmObs.Absent), "= V = = = = = =", "- V V - - - - -"),
        Row(Event.Observe(DmObs.Unavailable), "= = = = = = = =", "- - V - - - - -"),
        Row(Event.Observe(DmObs.Failed("network")), "= C = = = = = =", "- T V - - - - -"),
        Row(Event.ReconcileScan(AppUpdateOwnership.Scan.Unique(8), false), "D = = = = = D =", "- - - - - - - -"),
        Row(Event.ReconcileScan(AppUpdateOwnership.Scan.NotFound, false), "E = = = = = E =", "E - - - - - E -"),
        Row(Event.ReconcileScan(AppUpdateOwnership.Scan.NotFound, true), "Q = = = = = Q =", "- - - - - - - -"),
        Row(Event.ReconcileScan(AppUpdateOwnership.Scan.Unavailable, false), "Q = = = = = Q =", "- - - - - - - -"),
        Row(Event.ReconcileScan(AppUpdateOwnership.Scan.Incomplete, false), "Q = = = = = Q =", "- - - - - - - -"),
        Row(Event.ReconcileScan(AppUpdateOwnership.Scan.Ambiguous(2), false), "Q = = = = = Q =", "- - - - - - - -"),
        Row(Event.Enqueued(5, 8), "D = = = = = = =", "- - - - - - - -"),
        Row(Event.EnqueueFailed(5), "F = = = = = = =", "- - - - - - - -"),
        Row(Event.VerifyResult(5, Verification.Verified(100)), "= = R R R = = =", "- - L L L - - -"),
        Row(Event.VerifyResult(5, Verification.Failed("verificationFailed")), "= = C F F = = =", "- - T - - - - -"),
        Row(Event.VerifyResult(5, Verification.Failed("packageMismatch")), "= = F F F = = =", "- - - - - - - -"),
        Row(Event.InstallRequested(true), "= = = = = = = =", "- - - V V - - -"),
        Row(Event.InstallRequested(false), "= = = = = = = =", "- - - V V - - -"),
        Row(Event.InstallLaunch(5, true, false, true), "= = = I = = = =", "- - - - - - - -"),
        Row(Event.InstallLaunch(5, false, true, true), "= = = R = = = =", "- - - - - - - -"),
        Row(Event.InstallLaunch(5, false, false, false), "= = = R = = = =", "- - - N - - - -"),
        Row(Event.InstallLaunch(5, false, false, true), "= = = R = = = =", "- - - - - - - -"),
        Row(Event.Resumed(true, true), "= = = = R = = =", "- - V L - - - -"),
        Row(Event.Resumed(false, true), "= = = = R = = =", "- - V - - - - -"),
        Row(Event.Installed(null, "0.1"), "= = = = = = = =", "- - - - - - - -"),
        Row(Event.Installed(null, "1.0"), "C C C C C C C C", "T T T T T T T T"),
        Row(Event.Cancel, "C C C C C C C C", "T T T T T T T T"),
        Row(Event.SwitchRequested("stalled", 5), "= C = = = = = =", "- T - - - - - -"),
        Row(Event.SwitchRequested("failed", 5), "= = = = = = = =", "- - - - - - - -"),
        Row(Event.RetireResult(5, true, 6), "= = = = = = = X", "- - - - - - - -"),
        Row(Event.RetireResult(5, false), "= = = = = = = =", "- - - - - - - -"),
    )
    val symbols = mapOf("E" to Stage.ENQUEUING, "D" to Stage.DOWNLOADING, "V" to Stage.AWAITING_VERIFY,
        "R" to Stage.READY, "I" to Stage.INSTALLER_LAUNCHED, "F" to Stage.FAILED,
        "Q" to Stage.RECONCILE_REQUIRED, "C" to Stage.CLEANUP_PENDING)
    fun effectName(e: Effect): String = when (e) {
        is Effect.Enqueue -> "E"; is Effect.Retire -> "T"; is Effect.Verify -> "V"
        is Effect.LaunchInstaller -> "L"; is Effect.Notify -> "N"; Effect.Scan -> "S"
    }
    var count = 0
    for (row in rows) for ((i, stage) in Stage.entries.withIndex()) {
        val old = sampleTask(stage)
        val result = AppUpdateMachine.reduce(old, row.event)
        val expected = row.stages.split(' ')[i]
        val effect = row.effects.split(' ')[i]
        check(result.task?.stage == if (expected == "=") stage else symbols[expected]) { stage.toString() + " / " + row.event }
        check(result.effects.map(::effectName) == if (effect == "-") emptyList() else listOf(effect)) { stage.toString() + " effects / " + row.event }
        if (expected == "=" && effect == "-" && row.event !is Event.InstallLaunch && row.event !is Event.InstallRequested)
            check(result.task == old) { "illegal combination mutated: " + stage + " / " + row.event }
        count++
    }
    val t = sampleTask()
    for (e in listOf(Event.Enqueued(4, 1), Event.EnqueueFailed(4), Event.VerifyResult(4, Verification.Verified(100)),
        Event.InstallLaunch(4, true, false, true), Event.RetireResult(4, true))) {
        for (stage in Stage.entries) {
            val old = sampleTask(stage)
            val r = AppUpdateMachine.reduce(old, e)
            check(r.task == old && r.effects.isEmpty())
        }
    }
    // SWITCH/CANCEL/SUPERSEDED 清理的确认/未确认路径，以及耗尽与手动模式。
    for (intent in CleanupIntent.entries) for (confirmed in listOf(false, true)) {
        val old = sampleTask(Stage.CLEANUP_PENDING).copy(cleanupIntent = intent)
        val r = AppUpdateMachine.reduce(old, Event.RetireResult(5, confirmed, 90))
        when {
            !confirmed -> check(r.task == old && r.effects.isEmpty())
            intent == CleanupIntent.SWITCH -> {
                check(r.task!!.stage == Stage.ENQUEUING && r.task.generation == 90 && r.task.tried == listOf("r2", "edgeone"))
                check(r.effects.single() == Effect.Enqueue(90, old.sources[1].url, "update_90_app.apk"))
            }
            else -> check(r.task == null && r.effects.isEmpty())
        }
    }
    for (reason in listOf("connectTimeout", "stalled", "slow", "paused")) {
        check(AppUpdateMachine.reduce(t, Event.SwitchRequested(reason, 5)).task!!.switchReason == reason)
        // 换源后迟到的建议（旧 attempt）作废。
        check(AppUpdateMachine.reduce(t, Event.SwitchRequested(reason, 4)).task == t)
    }
    val manual = t.copy(mode = "manual")
    check(AppUpdateMachine.reduce(manual, Event.SwitchRequested("slow", 5)).task == manual)
    check(AppUpdateMachine.reduce(manual, Event.Observe(DmObs.Failed("network"))).task!!.stage == Stage.FAILED)
    val exhausted = t.copy(tried = listOf("r2", "edgeone"))
    check(AppUpdateMachine.reduce(exhausted, Event.Observe(DmObs.Failed("network"))).task!!.stage == Stage.FAILED)
    check(AppUpdateMachine.reduce(t.copy(verifiedVersionCode = 99), Event.Installed(99, null)).task!!.cleanupIntent == CleanupIntent.SUPERSEDED)
    // 已校验且读得到 versionCode 时只看 versionCode：同名不同 code（98 < 99）不算已安装。
    check(AppUpdateMachine.reduce(t.copy(verifiedVersionCode = 99), Event.Installed(98, "1.0")).task == t.copy(verifiedVersionCode = 99))
    val cancel = AppUpdateMachine.reduce(null, Event.Cancel)
    check(cancel.task == null && cancel.view.canceled && cancel.view.retired == true)
    check(AppUpdateMachine.reduce(null, Event.Start(sampleParams(), 44)).effects.single() is Effect.Enqueue)
    for (r in rows.filter { it.event !is Event.Start && it.event != Event.Cancel }) {
        val result = AppUpdateMachine.reduce(null, r.event)
        check(result.task == null && result.effects.isEmpty())
    }
    println("AppUpdateMachine: " + count + " stage/event cells + guards/cleanup passed")
}
