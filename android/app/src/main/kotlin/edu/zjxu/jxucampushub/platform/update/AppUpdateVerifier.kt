package edu.zjxu.jxucampushub.platform.update

import android.content.Context
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.os.Build
import java.io.File
import java.security.MessageDigest
import java.util.zip.ZipFile

/**
 * 受管 APK 的归档 / 包名 / 签名 / 版本 / ABI 校验（全部在后台线程执行）。
 *
 * 安全不变量（安装前强制）：
 * - `archive.packageName` 必须**精确等于** `context.packageName`（release 与
 *   `.dev` debug 因此天然互斥，绝不接受另一形态）；
 * - 归档签名集合必须与**已安装**应用签名集合一致（签名轮换不确定时 fail closed）；
 * - 归档 `versionCode` 必须**严格大于**已安装 versionCode（绝不从 semver 推导）；
 * - ABI 必须与本机 `Build.SUPPORTED_ABIS` 兼容；`minSdk` 不得高于当前 SDK；
 * - 归档 sha256 仅在来源提供摘要时校验；未提供时**如实标注**非摘要校验，
 *   但包名 / 签名 / 版本 / ABI 校验始终强制。
 */
internal object AppUpdateVerifier {
    internal sealed class Outcome {
        data class Verified(
            val versionName: String?,
            val digestChecked: Boolean,
        ) : Outcome()

        data class Failed(
            val reason: String,
            val message: String,
        ) : Outcome()
    }

    fun verify(
        context: Context,
        file: File,
        expectedSizeBytes: Long,
        expectedSha256: String?,
        expectedVersion: String?,
    ): Outcome {
        if (!file.isFile) {
            return Outcome.Failed(AppUpdateReason.VERIFICATION_FAILED, "managed file missing")
        }
        val length = file.length()
        if (length <= 0L) {
            return Outcome.Failed(AppUpdateReason.VERIFICATION_FAILED, "empty archive")
        }
        if (length > AppUpdateContract.MAX_APK_BYTES) {
            return Outcome.Failed(AppUpdateReason.STORAGE_INSUFFICIENT, "archive too large")
        }
        if (expectedSizeBytes > 0L && length != expectedSizeBytes) {
            return Outcome.Failed(AppUpdateReason.VERIFICATION_FAILED, "size mismatch")
        }

        val digestChecked: Boolean
        if (!expectedSha256.isNullOrEmpty()) {
            val actual = sha256(file)
                ?: return Outcome.Failed(AppUpdateReason.VERIFICATION_FAILED, "digest read failed")
            if (!actual.equals(expectedSha256, ignoreCase = true)) {
                return Outcome.Failed(AppUpdateReason.VERIFICATION_FAILED, "digest mismatch")
            }
            digestChecked = true
        } else {
            digestChecked = false
        }

        val pm = context.packageManager
        val flags = PackageManager.GET_META_DATA or signatureFlags()
        val archive: PackageInfo = try {
            pm.getPackageArchiveInfo(file.absolutePath, flags)
                ?: return Outcome.Failed(
                    AppUpdateReason.VERIFICATION_FAILED,
                    "unparseable archive",
                )
        } catch (_: Exception) {
            return Outcome.Failed(AppUpdateReason.VERIFICATION_FAILED, "unparseable archive")
        }

        val archivePackage = archive.packageName
        if (archivePackage.isNullOrEmpty() ||
            archivePackage != context.packageName
        ) {
            return Outcome.Failed(AppUpdateReason.PACKAGE_MISMATCH, "package name mismatch")
        }

        val archiveCode = versionCode(archive)
        val installedCode = installedVersionCode(context)
        if (installedCode != null && archiveCode <= installedCode) {
            return Outcome.Failed(AppUpdateReason.VERSION_NOT_NEWER, "not newer than installed")
        }

        val archiveCerts = certificates(archive)
        val installedCerts = installedCertificates(context)
        if (archiveCerts == null || installedCerts == null) {
            return Outcome.Failed(AppUpdateReason.SIGNATURE_MISMATCH, "signature unavailable")
        }
        if (archiveCerts != installedCerts) {
            return Outcome.Failed(AppUpdateReason.SIGNATURE_MISMATCH, "signer mismatch")
        }

        val archiveMinSdk = archive.applicationInfo?.minSdkVersion ?: 1
        if (archiveMinSdk > Build.VERSION.SDK_INT) {
            return Outcome.Failed(AppUpdateReason.UNSUPPORTED, "minSdk too high")
        }

        if (!isAbiCompatible(file)) {
            return Outcome.Failed(AppUpdateReason.ABI_UNSUPPORTED, "no compatible abi")
        }

        val archiveVersionName = archive.versionName
        val normalizedExpected = AppUpdateContract.normalizeVersion(expectedVersion)
        val normalizedArchive = AppUpdateContract.normalizeVersion(archiveVersionName)
        if (normalizedExpected.isNotEmpty() &&
            normalizedArchive.isNotEmpty() &&
            normalizedExpected != normalizedArchive
        ) {
            // releaseVersion 由清单提供；归一化后不一致视为篡改 / 错配，fail closed。
            return Outcome.Failed(AppUpdateReason.VERIFICATION_FAILED, "version name mismatch")
        }

        return Outcome.Verified(
            versionName = archiveVersionName,
            digestChecked = digestChecked,
        )
    }

    /** 流式 SHA-256（64 KiB 缓冲，绝不在主线程读整包）。 */
    fun sha256(file: File): String? {
        return try {
            val digest = MessageDigest.getInstance("SHA-256")
            file.inputStream().use { input ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    val read = input.read(buffer)
                    if (read <= 0) break
                    digest.update(buffer, 0, read)
                }
            }
            digest.digest().joinToString("") { "%02x".format(it) }
        } catch (_: Exception) {
            null
        }
    }

    /** APK 内是否含与本机 ABI 兼容的原生库；无原生库视为 ABI 无关。 */
    fun isAbiCompatible(file: File): Boolean {
        val abis = mutableSetOf<String>()
        try {
            ZipFile(file).use { zip ->
                val entries = zip.entries()
                while (entries.hasMoreElements()) {
                    val name = entries.nextElement().name
                    if (!name.startsWith("lib/")) continue
                    val parts = name.split('/')
                    if (parts.size >= 2 && parts[1].isNotEmpty()) abis.add(parts[1])
                }
            }
        } catch (_: Exception) {
            return false
        }
        if (abis.isEmpty()) return true
        return abis.any { it in Build.SUPPORTED_ABIS }
    }

    private fun signatureFlags(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            @Suppress("DEPRECATION")
            PackageManager.GET_SIGNATURES
        }

    private fun versionCode(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            info.versionCode.toLong()
        }

    private fun installedVersionCode(context: Context): Long? = try {
        val info = context.packageManager.getPackageInfo(
            context.packageName,
            signatureFlags(),
        )
        versionCode(info)
    } catch (_: Exception) {
        null
    }

    private fun installedCertificates(context: Context): Set<String>? = try {
        certificates(
            context.packageManager.getPackageInfo(context.packageName, signatureFlags()),
        )
    } catch (_: Exception) {
        null
    }

    private fun certificates(info: PackageInfo): Set<String>? {
        val signatures: Array<Signature> = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val signingInfo = info.signingInfo ?: return null
            signingInfo.apkContentsSigners
        } else {
            @Suppress("DEPRECATION")
            info.signatures ?: return null
        }
        if (signatures.isEmpty()) return null
        return signatures.map { it.toByteArray().toHexString() }.toSet()
    }

    private fun ByteArray.toHexString(): String =
        joinToString("") { "%02x".format(it) }
}
