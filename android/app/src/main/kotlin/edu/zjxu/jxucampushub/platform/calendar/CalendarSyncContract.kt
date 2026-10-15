package edu.zjxu.jxucampushub.platform.calendar

import edu.zjxu.jxucampushub.platform.ERROR_INVALID_ARGS
import java.util.TimeZone

/**
 * 课表日历同步通道的固定协议常量与输入校验。
 *
 * 通道名与 Dart 侧 `lib/core/calendar/` 的 MethodChannel facade 严格一致；provider
 * 只允许看到随机 opaqueId 与去敏的课程字段，禁止把学号 / 业务键 / 任意 URI 写进
 * `CUSTOM_APP_URI`。
 */
internal object CalendarSyncContract {
    const val CHANNEL = "edu.zjxu.jxucampushub/calendar_sync"

    /** `CUSTOM_APP_URI` 的固定前缀：`jxucampushub://calendar-event/<opaqueId>`。 */
    const val URI_SCHEME = "jxucampushub"
    const val URI_HOST = "calendar-event"
    const val EVENT_URI_PREFIX = "$URI_SCHEME://$URI_HOST/"

    /** 本 App 专属本地日历身份；displayName 仅用于系统日历展示。 */
    const val LOCAL_DISPLAY_NAME = "嘉兴大学课程"
    val LOCAL_CALENDAR_COLOR = 0xFF9E1B32.toInt()

    /** 单批事件上限（调用方约定约 40，这里再硬限一次以免 IPC/transaction 过大）。 */
    const val MAX_BATCH_EVENTS = 100
    const val MAX_QUERY_OPAQUE_IDS = 500
    const val MAX_TITLE_LENGTH = 512
    const val MAX_LOCATION_LENGTH = 1024
    const val MAX_TIMEZONE_LENGTH = 64
    const val MAX_REMINDER_MINUTES = 10080

    /**
     * 只读遗留扫描（`listOwnedEventCalendars`）的边界与去敏上限。
     *
     * 扫描行上限按「非法行同样消耗预算」计，避免大量垃圾行绕过上限；日历数上限
     * 触发即令 `complete=false`（`scanLimit`），绝不把部分结果当「全清」。
     */
    const val MAX_SCAN_MARKER_ROWS = 10_000
    const val MAX_OWNED_CALENDARS = 300
    const val MAX_DISPLAY_NAME_LENGTH = 256

    /**
     * 日历 displayName 去敏：去掉控制字符并把换行 / 制表符折成空格，trim，按
     * [MAX_DISPLAY_NAME_LENGTH] 截断（不切断代理对），空串归一为 null。
     *
     * 结果**只**用于 UI 预览，绝不写日志。
     */
    fun sanitizeDisplayName(raw: String?): String? {
        if (raw == null) return null
        val builder = StringBuilder()
        for (ch in raw) {
            when {
                ch == '\n' || ch == '\r' || ch == '\t' -> builder.append(' ')
                ch.code < 0x20 || ch.code == 0x7f -> Unit
                else -> builder.append(ch)
            }
        }
        val trimmed = builder.toString().trim()
        if (trimmed.isEmpty()) return null
        if (trimmed.length <= MAX_DISPLAY_NAME_LENGTH) return trimmed
        var cut = MAX_DISPLAY_NAME_LENGTH
        if (Character.isHighSurrogate(trimmed[cut - 1])) cut -= 1
        return trimmed.substring(0, cut)
    }

    // 只接受「规范 UUID」或「纯 hex 16–64 位」两种等价形态；其余一律拒绝，
    // 保证 provider 里不出现任意 URI / 学号 / 路径片段。
    private val UUID_REGEX = Regex(
        "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
    )
    private val HEX_REGEX = Regex("^[0-9a-fA-F]{16,64}$")

    fun isValidOpaqueId(value: String): Boolean =
        UUID_REGEX.matches(value) || HEX_REGEX.matches(value)

    fun eventUri(opaqueId: String): String = "$EVENT_URI_PREFIX$opaqueId"

    /** 仅当 URI 完全符合固定前缀且余下部分通过严检时才返回 opaqueId。 */
    fun opaqueIdFromUri(uri: String?): String? {
        if (uri == null || !uri.startsWith(EVENT_URI_PREFIX)) return null
        val id = uri.substring(EVENT_URI_PREFIX.length)
        return id.takeIf { isValidOpaqueId(it) }
    }

    /** 时区必须是可识别的 IANA ID；未知 ID 会回退 GMT，这里拒绝这种静默回退。 */
    fun isValidTimeZone(timeZone: String): Boolean {
        if (timeZone.isBlank() || timeZone.length > MAX_TIMEZONE_LENGTH) return false
        val zone = TimeZone.getTimeZone(timeZone)
        if (zone.id == "GMT" && timeZone != "GMT" && timeZone != "UTC") return false
        return true
    }
}

