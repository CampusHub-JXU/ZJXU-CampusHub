package edu.zjxu.jxucampushub.widget

import edu.zjxu.jxucampushub.widget.CampusWidgetTimeLogic.Course
import edu.zjxu.jxucampushub.widget.CampusWidgetTimeLogic.Day
import edu.zjxu.jxucampushub.widget.CampusWidgetTimeLogic.Exam
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.OffsetDateTime
import java.time.ZoneId
import org.json.JSONArray
import org.json.JSONObject

/**
 * Dart 推送的快照 v2（见 docs/desktop-widget-v2.md §2）的容错解析。
 *
 * 字段缺失 / 类型不符一律按空处理；JSON null 与字面量 "null" 都视为空串
 * （`optString` 会把 JSON null 读成 "null"，屏幕上会直接显示出来）。
 * 时间是无时区后缀的本地时间字符串，按设备本地时间解析。
 */
internal class CampusWidgetSnapshot(
    /** 0 = 缺失（旧版快照）；渲染层据此显示「打开 App 更新组件」。 */
    val schemaVersion: Int,
    val generatedAt: LocalDateTime?,
    /** notLoggedIn / noCache / beforeSemester / afterSemester；空串 = 正常。 */
    val emptyState: String,
    val emptyStateText: String,
    val weekLabel: String,
    val days: List<Day>,
    val exams: List<Exam>,
    val campusCard: Asset,
    val electricity: Asset,
    val unreadNotices: Int,
    val accentLight: Int?,
    val accentDark: Int?,
) {
    class Asset(val hasData: Boolean, val value: String, val low: Boolean) {
        val shown: Boolean get() = hasData && value.isNotBlank()
    }

    val isCurrentSchema: Boolean get() = schemaVersion >= SUPPORTED_SCHEMA

    companion object {
        const val SUPPORTED_SCHEMA = 2

        fun parse(json: JSONObject): CampusWidgetSnapshot {
            val card = json.optJSONObject("campusCard")
            val electricity = json.optJSONObject("electricity")
            val notices = json.optJSONObject("notices")
            val theme = json.optJSONObject("theme")
            return CampusWidgetSnapshot(
                schemaVersion = if (json.isNull("schemaVersion")) 0 else json.optInt("schemaVersion", 0),
                generatedAt = parseDateTime(json.text("generatedAt")),
                emptyState = json.text("emptyState"),
                emptyStateText = json.text("emptyStateText"),
                weekLabel = json.text("weekLabel"),
                days = parseDays(json.optJSONArray("days")),
                exams = parseExams(json.optJSONArray("exams")),
                campusCard = Asset(
                    hasData = card?.optBoolean("hasData", false) == true,
                    value = card?.text("balance").orEmpty(),
                    low = card?.optBoolean("low", false) == true,
                ),
                electricity = Asset(
                    hasData = electricity?.optBoolean("hasData", false) == true,
                    value = electricity?.text("value").orEmpty(),
                    low = electricity?.optBoolean("low", false) == true,
                ),
                unreadNotices = notices?.optInt("unreadCount", 0) ?: 0,
                accentLight = parseHexColor(theme?.text("accentLight").orEmpty()),
                accentDark = parseHexColor(theme?.text("accentDark").orEmpty()),
            )
        }

        private fun parseDays(array: JSONArray?): List<Day> {
            if (array == null) return emptyList()
            val days = ArrayList<Day>(array.length())
            for (i in 0 until array.length()) {
                val obj = array.optJSONObject(i) ?: continue
                val date = try {
                    LocalDate.parse(obj.text("date"))
                } catch (_: Exception) {
                    continue
                }
                days += Day(
                    date = date,
                    weekLabel = obj.text("weekLabel"),
                    holidayName = obj.text("holidayName"),
                    courses = parseCourses(obj.optJSONArray("courses")),
                )
            }
            days.sortBy { it.date }
            return days
        }

        private fun parseCourses(array: JSONArray?): List<Course> {
            if (array == null) return emptyList()
            val courses = ArrayList<Course>(array.length())
            for (i in 0 until array.length()) {
                val obj = array.optJSONObject(i) ?: continue
                val name = obj.text("courseName")
                val start = parseDateTime(obj.text("startAt")) ?: continue
                val end = parseDateTime(obj.text("endAt")) ?: continue
                if (name.isBlank() || !end.isAfter(start)) continue
                courses += Course(
                    start = start,
                    end = end,
                    timeText = obj.text("timeText"),
                    lessonText = obj.text("lessonText"),
                    name = name,
                    location = obj.text("locationText"),
                )
            }
            courses.sortBy { it.start }
            return courses
        }

        private fun parseExams(array: JSONArray?): List<Exam> {
            if (array == null) return emptyList()
            val exams = ArrayList<Exam>(array.length())
            for (i in 0 until array.length()) {
                val obj = array.optJSONObject(i) ?: continue
                val name = obj.text("courseName")
                val start = parseDateTime(obj.text("startAt")) ?: continue
                if (name.isBlank()) continue
                val end = parseDateTime(obj.text("endAt"))?.takeIf { it.isAfter(start) }
                exams += Exam(
                    start = start,
                    end = end,
                    timeText = obj.text("timeText"),
                    name = name,
                    location = obj.text("locationText"),
                )
            }
            exams.sortBy { it.start }
            return exams
        }

        /**
         * 本地时间字符串（`2026-10-16T08:00:00`）→ [LocalDateTime]。
         * 万一带了时区后缀，换算成设备默认时区的本地时间；解析失败返回 null。
         */
        fun parseDateTime(text: String): LocalDateTime? {
            if (text.isBlank()) return null
            return try {
                LocalDateTime.parse(text)
            } catch (_: Exception) {
                try {
                    OffsetDateTime.parse(text).atZoneSameInstant(ZoneId.systemDefault())
                        .toLocalDateTime()
                } catch (_: Exception) {
                    null
                }
            }
        }

        /** `#RRGGBB` → 不透明 ARGB；格式不符返回 null。 */
        fun parseHexColor(text: String): Int? {
            val match = HEX_COLOR.matchEntire(text.trim()) ?: return null
            return (0xFF000000L or match.groupValues[1].toLong(16)).toInt()
        }

        private val HEX_COLOR = Regex("^#([0-9a-fA-F]{6})$")

        /** JSON null / 缺失一律视为空串，字面量 "null" 同样视为空。 */
        fun JSONObject.text(key: String): String {
            if (isNull(key)) return ""
            val value = optString(key)
            return if (value == "null") "" else value
        }
    }
}
