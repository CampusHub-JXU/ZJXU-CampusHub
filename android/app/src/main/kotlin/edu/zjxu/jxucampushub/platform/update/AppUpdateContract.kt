package edu.zjxu.jxucampushub.platform.update

import android.net.Uri

/**
 * 应用内受管 APK 更新的固定通道协议与输入校验。
 *
 * 与 Dart 侧 `lib/core/update/apk_update_controller.dart` 的
 * `ApkUpdateProtocol` / `ApkUpdatePhase` / `ApkUpdateFailureReason`
 * **lockstep**：通道名、方法名、字段名、上限、phase / reason wire code
 * （即 Dart 枚举名）必须同步修改。
 *
 * 安全不变量：
 * - 只接受可信公开分发仓库（`github.com/FHfanshu/ZJXU-CampusHub`）的
 *   Release 资产路径，绝不接受任意下载镜像 / 主机 / 仓库；
 * - 拒绝 userinfo / 端口 / query / fragment / 编码路径穿越 / 嵌套解码分隔符；
 * - 文件名必须与 URL 解码后的最后一段完全一致，且为安全 `.apk` 名。
 */
internal object AppUpdateContract {
    const val CHANNEL = "edu.zjxu.jxucampushub/app_update"

    const val METHOD_IS_SUPPORTED = "isSupported"
    const val METHOD_START_DOWNLOAD = "startDownload"
    const val METHOD_QUERY_ACTIVE_UPDATE = "queryActiveUpdate"
    const val METHOD_CANCEL_ACTIVE_UPDATE = "cancelActiveUpdate"
    const val METHOD_REQUEST_INSTALL = "requestInstall"
    const val METHOD_OPEN_INSTALL_PERMISSION_SETTINGS = "openInstallPermissionSettings"

    const val TRUSTED_SCHEME = "https"
    const val TRUSTED_HOST = "github.com"
    const val TRUSTED_OWNER = "FHfanshu"
    const val TRUSTED_REPO = "ZJXU-CampusHub"
    const val SEGMENT_RELEASES = "releases"
    const val SEGMENT_DOWNLOAD = "download"

    const val MAX_URL_LENGTH = 2048
    const val MAX_VERSION_LENGTH = 64
    const val MAX_FILE_NAME_LENGTH = 256
    const val MAX_REQUEST_KEY_LENGTH = 320
    const val MAX_ABI_LENGTH = 32

    /** 单个受管 APK 的硬上限，避免恶意 / 异常清单触发超大下载。 */
    const val MAX_APK_BYTES = 512L * 1024 * 1024

    /** 应用外部私有目录下的受管子目录（DownloadManager 目标）。 */
    const val MANAGED_SUBDIR = "updates"

    /** 受管文件名的稳定前缀（便于清理时只认自己的文件；与归属判定同源）。 */
    const val MANAGED_FILE_PREFIX = AppUpdateOwnership.MANAGED_FILE_PREFIX

    const val NOTIFICATION_CHANNEL_ID = "app_update"
    const val NOTIFICATION_CHANNEL_NAME = "更新下载完成"
    const val NOTIFICATION_ID_COMPLETION = 0x7A42

    /** FileProvider authority 后缀；实际 authority = `${applicationId}.app_update_files`。 */
    const val FILE_PROVIDER_SUFFIX = ".app_update_files"

    /** 供原生持久化受管请求 id（下载完成后广播 / PendingIntent 只携带它）。 */
    const val EXTRA_REQUEST_KEY = "app_update_request_key"

    fun fileProviderAuthority(packageName: String): String =
        "$packageName$FILE_PROVIDER_SUFFIX"

    data class CanonicalAsset(
        val url: String,
        val tag: String,
        val fileName: String,
    )

    /**
     * 严格解析可信仓库的规范资产 URL；任何不符合固定形态的输入返回 null。
     *
     * 与 Dart `ApkUpdateUrlPolicy` 等价（原生侧再次校验，绝不信任 Dart 输入）。
     */
    fun parseCanonicalAssetUrl(raw: String?): CanonicalAsset? {
        val value = raw?.trim().orEmpty()
        if (value.isEmpty() || value.length > MAX_URL_LENGTH) return null

        val uri = try {
            Uri.parse(value)
        } catch (_: Exception) {
            return null
        }

        if (uri.scheme?.lowercase() != TRUSTED_SCHEME) return null
        if (!uri.userInfo.isNullOrEmpty()) return null
        if (uri.port != -1) return null
        if (!uri.fragment.isNullOrEmpty()) return null
        if (!uri.query.isNullOrEmpty()) return null
        if (uri.host?.lowercase() != TRUSTED_HOST) return null

        // pathSegments 已解码：`%2e%2e` → `..`、`%2f` → `/` 会被下面拒绝。
        val segments = uri.pathSegments
        if (segments.size != 6) return null
        if (segments[0] != TRUSTED_OWNER) return null
        if (segments[1] != TRUSTED_REPO) return null
        if (segments[2] != SEGMENT_RELEASES || segments[3] != SEGMENT_DOWNLOAD) return null

        val tag = segments[4]
        val fileName = segments[5]
        if (!isSafePathSegment(tag) || !isSafeApkFileName(fileName)) return null

        return CanonicalAsset(url = value, tag = tag, fileName = fileName)
    }