/** 通道错误类别；全部不携带 PII，Dart 侧按类别降级。 */
internal object CalendarSyncErrors {
    const val PERMISSION_DENIED = "permission_denied"
    const val INVALID_ARGS = ERROR_INVALID_ARGS
    const val PROVIDER_UNAVAILABLE = "provider_unavailable"
    const val CALENDAR_UNAVAILABLE = "calendar_unavailable"
    const val OWNERSHIP_CONFLICT = "ownership_conflict"
    const val BATCH_FAILED = "batch_failed"
    const val UNSUPPORTED = "unsupported"
    const val REQUESTS_IN_FLIGHT = "requests_in_flight"
}

internal class CalendarSyncException(
    val category: String,
    message: String,
) : Exception(message)

/**
 * `listOwnedEventCalendars` 的完整性原因（固定 wire code，Dart 侧按值解析）。
 *
 * 这是**只读扫描结果**的原因码，不是写入失败类别；语义与既有
 * [CalendarSyncErrors] 对应处见各自注释。四值冻结，新增须同步 Dart 与文档。
 */
internal object CalendarOwnedScanReasons {
    /** provider 不可用 / 扫描整体失败（映射既有 `provider_unavailable`）。 */
    const val UNAVAILABLE = "unavailable"

    /** 日历权限被拒 / 扫描中途撤销（映射既有 `permission_denied`）。 */
    const val PERMISSION_DENIED = "permissionDenied"

    /** 达到行数 / 日历数上限：结论不完整（无既有对应）。 */
    const val SCAN_LIMIT = "scanLimit"

    /** 命中的自有日历元数据缺失 / 查询失败：`writable` 未知（映射既有 `calendar_unavailable`）。 */
    const val CALENDAR_UNAVAILABLE = "calendarUnavailable"
}

/** 经过校验的绝对非重复事件输入（native 内部使用）。 */
internal data class CalendarEventInput(
    val opaqueId: String,
    val title: String,
    val location: String,
    val startMillis: Long,
    val endMillis: Long,
    val reminderMinutes: Int,
    val timeZone: String,
)

internal fun parseEventInput(raw: Map<*, *>): CalendarEventInput {
    val opaqueId = (raw["opaqueId"] as? String)?.trim().orEmpty()
    if (!CalendarSyncContract.isValidOpaqueId(opaqueId)) {
        throw CalendarSyncException(CalendarSyncErrors.INVALID_ARGS, "invalid opaqueId")
    }

    val title = (raw["title"] as? String)?.trim().orEmpty()
    if (title.isEmpty() || title.length > CalendarSyncContract.MAX_TITLE_LENGTH) {
        throw CalendarSyncException(CalendarSyncErrors.INVALID_ARGS, "invalid title")
    }

    val location = (raw["location"] as? String)?.trim().orEmpty()
    if (location.length > CalendarSyncContract.MAX_LOCATION_LENGTH) {
        throw CalendarSyncException(CalendarSyncErrors.INVALID_ARGS, "invalid location")
    }

    val startMillis = (raw["startMillis"] as? Number)?.toLong()
        ?: throw CalendarSyncException(CalendarSyncErrors.INVALID_ARGS, "invalid startMillis")
    val endMillis = (raw["endMillis"] as? Number)?.toLong()
        ?: throw CalendarSyncException(CalendarSyncErrors.INVALID_ARGS, "invalid endMillis")
    if (startMillis <= 0L || endMillis <= startMillis) {
        throw CalendarSyncException(CalendarSyncErrors.INVALID_ARGS, "invalid event interval")
    }

    val reminderMinutes = (raw["reminderMinutes"] as? Number)?.toInt()
        ?: throw CalendarSyncException(CalendarSyncErrors.INVALID_ARGS, "invalid reminderMinutes")
    if (reminderMinutes < 0 || reminderMinutes > CalendarSyncContract.MAX_REMINDER_MINUTES) {
        throw CalendarSyncException(CalendarSyncErrors.INVALID_ARGS, "invalid reminderMinutes")
    }

    val timeZone = (raw["timeZone"] as? String)?.trim().orEmpty()
    if (!CalendarSyncContract.isValidTimeZone(timeZone)) {
        throw CalendarSyncException(CalendarSyncErrors.INVALID_ARGS, "invalid timeZone")
    }

    return CalendarEventInput(
        opaqueId = opaqueId,
        title = title,
        location = location,
        startMillis = startMillis,
        endMillis = endMillis,
        reminderMinutes = reminderMinutes,
        timeZone = timeZone,
    )
}
