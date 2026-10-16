package edu.zjxu.jxucampushub.platform.update

import android.content.Context
import java.io.File

internal object AppUpdateVerifier {
    sealed class Outcome {
        data class Verified(val versionName: String?, val digestChecked: Boolean) : Outcome()
        data class Failed(val reason: String, val message: String) : Outcome()
    }
    var verifyAction: (File) -> Outcome = { Outcome.Verified("1.0", false) }
    fun verify(context: Context, file: File, expectedSizeBytes: Long, expectedSha256: String?,
        expectedVersion: String?) = verifyAction(file)
}
internal object AppUpdateNotifications {
    var posts = 0
    fun postCompletion(context: Context, requestKey: String) { posts++ }
}