    /** 路径段不得为空 / `.` / `..`，不得含分隔符或控制字符。 */
    fun isSafePathSegment(segment: String): Boolean {
        if (segment.isEmpty() || segment == "." || segment == "..") return false
        if (segment.length > MAX_FILE_NAME_LENGTH) return false
        return segment.none { isUnsafeChar(it) }
    }

    /** 只接受安全 `.apk` 文件名（无分隔符 / 控制字符 / `..` / 转义）。 */
    fun isSafeApkFileName(name: String): Boolean {
        if (name.isEmpty() || name.length > MAX_FILE_NAME_LENGTH) return false
        if (!name.lowercase().endsWith(".apk")) return false
        if (name == "." || name == ".." || name.contains("..")) return false
        return name.none { isUnsafeChar(it) }
    }

    private fun isUnsafeChar(ch: Char): Boolean =
        ch == '/' || ch == '\\' || ch.code < 0x20 || ch.code == 0x7f

    /** 规范化 releaseVersion：去 `v` 前缀与 `+build` 后缀；空串返回空。 */
    fun normalizeVersion(value: String?): String {
        var normalized = value?.trim().orEmpty()
        if (normalized.startsWith("v") || normalized.startsWith("V")) {
            normalized = normalized.substring(1)
        }
        val plus = normalized.indexOf('+')
        if (plus >= 0) normalized = normalized.substring(0, plus)
        return normalized.trim()
    }

    /** SHA-256 规范化：接受裸 64 hex 或 `sha256:` 前缀，统一小写；非法返回 null。 */
    fun normalizeSha256(raw: String?): String? {
        var value = raw?.trim().orEmpty()
        if (value.isEmpty()) return null
        if (value.lowercase().startsWith("sha256:")) {
            value = value.substring("sha256:".length).trim()
        }
        if (value.length != 64) return null
        if (!value.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) return null
        return value.lowercase()
    }
}

/** phase wire code（= Dart `ApkUpdatePhase` 枚举名）。 */
internal object AppUpdatePhase {
    const val IDLE = "idle"
    const val ENQUEUED = "enqueued"
    const val DOWNLOADING = "downloading"
    const val PAUSED = "paused"
    const val VERIFYING = "verifying"
    const val READY_TO_INSTALL = "readyToInstall"
    const val PERMISSION_REQUIRED = "permissionRequired"
    const val INSTALLER_OPENED = "installerOpened"
    const val FAILED = "failed"
    const val CANCELED = "canceled"
    const val UNAVAILABLE = "unavailable"
}

/** reason wire code（= Dart `ApkUpdateFailureReason` 枚举名）。 */
internal object AppUpdateReason {
    const val UNKNOWN = "unknown"
    const val UNSUPPORTED = "unsupported"
    const val UNTRUSTED_ASSET = "untrustedAsset"
    const val NETWORK = "network"
    const val STORAGE_INSUFFICIENT = "storageInsufficient"
    const val VERIFICATION_FAILED = "verificationFailed"
    const val SIGNATURE_MISMATCH = "signatureMismatch"
    const val PACKAGE_MISMATCH = "packageMismatch"
    const val VERSION_NOT_NEWER = "versionNotNewer"
    const val ABI_UNSUPPORTED = "abiUnsupported"
    const val PERMISSION_DENIED = "permissionDenied"
    const val INSTALLER_UNAVAILABLE = "installerUnavailable"
    const val NATIVE_ERROR = "nativeError"
}

/** 通道错误码（不含 PII；Dart 侧 `safeInvoke` 按平台异常降级）。 */
internal object AppUpdateErrors {
    const val INVALID_ARGS = "invalid_args"
    const val UNTRUSTED_ASSET = "untrusted_asset"
    const val STORAGE = "storage_unavailable"
}

internal class AppUpdateException(
    val category: String,
    message: String,
) : Exception(message)
