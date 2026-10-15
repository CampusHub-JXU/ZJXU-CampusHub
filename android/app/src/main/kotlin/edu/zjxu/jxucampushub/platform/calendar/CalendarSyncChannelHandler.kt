package edu.zjxu.jxucampushub.platform.calendar

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 课表日历同步通道（仅前台，主 Activity 注册）。
 *
 * 固定协议 7 方法：
 * `checkPermissions` / `requestPermissions` / `createOrGetLocalCalendar` /
 * `listWritableCalendars` / `queryOwnedEvents` / `upsertEventBatch` /
 * `deleteOwnedEventsByIds`。
 *
 * - 每次写操作前在原生侧再查 READ + WRITE_CALENDAR；
 * - `requestPermissions` 依赖 Activity 的 `onRequestPermissionsResult` 回填，
 *   MainActivity 必须把结果转发进来，并保留 `super` 以不破坏其他插件；
 * - 业务失败统一返回带安全错误类别的 `PlatformException`，不含 PII；
 * - 不在 WorkManager 后台引擎注册。
 */
class CalendarSyncChannelHandler(private val activity: Activity) {
    companion object {
        /** 与其他 Flutter 插件错开的高位 requestCode。 */
        private const val REQUEST_CODE = 0x7A1C

        private val CALENDAR_PERMISSIONS = arrayOf(
            Manifest.permission.READ_CALENDAR,
            Manifest.permission.WRITE_CALENDAR,
        )
    }

    private val store by lazy {
        CalendarProviderStore(activity.contentResolver, activity.packageName)
    }

