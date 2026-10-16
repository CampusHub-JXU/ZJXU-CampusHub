package edu.zjxu.jxucampushub.widget

import edu.zjxu.jxucampushub.widget.CampusWidgetTimeLogic.Course
import edu.zjxu.jxucampushub.widget.CampusWidgetTimeLogic.Day
import edu.zjxu.jxucampushub.widget.CampusWidgetTimeLogic.Exam
import edu.zjxu.jxucampushub.widget.CampusWidgetTimeLogic.MediumKind
import java.time.LocalDate
import java.time.LocalDateTime

// Host-JVM tests for the pure widget time logic (no Android classes).
// Run: python tools/widget_native_tests/run.py

private var checks = 0

private fun check(condition: Boolean, message: String) {
    checks++
    if (!condition) throw AssertionError(message)
}

private fun <T> eq(actual: T, expected: T, message: String) {
    checks++
    if (actual != expected) throw AssertionError("$message: expected=$expected actual=$actual")
}

private fun dt(date: String, time: String) = LocalDateTime.parse("${date}T$time:00")

private fun course(date: String, from: String, to: String, name: String, loc: String = "") =
    Course(dt(date, from), dt(date, to), "$from-$to", "", name, loc)

private fun day(date: String, vararg courses: Course, holiday: String = "") =
    Day(LocalDate.parse(date), "第 7 周 · x", holiday, courses.toList())

// 2026-10-16 is a Friday.
private val friday = day(
    "2026-10-16",
    course("2026-10-16", "08:00", "09:35", "高等数学", "7-201"),
    course("2026-10-16", "10:10", "11:45", "大学英语", "3-105"),
    course("2026-10-16", "14:00", "15:35", "程序设计", "2-110"),
)
private val saturday = day("2026-10-17")
private val sunday = day("2026-10-18")
private val monday = day(
    "2026-10-19",
    course("2026-10-19", "08:00", "09:35", "高等数学", "2-110"),
)
private val week = listOf(friday, saturday, sunday, monday)
private val today0 = LocalDate.parse("2026-10-16")

