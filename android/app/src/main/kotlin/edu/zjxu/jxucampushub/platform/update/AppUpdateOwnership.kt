package edu.zjxu.jxucampushub.platform.update

import java.io.File

/**
 * 受管下载「归属判定」的**纯逻辑**（不依赖 Android framework）。
 *
 * 用途：[AppUpdateManager] 用它在系统 DownloadManager 的行集合里，只认
 * **URL 精确匹配 + 本地目标 URI 解析出的规范文件与记录的受管文件完全一致**
 * 的那一行。绝不按 URL 单独匹配——否则会把「通用 WebView 附件下载」到公共
 * 目录的同名 canonical URL 误认成自己的下载（进而让取消 / 删除误伤无关附件）；
 * 也绝不做前缀 / basename 之类的宽松匹配。
 *
 * 抽成纯 Kotlin 的原因：可用桌面 JVM 直接跑可执行用例（真实运行逻辑，而非
 * 结构性正则断言），且不引入任何 Android 依赖 / 新测试框架。
 */
internal object AppUpdateOwnership {

    /** 受管文件名的稳定前缀（与 [AppUpdateContract.MANAGED_FILE_PREFIX] 同源）。 */
    const val MANAGED_FILE_PREFIX = "update_"

    /** DownloadManager 行里我们关心的字段子集。 */
    data class DmRow(
        val id: Long,
        val url: String?,
        val localUri: String?,
    )

    /** 归属扫描结果（可执行、可断言）。 */
    sealed class Scan {
        /** 恰好一行属于本请求。 */
        data class Unique(val downloadId: Long) : Scan()

        /** 多于一行属于本请求：归属不确定，绝不任取第一行。 */
        data class Ambiguous(val matches: Int) : Scan()

        /** 有界扫描完整跑完且没有任何匹配行。 */
        object NotFound : Scan()

        /** 达到行数上限仍未扫完：结论**不权威**，绝不据此重新入队。 */
        object Incomplete : Scan()

        /** 查询失败 / cursor 为空 / 缺少列：无法对账，绝不据此重新入队。 */
        object Unavailable : Scan()
    }

    /**
     * 判定单行是否属于本受管请求：URL 精确相等，且本地目标 URI 解析出的规范路径
     * 与「受管目录 + 记录的受管文件名」的规范路径**完全一致**。
     */
    fun matches(
        row: DmRow,
        expectedUrl: String,
        managedDirPath: String,
        managedFileName: String,
    ): Boolean {
        if (row.url != expectedUrl) return false
        val expected = canonicalManagedPath(managedDirPath, managedFileName) ?: return false
        val actual = resolveFileSchemeLocalPath(row.localUri)?.let { canonicalPath(it) }
            ?: return false
        return actual == expected
    }

    /**
     * 对扫描到的行分类。
     *
     * [capReached] 为 true 表示达到行数上限仍未扫完：此时**不得**断言「不存在」
     * （返回 [Scan.Incomplete]），也**不得**在未扫完时声称唯一。
     */
    fun classify(
        rows: List<DmRow>,
        expectedUrl: String,
        managedDirPath: String,
        managedFileName: String,
        capReached: Boolean,
    ): Scan {
        var matchedId = -1L
        var matches = 0
        for (row in rows) {
            if (matches(row, expectedUrl, managedDirPath, managedFileName)) {
                matches++
                matchedId = row.id
            }
        }
        return when {
            matches > 1 -> Scan.Ambiguous(matches)
            capReached -> Scan.Incomplete
            matches == 1 -> Scan.Unique(matchedId)
            else -> Scan.NotFound
        }
    }

    /** 受管目录 + 受管文件名 → 规范绝对路径；文件名不合法返回 null。 */
    fun canonicalManagedPath(managedDirPath: String, managedFileName: String): String? {
        if (managedDirPath.isEmpty() || !isManagedFileName(managedFileName)) return null
        return canonicalPath(File(managedDirPath, managedFileName).path)
    }

