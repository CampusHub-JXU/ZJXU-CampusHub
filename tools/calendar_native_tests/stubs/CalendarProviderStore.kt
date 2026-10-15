package edu.zjxu.jxucampushub.platform.calendar

import android.content.ContentResolver
import java.util.concurrent.CopyOnWriteArrayList

internal class CalendarProviderStore(
    resolver: ContentResolver,
    packageName: String,
) {
    companion object {
        val invocations = CopyOnWriteArrayList<Pair<String, String>>()
        @Volatile var blockFirstQuery: (() -> Unit)? = null
        @Volatile var failList: Boolean = false
    }

    fun createOrGetLocalCalendar(): Long = run("create") { 1L }
    fun listWritableCalendars(): List<Map<String, Any?>> = run("list") {
        if (failList) throw IllegalStateException("opaque provider failure")
        emptyList()
    }
    fun queryOwnedEvents(calendarId: Long, opaqueIds: List<String>?): List<Map<String, Any?>> =
        run("query") { blockFirstQuery?.invoke(); emptyList() }
    fun listOwnedEventCalendars(): Map<String, Any?> = run("ownedCalendars") {
        mapOf("calendars" to emptyList<Any>(), "complete" to true, "reason" to null)
    }
    fun scanOwnedEvents(calendarId: Long): Map<String, Any?> = run("scan") {
        mapOf("events" to emptyList<Any>(), "complete" to true, "reason" to null)
    }
    fun upsertEventBatch(calendarId: Long, events: List<CalendarEventInput>): Map<String, Any?> =
        run("upsert") { mapOf("created" to 0, "updated" to 0, "deleted" to 0) }
    fun deleteOwnedEventsByIds(calendarId: Long, items: List<Pair<String, Long>>): Map<String, Any?> =
        run("delete") { mapOf("deleted" to 0) }

    private inline fun <T> run(name: String, action: () -> T): T {
        invocations += name to Thread.currentThread().name
        return action()
    }
}