fun main() {
    // --- hero: ongoing first, else next upcoming
    var hero = CampusWidgetTimeLogic.hero(week, dt("2026-10-16", "07:00"))!!
    eq(hero.course.name, "高等数学", "before first class -> first upcoming")
    check(!hero.ongoing, "upcoming is not ongoing")

    hero = CampusWidgetTimeLogic.hero(week, dt("2026-10-16", "08:00"))!!
    check(hero.ongoing, "start instant is ongoing")
    hero = CampusWidgetTimeLogic.hero(week, dt("2026-10-16", "09:35"))!!
    check(!hero.ongoing, "end instant is no longer ongoing")
    eq(hero.course.name, "大学英语", "gap -> next upcoming")

    hero = CampusWidgetTimeLogic.hero(week, dt("2026-10-16", "16:00"))!!
    eq(hero.course.name, "高等数学", "after today's classes -> next within days")
    eq(hero.date, LocalDate.parse("2026-10-19"), "next class is on Monday")
    check(CampusWidgetTimeLogic.hero(week, dt("2026-10-19", "10:00")) == null, "nothing left")

    // --- coursesAfterHero
    hero = CampusWidgetTimeLogic.hero(week, dt("2026-10-16", "08:30"))!!
    eq(
        CampusWidgetTimeLogic.coursesAfterHero(week, hero, dt("2026-10-16", "08:30"), 2).map { it.name },
        listOf("大学英语", "程序设计"),
        "next rows after ongoing",
    )
    eq(
        CampusWidgetTimeLogic.coursesAfterHero(week, hero, dt("2026-10-16", "08:30"), 1).size,
        1,
        "limit respected",
    )

    // --- progress
    eq(CampusWidgetTimeLogic.progressPercent(friday.courses[0], dt("2026-10-16", "08:00")), 0, "progress 0")
    eq(CampusWidgetTimeLogic.progressPercent(friday.courses[0], dt("2026-10-16", "09:35")), 100, "progress 100")
    eq(CampusWidgetTimeLogic.progressPercent(friday.courses[0], dt("2026-10-16", "08:47")), 49, "progress mid")

    // --- medium plan
    var plan = CampusWidgetTimeLogic.mediumPlan(week, dt("2026-10-16", "08:30"))
    eq(plan.kind, MediumKind.TODAY, "today remaining")
    plan = CampusWidgetTimeLogic.mediumPlan(week, dt("2026-10-16", "16:00"))
    eq(plan.kind, MediumKind.OVER, "today over")
    plan = CampusWidgetTimeLogic.mediumPlan(week, dt("2026-10-17", "10:00"))
    eq(plan.kind, MediumKind.NONE, "no class today")
    eq(
        CampusWidgetTimeLogic.mediumPlan(week, dt("2026-10-30", "10:00")).kind,
        MediumKind.UNKNOWN,
        "stale snapshot",
    )

    // --- flow: today's remaining unlabeled, later days labelled, empty days skipped
    var items = CampusWidgetTimeLogic.flow(week, dt("2026-10-16", "09:40"), null, LocalDate.parse("2026-10-16"))
    eq(
        items.map { it.course?.name ?: "L:" + it.labelDate },
        listOf("大学英语", "程序设计", "L:2026-10-19", "高等数学"),
        "flow with unlabeled today",
    )
    items = CampusWidgetTimeLogic.flow(week, dt("2026-10-16", "16:00"), null, null)
    eq(
        items.map { it.course?.name ?: "L:" + it.labelDate },
        listOf("L:2026-10-19", "高等数学"),
        "flow when today over: next class day under a label",
    )
    val heroNow = dt("2026-10-16", "08:30")
    val heroOngoing = CampusWidgetTimeLogic.hero(week, heroNow)!!
    items = CampusWidgetTimeLogic.flow(week, heroNow, heroOngoing.course, heroOngoing.date)
    eq(items.map { it.course?.name ?: "L" }, listOf("大学英语", "程序设计", "L", "高等数学"), "flow skips hero")

    // --- fit
    eq(CampusWidgetTimeLogic.fit(items, 1000, 2).size, 2, "max slots")
    eq(CampusWidgetTimeLogic.fit(items, 60, 10).size, 2, "budget: two course rows")
    // budget ends right after a label -> trailing label dropped
    eq(CampusWidgetTimeLogic.fit(items, 60 + 26, 10).size, 2, "orphan label dropped")
    eq(CampusWidgetTimeLogic.fit(items, 60 + 26 + 30, 10).size, 4, "label + row fit")
    eq(CampusWidgetTimeLogic.fit(emptyList(), 100, 10).size, 0, "empty")
    eq(CampusWidgetTimeLogic.dateLabel(today0, LocalDate.parse("2026-10-19")), "周一 10/19", "dateLabel")
    eq(CampusWidgetTimeLogic.dateLabel(today0, LocalDate.parse("2026-10-17")), "明天 10/17", "dateLabel tomorrow")

    // --- exams
    val exams = listOf(
        Exam(dt("2026-10-20", "09:00"), dt("2026-10-20", "11:00"), "", "线性代数", ""),
        Exam(dt("2026-10-22", "14:00"), null, "", "大学物理", ""),
    )
    eq(CampusWidgetTimeLogic.nearestExam(exams, dt("2026-10-16", "12:00"))?.name, "线性代数", "nearest exam")
    eq(CampusWidgetTimeLogic.nearestExam(exams, dt("2026-10-20", "11:00"))?.name, "大学物理", "ended exam skipped")
    check(CampusWidgetTimeLogic.nearestExam(exams, dt("2026-10-22", "16:00")) == null, "null end -> +2h")
    eq(CampusWidgetTimeLogic.examCountdownDays(exams[0], dt("2026-10-16", "23:59")), 4, "countdown 4 days")
    eq(CampusWidgetTimeLogic.examCountdownDays(exams[0], dt("2026-10-17", "00:00")), 3, "countdown ticks at midnight")
    eq(CampusWidgetTimeLogic.examCountdownDays(exams[0], dt("2026-10-20", "09:30")), 0, "exam day -> 0")

    // --- next boundary
    eq(
        CampusWidgetTimeLogic.nextBoundary(week, exams, dt("2026-10-16", "07:00")),
        dt("2026-10-16", "08:00"),
        "boundary = first class start",
    )
    eq(
        CampusWidgetTimeLogic.nextBoundary(week, exams, dt("2026-10-16", "08:00")),
        dt("2026-10-16", "09:35"),
        "boundary is strictly after now",
    )
    eq(
        CampusWidgetTimeLogic.nextBoundary(week, exams, dt("2026-10-16", "16:00")),
        dt("2026-10-17", "00:00"),
        "boundary = midnight when classes are over",
    )
    eq(
        CampusWidgetTimeLogic.nextBoundary(emptyList(), emptyList(), dt("2026-12-31", "23:00")),
        dt("2027-01-01", "00:00"),
        "midnight rolls the year",
    )
    eq(
        CampusWidgetTimeLogic.nextBoundary(emptyList(), exams, dt("2026-10-19", "23:00")),
        dt("2026-10-20", "00:00"),
        "midnight before exam",
    )
    eq(
        CampusWidgetTimeLogic.nextBoundary(emptyList(), exams, dt("2026-10-20", "00:00")),
        dt("2026-10-20", "09:00"),
        "exam start is a boundary",
    )
    check(CampusWidgetTimeLogic.hasOngoingCourse(week, dt("2026-10-16", "08:01")), "ongoing")
    check(!CampusWidgetTimeLogic.hasOngoingCourse(week, dt("2026-10-16", "09:50")), "not ongoing")

    // --- labels
    val today = LocalDate.parse("2026-10-16")
    eq(CampusWidgetTimeLogic.dayLabel(today, today), "今天", "today")
    eq(CampusWidgetTimeLogic.dayLabel(today, LocalDate.parse("2026-10-17")), "明天", "tomorrow")
    eq(CampusWidgetTimeLogic.dayLabel(today, LocalDate.parse("2026-10-19")), "周一", "weekday")
    eq(CampusWidgetTimeLogic.weekday(LocalDate.parse("2026-10-18")), "周日", "sunday")
    eq(CampusWidgetTimeLogic.hhmm(dt("2026-10-16", "08:05")), "08:05", "hhmm padding")
    eq(CampusWidgetTimeLogic.weekOnly("第 7 周 · 周五"), "第 7 周", "week only")
    eq(CampusWidgetTimeLogic.weekOnly("第 7 周"), "第 7 周", "week only (no suffix)")

    println("CampusWidgetTimeLogicTest passed ($checks checks)")
}
