package edu.zjxu.jxucampushub.platform.download

import android.app.Activity
import android.app.DownloadManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import edu.zjxu.jxucampushub.platform.invalidArgs
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * 下载通道：附件转交系统 DownloadManager，并注入 Cookie / UA / Referer。
 */
class DownloadChannelHandler(private val activity: Activity) {
    companion object {
        private const val CHANNEL = "edu.zjxu.jxucampushub/download"
    }

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "enqueueDownload" -> {
                    val url = call.argument<String>("url")
                    val fileName = call.argument<String>("fileName")
                    if (url.isNullOrBlank() || fileName.isNullOrBlank()) {
                        result.invalidArgs("url and fileName are required")
                        return@setMethodCallHandler
                    }
                    result.success(
                        enqueueDownload(
                            url = url,
                            fileName = fileName,
                            mimeType = call.argument<String>("mimeType"),
                            userAgent = call.argument<String>("userAgent"),
                            cookie = call.argument<String>("cookie"),
                            referer = call.argument<String>("referer"),
                        ),
                    )
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun enqueueDownload(
        url: String,
        fileName: String,
        mimeType: String?,
        userAgent: String?,
        cookie: String?,
        referer: String?,
    ): Boolean {
        return try {
            val safeName = fileName
                .replace(Regex("[\\\\/:*?\"<>|]"), "_")
                .trim()
                .ifEmpty { "attachment" }
            val request = DownloadManager.Request(Uri.parse(url)).apply {
                setTitle(safeName)
                setDescription(safeName)
                setNotificationVisibility(
                    DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED,
                )
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    setDestinationInExternalPublicDir(
                        Environment.DIRECTORY_DOWNLOADS,
                        safeName,
                    )
                } else {
                    // API 24-28 写公共下载目录需运行时 WRITE_EXTERNAL_STORAGE 授权，
                    // 为避免额外权限退回应用外部私有目录（文件管理器仍可访问）。
                    setDestinationInExternalFilesDir(
                        activity,
                        Environment.DIRECTORY_DOWNLOADS,
                        safeName,
                    )
                }
                if (!mimeType.isNullOrBlank()) setMimeType(mimeType)
                if (!cookie.isNullOrBlank()) addRequestHeader("Cookie", cookie)
                if (!userAgent.isNullOrBlank()) addRequestHeader("User-Agent", userAgent)
                if (!referer.isNullOrBlank()) addRequestHeader("Referer", referer)
                setAllowedOverMetered(true)
                setAllowedOverRoaming(true)
            }
            activity.getSystemService(DownloadManager::class.java)?.enqueue(request)
            true
        } catch (error: Exception) {
            android.util.Log.e(
                "Download",
                "enqueueDownload failed: ${error.javaClass.simpleName}: ${error.message}",
            )
            false
        }
    }
}