    /** 等待 `onRequestPermissionsResult` 回填的挂起结果；同一时刻只允许一个。 */
    private var pendingPermissionResult: MethodChannel.Result? = null

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CalendarSyncContract.CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "checkPermissions" -> result.success(hasCalendarPermissions())
                "requestPermissions" -> requestPermissions(result)
                else -> handleAuthorizedCall(call, result)
            }
        }
    }

    /**
     * 由 MainActivity 的 `onRequestPermissionsResult` 转发；只处理本通道的 requestCode，
     * 其余交回 `super`。
     */
    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != REQUEST_CODE) return
        val pending = pendingPermissionResult ?: return
        pendingPermissionResult = null
        pending.success(hasCalendarPermissions())
    }

    private fun handleAuthorizedCall(call: MethodCall, result: MethodChannel.Result) {
        if (!hasCalendarPermissions()) {
            result.error(
                CalendarSyncErrors.PERMISSION_DENIED,
                "calendar permission not granted",
                null,
            )
            return
        }

        try {
            when (call.method) {
                "createOrGetLocalCalendar" -> result.success(store.createOrGetLocalCalendar())
                "listWritableCalendars" -> result.success(store.listWritableCalendars())
                "queryOwnedEvents" -> result.success(queryOwnedEvents(call))
                "listOwnedEventCalendars" -> result.success(store.listOwnedEventCalendars())
                "scanOwnedEvents" -> result.success(scanOwnedEvents(call))
                "upsertEventBatch" -> result.success(upsertEventBatch(call))
                "deleteOwnedEventsByIds" -> result.success(deleteOwnedEventsByIds(call))
                else -> result.notImplemented()
            }
        } catch (error: CalendarSyncException) {
            result.error(error.category, error.message, null)
        } catch (_: Exception) {
            result.error(
                CalendarSyncErrors.PROVIDER_UNAVAILABLE,
                "calendar operation failed",
                null,
            )
        }
    }

    private fun queryOwnedEvents(call: MethodCall): List<Map<String, Any?>> {
        val calendarId = requireCalendarId(call.argument<Number>("calendarId"))
        val opaqueIds = parseOpaqueIds(call.argument<List<*>>("opaqueIds"))
        return store.queryOwnedEvents(calendarId, opaqueIds)
    }

    private fun scanOwnedEvents(call: MethodCall): Map<String, Any?> {
        val calendarId = requireCalendarId(call.argument<Number>("calendarId"))
        return store.scanOwnedEvents(calendarId)
    }

    private fun upsertEventBatch(call: MethodCall): Map<String, Any?> {
        val calendarId = requireCalendarId(call.argument<Number>("calendarId"))
        val rawEvents = call.argument<List<*>>("events")
            ?: throw CalendarSyncException(CalendarSyncErrors.INVALID_ARGS, "events is required")
        if (rawEvents.isEmpty() || rawEvents.size > CalendarSyncContract.MAX_BATCH_EVENTS) {
            throw CalendarSyncException(CalendarSyncErrors.INVALID_ARGS, "invalid event count")
        }

        val events = rawEvents.map { raw ->
            val map = raw as? Map<*, *>
                ?: throw CalendarSyncException(CalendarSyncErrors.INVALID_ARGS, "invalid event entry")
            parseEventInput(map)
        }
        if (events.map { it.opaqueId }.toSet().size != events.size) {
            throw CalendarSyncException(CalendarSyncErrors.INVALID_ARGS, "duplicate opaqueId in batch")
        }

        return store.upsertEventBatch(calendarId, events)
    }

    private fun deleteOwnedEventsByIds(call: MethodCall): Map<String, Any?> {
        val calendarId = requireCalendarId(call.argument<Number>("calendarId"))
        val rawEvents = call.argument<List<*>>("events")
            ?: throw CalendarSyncException(CalendarSyncErrors.INVALID_ARGS, "events is required")
        if (rawEvents.isEmpty() || rawEvents.size > CalendarSyncContract.MAX_BATCH_EVENTS) {
            throw CalendarSyncException(CalendarSyncErrors.INVALID_ARGS, "invalid event count")
        }

        val items = rawEvents.map { raw ->
            val map = raw as? Map<*, *>
                ?: throw CalendarSyncException(CalendarSyncErrors.INVALID_ARGS, "invalid event entry")
            val opaqueId = (map["opaqueId"] as? String)?.trim().orEmpty()
            if (!CalendarSyncContract.isValidOpaqueId(opaqueId)) {
                throw CalendarSyncException(CalendarSyncErrors.INVALID_ARGS, "invalid opaqueId")
            }
            val eventId = (map["eventId"] as? Number)?.toLong()
                ?: throw CalendarSyncException(CalendarSyncErrors.INVALID_ARGS, "invalid eventId")
            if (eventId <= 0L) {
                throw CalendarSyncException(CalendarSyncErrors.INVALID_ARGS, "invalid eventId")
            }
            opaqueId to eventId
        }
        if (items.map { it.first }.toSet().size != items.size) {
            throw CalendarSyncException(CalendarSyncErrors.INVALID_ARGS, "duplicate opaqueId in batch")
        }

        return store.deleteOwnedEventsByIds(calendarId, items)
    }

    private fun parseOpaqueIds(raw: List<*>?): List<String>? {
        if (raw == null) return null
        if (raw.size > CalendarSyncContract.MAX_QUERY_OPAQUE_IDS) {
            throw CalendarSyncException(CalendarSyncErrors.INVALID_ARGS, "too many opaqueIds")
        }
        return raw.map { element ->
            val id = element as? String
                ?: throw CalendarSyncException(CalendarSyncErrors.INVALID_ARGS, "invalid opaqueId")
            if (!CalendarSyncContract.isValidOpaqueId(id)) {
                throw CalendarSyncException(CalendarSyncErrors.INVALID_ARGS, "invalid opaqueId")
            }
            id
        }
    }

    private fun requireCalendarId(value: Number?): Long {
        val id = value?.toLong()
            ?: throw CalendarSyncException(CalendarSyncErrors.INVALID_ARGS, "calendarId is required")
        if (id <= 0L) {
            throw CalendarSyncException(CalendarSyncErrors.INVALID_ARGS, "invalid calendarId")
        }
        return id
    }

    private fun requestPermissions(result: MethodChannel.Result) {
        if (hasCalendarPermissions()) {
            result.success(true)
            return
        }
        if (pendingPermissionResult != null) {
            result.error(
                CalendarSyncErrors.REQUESTS_IN_FLIGHT,
                "a permission request is already in progress",
                null,
            )
            return
        }

        pendingPermissionResult = result
        try {
            activity.requestPermissions(CALENDAR_PERMISSIONS, REQUEST_CODE)
        } catch (_: Exception) {
            pendingPermissionResult = null
            result.error(
                CalendarSyncErrors.PROVIDER_UNAVAILABLE,
                "permission request failed",
                null,
            )
        }
    }

    private fun hasCalendarPermissions(): Boolean =
        hasPermission(Manifest.permission.READ_CALENDAR) &&
            hasPermission(Manifest.permission.WRITE_CALENDAR)

    private fun hasPermission(permission: String): Boolean =
        activity.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
}
