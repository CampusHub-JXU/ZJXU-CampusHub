package edu.zjxu.jxucampushub.platform.update

/** Runs the production JVM logic; no copied implementation or Android mocks. */
fun main(args: Array<String>) {
    fun resumed(
        verified: Boolean = true,
        permissionGranted: Boolean = true,
        installerOpened: Boolean = false,
        userWantsInstall: Boolean = true,
    ) = AppUpdateOwnership.installStateAfterResume(
        verified, permissionGranted, installerOpened, userWantsInstall,
    )

    // Permission not yet granted: wait without consuming the user's intent.
    val denied = resumed(permissionGranted = false)
    check(denied.permissionRequired && denied.userWantsInstall)
    // Granting it clears the stale permission state and allows one automatic attempt.
    val granted = resumed(userWantsInstall = denied.userWantsInstall)
    check(!granted.permissionRequired && granted.userWantsInstall)

    // Returning after cancel/failure in the system installer never auto-opens again.
    val canceled = resumed(installerOpened = true)
    check(!canceled.permissionRequired && !canceled.userWantsInstall)
    val again = resumed(userWantsInstall = canceled.userWantsInstall)
    check(!again.permissionRequired && !again.userWantsInstall)
    // A revoked permission must still be shown on return.
    val revoked = resumed(permissionGranted = false, installerOpened = true)
    check(revoked.permissionRequired && !revoked.userWantsInstall)
    // Unverified downloads are not projected as installable/permission-blocked.
    val downloading = resumed(verified = false, permissionGranted = false)
    check(!downloading.permissionRequired && downloading.userWantsInstall)
    // A canceled auto-install intent is never recreated on resume.
    check(!resumed(userWantsInstall = false).userWantsInstall)

    // Cancel/replacement guards still reject delayed results after lifecycle changes.
    check(AppUpdateOwnership.isStale(null, 0, "request", 1))
    check(AppUpdateOwnership.isStale("request", 2, "request", 1))
    check(AppUpdateOwnership.isStale("other", 1, "request", 1))
    check(!AppUpdateOwnership.isStale("request", 1, "request", 1))
    check(AppUpdateOwnership.cancelDisposition(true, false) ==
        AppUpdateOwnership.CancelDisposition.RETAIN_FAILED)
    check(AppUpdateOwnership.cancelDisposition(true, true) ==
        AppUpdateOwnership.CancelDisposition.CLEARED_CANCELED)
    check(AppUpdateOwnership.canLaunchInstaller(true, false, false))
    check(!AppUpdateOwnership.canLaunchInstaller(false, false, false))
    check(!AppUpdateOwnership.canLaunchInstaller(true, true, false))
    check(!AppUpdateOwnership.canLaunchInstaller(true, false, true))
    println("AppUpdate native lifecycle: 17 scenarios passed")
    runManagerTests(java.io.File(args.single()))
}
