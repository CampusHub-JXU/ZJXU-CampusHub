package android.os

object Build {
    object VERSION { const val SDK_INT = 35 }
    object VERSION_CODES { const val O = 26; const val Q = 29 }
}
object Environment { const val DIRECTORY_DOWNLOADS = "Downloads" }
class Looper { companion object { fun getMainLooper() = Looper() } }
class Handler(looper: Looper) { fun post(action: () -> Unit) { action() } }
