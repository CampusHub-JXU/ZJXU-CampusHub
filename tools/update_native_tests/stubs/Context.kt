package android.content

import android.app.DownloadManager
import java.io.File

open class Context {
    companion object { const val MODE_PRIVATE = 0 }
    open val applicationContext: Context get() = this
    open val packageName = "test.app"
    val prefs = SharedPreferences()
    val downloads = DownloadManager()
    var root = File(".")
    val packageManager = PackageManager()
    fun getSharedPreferences(name: String, mode: Int) = prefs
    fun <T> getSystemService(type: Class<T>): T? = type.cast(downloads)
    fun getExternalFilesDir(type: String): File = root
}
class PackageManager {
    var installsAllowed = false
    fun canRequestPackageInstalls() = installsAllowed
}
class SharedPreferences {
    val data = mutableMapOf<String, Any?>()
    var failCommitAt = 0
    var commits = 0
    fun getString(key: String, default: String?) = data[key] as String? ?: default
    fun getLong(key: String, default: Long) = data[key] as Long? ?: default
    fun getInt(key: String, default: Int) = data[key] as Int? ?: default
    fun getBoolean(key: String, default: Boolean) = data[key] as Boolean? ?: default
    fun edit() = Editor()
    inner class Editor {
        private val changed = mutableMapOf<String, Any?>()
        private var clear = false
        fun clear() = apply { clear = true }
        fun putString(k: String, v: String?) = apply { changed[k] = v }
        fun putLong(k: String, v: Long) = apply { changed[k] = v }
        fun putInt(k: String, v: Int) = apply { changed[k] = v }
        fun putBoolean(k: String, v: Boolean) = apply { changed[k] = v }
        fun commit(): Boolean {
            // Android updates memory even when writing the preferences file fails.
            if (clear) data.clear()
            data.putAll(changed)
            commits++
            return commits != failCommitAt
        }
    }
}
class Intent(val action: String? = null, val uri: android.net.Uri? = null) {
    companion object { const val ACTION_VIEW = "view"; const val FLAG_GRANT_READ_URI_PERMISSION = 1 }
    var id = -1L
    var requestKey: String? = null
    fun getLongExtra(key: String, default: Long) = id
    fun getStringExtra(key: String) = requestKey
    fun setDataAndType(uri: android.net.Uri, type: String) {}
    fun addFlags(flags: Int) {}
}
open class BroadcastReceiver {
    open fun onReceive(context: Context, intent: Intent) {}
    class PendingResult {
        val finished = java.util.concurrent.CountDownLatch(1)
        fun finish() { finished.countDown() }
    }
    var pending: PendingResult? = null
    fun goAsync() = PendingResult().also { pending = it }
}
