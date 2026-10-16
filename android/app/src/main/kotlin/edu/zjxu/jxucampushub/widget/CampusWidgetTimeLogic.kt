package edu.zjxu.jxucampushub.widget

import java.time.LocalDate
import java.time.LocalDateTime
import java.time.temporal.ChronoUnit

/**
 * 桌面组件的纯时间逻辑：当前课 / 下一节 / 明日回退 / 下一个重渲边界 / 考试倒计时。
 *
 * **不依赖任何 Android 类**（只用 java.time），可在宿主 JVM 上直接单测
 * （`tools/widget_native_tests/run.py`）。所有时间都是「设备本地时间」，
 * 由调用方用设备默认时区解析 / 换算；本对象只比较 [LocalDateTime]。
 */
internal object CampusWidgetTimeLogic {
    /** 考试没有结束时间时按开始后 2 小时视为结束。 */
    private const val DEFAULT_EXAM_HOURS = 2L

    class Course(
        val start: LocalDateTime,
        val end: LocalDateTime,
        val timeText: String,
        val lessonText: String,
        val name: String,
        val location: String,
    )

    class Day(
        val date: LocalDate,
        val weekLabel: String,
        val holidayName: String,
        /** 已按 [Course.start] 升序。 */
        val courses: List<Course>,
    )

    class Exam(
        val start: LocalDateTime,
        val end: LocalDateTime?,
        val timeText: String,
        val name: String,
        val location: String,
    ) {
        val effectiveEnd: LocalDateTime get() = end ?: start.plusHours(DEFAULT_EXAM_HOURS)
    }

    /** 进行中的课，或（没有进行中时）此刻之后最早开始的一节课。 */
    class Hero(val course: Course, val ongoing: Boolean) {
        val date: LocalDate get() = course.start.toLocalDate()
    }

    enum class MediumKind {
        /** 今天还有未结束的课。 */
        TODAY,

        /** 今天有课但都已结束。 */
        OVER,

        /** 今天本来就没课（含节假日 / 停课）。 */
        NONE,

        /** 快照里没有今天（快照太旧）：无法判断。 */
        UNKNOWN,
    }

    class MediumPlan(val kind: MediumKind, val today: Day?)

    /** 课程列表里的一项：日期小标题或一节课（二选一）。 */
    class FlowItem(val labelDate: LocalDate?, val course: Course?)

    // ------------------------------------------------------------------ hero

    fun hero(days: List<Day>, now: LocalDateTime): Hero? {
        var upcoming: Course? = null
        for (day in days) {
            for (course in day.courses) {
                if (!now.isBefore(course.start) && now.isBefore(course.end)) {
                    return Hero(course, ongoing = true)
                }
                if (course.start.isAfter(now) &&
                    (upcoming == null || course.start.isBefore(upcoming.start))
                ) {
                    upcoming = course
                }
            }
        }
        return upcoming?.let { Hero(it, ongoing = false) }
    }

    /** Hero 同一天、排在它之后且尚未结束的课，最多 [limit] 条。 */
    fun coursesAfterHero(
        days: List<Day>,
        hero: Hero,
        now: LocalDateTime,
        limit: Int,
    ): List<Course> {
        val day = days.firstOrNull { it.date == hero.date } ?: return emptyList()
        return day.courses
            .filter { it !== hero.course && it.start.isAfter(hero.course.start) && it.end.isAfter(now) }
            .take(limit)
    }

    fun progressPercent(course: Course, now: LocalDateTime): Int {
        val total = ChronoUnit.SECONDS.between(course.start, course.end)
        if (total <= 0L) return 0
        val elapsed = ChronoUnit.SECONDS.between(course.start, now)
        return (elapsed * 100L / total).coerceIn(0L, 100L).toInt()
    }

    // ---------------------------------------------------------------- medium

    fun mediumPlan(days: List<Day>, now: LocalDateTime): MediumPlan {
        val todayDay = days.firstOrNull { it.date == now.toLocalDate() }
            ?: return MediumPlan(MediumKind.UNKNOWN, null)
        val kind = when {
            todayDay.courses.any { it.end.isAfter(now) } -> MediumKind.TODAY
            todayDay.courses.isNotEmpty() -> MediumKind.OVER
            else -> MediumKind.NONE
        }
        return MediumPlan(kind, todayDay)
    }

    // ------------------------------------------------------------------ flow

    /** 课程行估算高度（dp，含行间距）。 */
    const val COURSE_ROW_DP = 30