    /** 受管文件名：非空、带前缀、无分隔符 / `..` / 控制字符。 */
    fun isManagedFileName(name: String): Boolean {
        if (name.isEmpty()) return false
        if (!name.startsWith(MANAGED_FILE_PREFIX)) return false
        if (name == "." || name == "..") return false
        if (name.contains("..")) return false
        if (name.contains('/') || name.contains('\\')) return false
        return name.none { it.code < 0x20 || it.code == 0x7f }
    }

    /**
     * 迟到回调是否已过期（requestKey + generation 精确匹配）。
     *
     * 与 [AppUpdateManager] 的安装 / 校验回调守卫同源：取消或新请求会让在途结果作废，
     * 绝不在更新后的记录上回填。`currentRequestKey == null`（记录已被清除）视为过期。
     */
    fun isStale(
        currentRequestKey: String?,
        currentGeneration: Int,
        expectedRequestKey: String,
        expectedGeneration: Int,
    ): Boolean =
        currentRequestKey == null ||
            currentRequestKey != expectedRequestKey ||
            currentGeneration != expectedGeneration

    /** 取消决策（用户取消语义，纯逻辑）。 */
    enum class CancelDisposition {
        /** 无记录：无活动请求，幂等返回 canceled。 */
        IDEMPOTENT_CANCELED,

        /** 权威退役确认：可清除记录并返回 canceled。 */
        CLEARED_CANCELED,

        /** 无法确认退役：保留 exact 记录、不删文件、不谎报 canceled，返回类型化失败。 */
        RETAIN_FAILED,
    }

    /**
     * 取消决策：只有「权威退役已确认」才允许清除；无法确认时**保留**记录以便重试，
     * 绝不静默清除（否则可能丢弃仍在进行的受管请求 / 误伤后续状态）。
     */
    fun cancelDisposition(hasRecord: Boolean, retireConfirmed: Boolean): CancelDisposition =
        when {
            !hasRecord -> CancelDisposition.IDEMPOTENT_CANCELED
            retireConfirmed -> CancelDisposition.CLEARED_CANCELED
            else -> CancelDisposition.RETAIN_FAILED
        }

    /**
     * 解析 DownloadManager 的本地目标 URI：
     * - 只接受 `file:` 方案且**无 authority**（`file:///...`）；`content:` /
     *   带 host 的 `file://host/...` 一律返回 null——在不查 ContentResolver 的
     *   前提下无法确定真实目标 → fail closed，绝不猜，也绝不查任意 content URI；
     * - 解码 `%XX`，拒绝解码后含控制字符或 `..` 段（路径穿越）；
     * - 结果仅用于与自有受管文件做**完全相等**比较，不做前缀 / basename 匹配。
     */
    fun resolveFileSchemeLocalPath(localUri: String?): String? {
        if (localUri.isNullOrEmpty()) return null
        if (!localUri.lowercase().startsWith("file://")) return null
        val rest = localUri.substring("file://".length)
        // `file:///path` → 无 authority；`file://host/path` → 有 authority，拒绝。
        if (!rest.startsWith("/")) return null
        if (rest.contains('?') || rest.contains('#')) return null
        val decoded = percentDecode(rest) ?: return null
        if (decoded.isEmpty()) return null
        for (ch in decoded) {
            if (ch.code < 0x20 || ch.code == 0x7f) return null
        }
        for (segment in decoded.split('/')) {
            if (segment == "..") return null
        }
        return decoded
    }

    private fun canonicalPath(path: String): String? = try {
        File(path).canonicalPath
    } catch (_: Exception) {
        null
    }

    private fun percentDecode(raw: String): String? {
        if (!raw.contains('%')) return raw
        val out = StringBuilder(raw.length)
        var i = 0
        while (i < raw.length) {
            val ch = raw[i]
            if (ch == '%') {
                if (i + 2 >= raw.length) return null
                val hi = hex(raw[i + 1]) ?: return null
                val lo = hex(raw[i + 2]) ?: return null
                out.append(((hi shl 4) or lo).toChar())
                i += 3
            } else {
                out.append(ch)
                i++
            }
        }
        return out.toString()
    }

    private fun hex(ch: Char): Int? = when (ch) {
        in '0'..'9' -> ch - '0'
        in 'a'..'f' -> ch - 'a' + 10
        in 'A'..'F' -> ch - 'A' + 10
        else -> null
    }
}
