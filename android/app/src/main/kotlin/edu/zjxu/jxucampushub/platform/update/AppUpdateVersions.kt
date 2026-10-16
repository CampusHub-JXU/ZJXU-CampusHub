package edu.zjxu.jxucampushub.platform.update

/** 与 Dart AppRelease 共用版本表；非数字版本按规范化字符串排序，不猜 semver。 */
internal object AppUpdateVersions {
    fun normalizeVersion(value: String): String {
        var normalized = value.trim()
        if (normalized.startsWith("v") || normalized.startsWith("V")) normalized = normalized.substring(1)
        return normalized.substringBefore('+').trim()
    }

    fun tryParseVersionSegments(value: String): List<Long>? {
        if (value.isEmpty()) return null
        return value.split('.').map { part ->
            val text = part.trim()
            // Dart int.tryParse 接受带符号十六进制；有溢出时同样退回字符串比较。
            val negative = text.startsWith("-")
            val unsigned = text.removePrefix("-").removePrefix("+")
            val parsed = if (unsigned.startsWith("0x", true)) {
                unsigned.substring(2).toLongOrNull(16)?.let { if (negative) -it else it }
            } else text.toLongOrNull()
            parsed ?: return null
        }
    }

    fun isVersionNewer(candidate: String, currentVersion: String): Boolean {
        val latest = normalizeVersion(candidate)
        val current = normalizeVersion(currentVersion)
        val a = tryParseVersionSegments(latest)
        val b = tryParseVersionSegments(current)
        if (a == null || b == null) return latest.compareTo(current) > 0
        for (i in 0 until maxOf(a.size, b.size)) {
            val x = a.getOrElse(i) { 0L }
            val y = b.getOrElse(i) { 0L }
            if (x != y) return x > y
        }
        return false
    }
}