    /** 日期小标题估算高度（dp）。 */
    const val LABEL_ROW_DP = 26

    /**
     * 从此刻起依次排出各天尚未结束的课：每个有课的日子一组，组前放日期小标题，
     * 但 [unlabeledDate] 那一天（已在组件顶部交代过的日子）不放标题；[skip] 那节课不重复列出。
     * 没课的日子直接跳过。
     */
    fun flow(
        days: List<Day>,
        now: LocalDateTime,
        skip: Course?,
        unlabeledDate: LocalDate?,
    ): List<FlowItem> {
        val items = ArrayList<FlowItem>()
        for (day in days.sortedBy { it.date }) {
            if (day.date.isBefore(now.toLocalDate())) continue
            val courses = day.courses.filter { it !== skip && it.end.isAfter(now) }
            if (courses.isEmpty()) continue
            if (day.date != unlabeledDate) items += FlowItem(day.date, null)
            for (course in courses) items += FlowItem(null, course)
        }
        return items
    }

    /** 按 [budgetDp] 与 [maxSlots] 截断；末尾孤立的日期标题丢弃。 */
    fun fit(items: List<FlowItem>, budgetDp: Int, maxSlots: Int): List<FlowItem> {
        val fitted = ArrayList<FlowItem>()
        var used = 0
        for (item in items) {
            val cost = if (item.course != null) COURSE_ROW_DP else LABEL_ROW_DP
            if (fitted.size >= maxSlots || used + cost > budgetDp) break
            fitted += item
            used += cost
        }
        while (fitted.isNotEmpty() && fitted.last().course == null) fitted.removeAt(fitted.size - 1)
        return fitted
    }

    /** 「周一 10/19」「明天 10/17」。 */
    fun dateLabel(today: LocalDate, date: LocalDate): String =
        "${dayLabel(today, date)} ${date.monthValue}/${date.dayOfMonth}"

    // ------------------------------------------------------------------ exam

    /** 第一场尚未结束的考试（[exams] 已按开始时间升序）。 */
    fun nearestExam(exams: List<Exam>, now: LocalDateTime): Exam? =
        exams.firstOrNull { it.effectiveEnd.isAfter(now) }

    /** 距考试日的自然日天数；考试当天为 0，不为负。 */
    fun examCountdownDays(exam: Exam, now: LocalDateTime): Int {
        val days = ChronoUnit.DAYS.between(now.toLocalDate(), exam.start.toLocalDate())
        return days.coerceAtLeast(0L).toInt()
    }

    // -------------------------------------------------------------- boundary

    /**
     * 下一个需要重渲的时刻（严格晚于 [now]）：
     * min(所有课程 start / end，考试 start / effectiveEnd，下一个本地午夜)。
     */
    fun nextBoundary(
        days: List<Day>,
        exams: List<Exam>,
        now: LocalDateTime,
    ): LocalDateTime {
        var best = now.toLocalDate().plusDays(1).atStartOfDay()
        fun consider(t: LocalDateTime) {
            if (t.isAfter(now) && t.isBefore(best)) best = t
        }
        for (day in days) {
            for (course in day.courses) {
                consider(course.start)
                consider(course.end)
            }
        }
        for (exam in exams) {
            consider(exam.start)
            consider(exam.effectiveEnd)
        }
        return best
    }

    /** 此刻有进行中的课（需要排进度条的 10 分钟非唤醒闹钟）。 */
    fun hasOngoingCourse(days: List<Day>, now: LocalDateTime): Boolean =
        hero(days, now)?.ongoing == true

    // ----------------------------------------------------------------- label

    private val WEEKDAYS = arrayOf("周一", "周二", "周三", "周四", "周五", "周六", "周日")

    fun weekday(date: LocalDate): String = WEEKDAYS[date.dayOfWeek.value - 1]

    /** 今天 / 明天 / 周X（相对 [today]）。 */
    fun dayLabel(today: LocalDate, target: LocalDate): String =
        when (ChronoUnit.DAYS.between(today, target)) {
            0L -> "今天"
            1L -> "明天"
            else -> weekday(target)
        }

    fun hhmm(time: LocalDateTime): String =
        "${time.hour.toString().padStart(2, '0')}:${time.minute.toString().padStart(2, '0')}"

    /** 「第 7 周 · 周五」→「第 7 周」。 */
    fun weekOnly(label: String): String = label.substringBefore(" · ").trim()
}
