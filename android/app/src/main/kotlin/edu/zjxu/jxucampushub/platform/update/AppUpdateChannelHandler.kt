package edu.zjxu.jxucampushub.platform.update

import android.app.Activity
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 仅主引擎注册；串行后台 TaskQueue 承载存储/DM 查询，Activity 操作回主线程。
 * 输入只含受限资产身份及候选源，绝不接受任意 id/本地路径；异步回复最多一次。
 */
class AppUpdateChannelHandler internal constructor(
    private val activity: Activity,
    private val manager: AppUpdateManager,
) {
    private val mainHandler = Handler(Looper.getMainLooper())

    fun register(messenger: BinaryMessenger) {
        val taskQueue = messenger.makeBackgroundTaskQueue(
            BinaryMessenger.TaskQueueOptions().setIsSerial(true),
        )
        MethodChannel(messenger, AppUpdateContract.CHANNEL, StandardMethodCodec.INSTANCE, taskQueue)
            .setMethodCallHandler { call, rawResult ->
                val result = OnceResult(rawResult)
                guarded(result) {
                    when (call.method) {
                        AppUpdateContract.METHOD_IS_SUPPORTED -> result.success(manager.isSupported())
                        AppUpdateContract.METHOD_START_DOWNLOAD -> result.success(manager.startDownload(parseStart(call)))
                        AppUpdateContract.METHOD_QUERY_ACTIVE_UPDATE -> result.success(manager.queryActive())
                        AppUpdateContract.METHOD_CANCEL_ACTIVE_UPDATE -> result.success(manager.cancelActive())
                        AppUpdateContract.METHOD_SWITCH_SOURCE -> result.success(manager.switchSource(requiredString(call, "reason"),
                            (call.argument<Any?>("attempt") as? Number)?.toInt() ?: invalid()))
                        AppUpdateContract.METHOD_REQUEST_INSTALL -> {
                            val tag = optionalString(call, "expectedReleaseTag")
                            mainHandler.post {
                                guarded(result) { manager.requestInstall(activity, tag) { result.success(it) } }
                            }
                        }
                        AppUpdateContract.METHOD_OPEN_INSTALL_PERMISSION_SETTINGS -> mainHandler.post {
                            guarded(result) { result.success(manager.openInstallPermissionSettings(activity)) }
                        }
                        else -> result.notImplemented()
                    }
                }
            }
    }

    private fun parseStart(call: MethodCall): StartParams {
        val raw = call.argument<List<*>>("sources") ?: invalid()
        val sources = raw.map { entry ->
            val map = entry as? Map<*, *> ?: invalid()
            SourceUrl(map["source"] as? String ?: invalid(), map["url"] as? String ?: invalid())
        }
        val size = call.argument<Any?>("sizeBytes")
        if (size != null && size !is Int && size !is Long) invalid()
        return StartParams(
            version = requiredString(call, "version"), releaseTag = requiredString(call, "releaseTag"),
            fileName = requiredString(call, "fileName"), requestKey = requiredString(call, "requestKey"),
            mode = requiredString(call, "mode"), sources = sources,
            sizeBytes = (size as? Number)?.toLong() ?: 0L, sha256 = optionalString(call, "sha256"),
            abi = optionalString(call, "abi"), unavailablePreferred = optionalString(call, "unavailablePreferred"),
        )
    }
    private fun requiredString(call: MethodCall, name: String): String = optionalString(call, name) ?: invalid()
    private fun optionalString(call: MethodCall, name: String): String? {
        val v = call.argument<Any?>(name) ?: return null
        return v as? String ?: invalid()
    }
    private fun invalid(): Nothing = throw AppUpdateException(AppUpdateErrors.INVALID_ARGS, "invalid update request")
    private fun guarded(result: MethodChannel.Result, action: () -> Unit) {
        try { action() } catch (e: AppUpdateException) {
            result.error(e.category, e.message, null)
        } catch (_: Exception) { result.error(AppUpdateErrors.INVALID_ARGS, "invalid update request", null) }
    }

    /** 与 CalendarSyncChannelHandler 同源的单回复守卫。 */
    private class OnceResult(private val delegate: MethodChannel.Result) : MethodChannel.Result {
        private val completed = AtomicBoolean(false)
        override fun success(result: Any?) { if (completed.compareAndSet(false, true)) delegate.success(result) }
        override fun error(code: String, message: String?, details: Any?) {
            if (completed.compareAndSet(false, true)) delegate.error(code, message, details)
        }
        override fun notImplemented() { if (completed.compareAndSet(false, true)) delegate.notImplemented() }
    }
}
