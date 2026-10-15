package android.app

import android.content.ContentResolver
import android.content.pm.PackageManager
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

open class Activity {
    val contentResolver = ContentResolver()
    val packageName = "edu.zjxu.test"
    private val uiThread: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "android-main-test").also { it.isDaemon = true }
    }
    @Volatile var granted = true
    @Volatile var requestPermissionsThread: String? = null
    var onPermissionRequest: ((Array<String>, Int) -> Unit)? = null

    fun checkSelfPermission(permission: String): Int =
        if (granted) PackageManager.PERMISSION_GRANTED else PackageManager.PERMISSION_DENIED

    fun requestPermissions(permissions: Array<String>, requestCode: Int) {
        requestPermissionsThread = Thread.currentThread().name
        onPermissionRequest?.invoke(permissions, requestCode)
    }

    fun runOnUiThread(action: Runnable) {
        if (Thread.currentThread().name == "android-main-test") action.run()
        else uiThread.submit(action).get(5, TimeUnit.SECONDS)
    }

    fun close() { uiThread.shutdownNow() }
}
