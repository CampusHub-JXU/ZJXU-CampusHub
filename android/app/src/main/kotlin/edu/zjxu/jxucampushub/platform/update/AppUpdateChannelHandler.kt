package edu.zjxu.jxucampushub.platform.update

import android.app.Activity
import edu.zjxu.jxucampushub.platform.ERROR_INVALID_ARGS
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 应用内受管更新通道（仅前台，主 Activity 注册）。
 *
 * 固定协议 6 方法：
 * `isSupported` / `startDownload` / `queryActiveUpdate` / `cancelActiveUpdate` /
 * `requestInstall` / `openInstallPermissionSettings`。
 *
 * - 只接受协议字段（版本 / 规范资产 URL / 文件名 / requestKey / 可选 assetId /
 *   sizeBytes / sha256 / abi）；**绝不**接受任意本地路径 / 下载 id / URI；
 * - URL / 文件名 / 上限在 [AppUpdateManager] 原生再次校验（不信任 Dart）；
 * - 业务失败返回安全错误类别（不含 PII），Dart 侧 `safeInvoke` 降级；
 * - 不在 WorkManager 后台引擎注册。
 */
class AppUpdateChannelHandler internal constructor(
    private val activity: Activity,
    private val manager: AppUpdateManager,
) {
    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, AppUpdateContract.CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    AppUpdateContract.METHOD_IS_SUPPORTED ->
                        result.success(manager.isSupported())

                    AppUpdateContract.METHOD_START_DOWNLOAD -> handleStart(call, result)

                    AppUpdateContract.METHOD_QUERY_ACTIVE_UPDATE ->
                        result.success(manager.queryActive())

                    AppUpdateContract.METHOD_CANCEL_ACTIVE_UPDATE ->
                        result.success(manager.cancelActive())

                    AppUpdateContract.METHOD_REQUEST_INSTALL ->
                        manager.requestInstall(activity) { launched ->
                            result.success(launched)
                        }

                    AppUpdateContract.METHOD_OPEN_INSTALL_PERMISSION_SETTINGS ->
                        result.success(manager.openInstallPermissionSettings(activity))

                    else -> result.notImplemented()
                }
            }
    }

    private fun handleStart(call: MethodCall, result: MethodChannel.Result) {
        try {
            val params = AppUpdateManager.StartParams(
                version = call.argument<String>("version"),
                url = call.argument<String>("url"),
                fileName = call.argument<String>("fileName"),
                requestKey = call.argument<String>("requestKey"),
                sizeBytes = call.argument<Number>("sizeBytes")?.toLong(),
                sha256 = call.argument<String>("sha256"),
                abi = call.argument<String>("abi"),
            )
            result.success(manager.startDownload(params))
        } catch (error: AppUpdateException) {
            result.error(error.category, error.message, null)
        } catch (_: Exception) {
            result.error(ERROR_INVALID_ARGS, "invalid update request", null)
        }
    }
}
