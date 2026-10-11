package edu.zjxu.jxucampushub.platform.calendar

import android.content.ContentProviderOperation
import android.content.ContentProviderResult
import android.content.ContentResolver
import android.content.ContentUris
import android.content.ContentValues
import android.provider.CalendarContract
import android.util.Log

/**
 * 系统日历 provider 的唯一访问层。
 *
 * 所有权铁律：
 * - 专属本地日历用 `ACCOUNT_TYPE=LOCAL` + 由 packageName 派生的 accountName/NAME
 *   三元组严格定位，绝不回退到「第一个可写日历」，避免误写他人日历；
 * - 所有 UPDATE / DELETE 的 selection 同时限定 `_id + calendar_id +
 *   custom_app_package + custom_app_uri`，不做「先查后裸 id 操作」；
 * - 同 opaqueId 在别的 calendar 已存在时拒绝插入，避免重复；
 * - 批次用不 yield 的 `applyBatch`，任一步失败整体抛错，不伪造成功。
 *
 * 日志只记录异常类型，不打印账号 / 课名 / 事件 URI。
 */
internal class CalendarProviderStore(
    private val resolver: ContentResolver,
    private val packageName: String,
) {
    companion object {
        private const val TAG = "CalendarSync"

        private val CALENDAR_PROJECTION = arrayOf(
            CalendarContract.Calendars._ID,
            CalendarContract.Calendars.CALENDAR_DISPLAY_NAME,
            CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL,
        )

        private val EVENT_OWNER_SELECTION =
            "${CalendarContract.Events._ID} = ? AND " +
                "${CalendarContract.Events.CALENDAR_ID} = ? AND " +
                "${CalendarContract.Events.CUSTOM_APP_PACKAGE} = ? AND " +
                "${CalendarContract.Events.CUSTOM_APP_URI} = ?"

        // 所有权 selection 在每次 UPDATE/DELETE **执行时**重新求值（provider 侧按行匹配），
        // 故「先查后写」的 TOCTOU 窗口只影响理论并发；本功能仅 App 前台单写者，
        // 且 UPDATE 带 withExpectedCount(1) 令 0/多行整批回滚、DELETE 0 行按 notDeleted 返回，
        // 不构成跨进程强一致保证（用户可能同时在系统日历手工改动）。
    }

    private val accountName = "$packageName.calendar"
    private val calendarName = "$packageName.course-sync"

    private val ownedCalendarSelection =
        "${CalendarContract.Calendars.ACCOUNT_TYPE} = ? AND " +
            "${CalendarContract.Calendars.ACCOUNT_NAME} = ? AND " +
            "${CalendarContract.Calendars.NAME} = ?"

    // ---------------------------------------------------------------- calendar

    /**
     * 返回本 App 专属本地日历；不存在则创建。
     *
     * 创建走官方 `ACCOUNT_TYPE_LOCAL` sync-adapter-style URI（`CALLER_IS_SYNCADAPTER=true`
     * + ACCOUNT_NAME/ACCOUNT_TYPE query params，见 AOSP CalendarProvider2 的本地日历路径），
     * 但**不**新建真正的 sync adapter；创建后重新用严格三元组复核身份与可写性，失败即安全
     * 抛错，**不**重复创建。
     */
    fun createOrGetLocalCalendar(): Map<String, Any?> {
        findOwnedCalendar()?.let { owned ->
            return mapOf("id" to owned.first, "displayName" to owned.second)
        }

        val values = ContentValues().apply {
            put(CalendarContract.Calendars.ACCOUNT_NAME, accountName)
            put(CalendarContract.Calendars.ACCOUNT_TYPE, CalendarContract.ACCOUNT_TYPE_LOCAL)
            put(CalendarContract.Calendars.NAME, calendarName)
            put(CalendarContract.Calendars.CALENDAR_DISPLAY_NAME, CalendarSyncContract.LOCAL_DISPLAY_NAME)
            put(CalendarContract.Calendars.CALENDAR_COLOR, CalendarSyncContract.LOCAL_CALENDAR_COLOR)
            put(
                CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL,
                CalendarContract.Calendars.CAL_ACCESS_OWNER,
            )
            put(CalendarContract.Calendars.OWNER_ACCOUNT, accountName)
            put(CalendarContract.Calendars.VISIBLE, 1)
            put(CalendarContract.Calendars.SYNC_EVENTS, 1)
        }

        val createUri = CalendarContract.Calendars.CONTENT_URI.buildUpon()
            .appendQueryParameter(CalendarContract.CALLER_IS_SYNCADAPTER, "true")
            .appendQueryParameter(CalendarContract.Calendars.ACCOUNT_NAME, accountName)
            .appendQueryParameter(CalendarContract.Calendars.ACCOUNT_TYPE, CalendarContract.ACCOUNT_TYPE_LOCAL)
            .build()

        val uri = resolver.insert(createUri, values)
            ?: throw CalendarSyncException(
                CalendarSyncErrors.PROVIDER_UNAVAILABLE,
                "local calendar insert returned no uri",
            )
        val id = ContentUris.parseId(uri)
        if (id <= 0L) {
            throw CalendarSyncException(
                CalendarSyncErrors.PROVIDER_UNAVAILABLE,
                "local calendar insert returned invalid id",
            )
        }

        // 创建后按严格身份 + 可写复核；失败不重复创建（重复插入会制造拥有权歧义）。
        val owned = findOwnedCalendar()
            ?: throw CalendarSyncException(
                CalendarSyncErrors.CALENDAR_UNAVAILABLE,
                "created local calendar not found",
            )
        if (owned.first != id) {
            throw CalendarSyncException(
                CalendarSyncErrors.OWNERSHIP_CONFLICT,
                "created local calendar identity mismatch",
            )
        }
        return mapOf("id" to owned.first, "displayName" to owned.second)
    }

    /** 列出所有可写（access >= CONTRIBUTOR）日历，仅用于用户选择，不自动写入。 */
    fun listWritableCalendars(): List<Map<String, Any?>> {
        val projection = arrayOf(
            CalendarContract.Calendars._ID,
            CalendarContract.Calendars.CALENDAR_DISPLAY_NAME,
            CalendarContract.Calendars.ACCOUNT_NAME,
        )
        val selection = "${CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL} >= ?"
        val args = arrayOf(CalendarContract.Calendars.CAL_ACCESS_CONTRIBUTOR.toString())
        val sortOrder = "${CalendarContract.Calendars.CALENDAR_DISPLAY_NAME} COLLATE NOCASE ASC"

        val result = mutableListOf<Map<String, Any?>>()
        resolver.query(
            CalendarContract.Calendars.CONTENT_URI,
            projection,
            selection,
            args,
            sortOrder,
        ).use { cursor ->
            if (cursor == null) {
                throw CalendarSyncException(
                    CalendarSyncErrors.PROVIDER_UNAVAILABLE,
                    "calendar provider unavailable",
                )
            }
            while (cursor.moveToNext()) {
                val id = cursor.getLong(0)
                val displayName = cursor.getString(1) ?: continue
                val account = cursor.getString(2)
                result += mapOf(
                    "id" to id,
                    "displayName" to displayName,
                    "accountName" to account?.takeIf { it.isNotBlank() },
                )
            }
        }
        return result
    }

    /**
     * 以严格三元组（ACCOUNT_TYPE=LOCAL + accountName + NAME）读取本 App 专属日历。
     *
     * 读取**不**附加 `CALLER_IS_SYNCADAPTER` query params：官方/AOSP 只在写路径用该参数
     * 指定调用账户，普通 query 已能看到本地日历；附加它会收窄可见范围、改变读取语义，
     * 故保持普通 query 以免误判「不存在」而重复创建。
     */
    private fun findOwnedCalendar(): Pair<Long, String>? {
        val args = arrayOf(
            CalendarContract.ACCOUNT_TYPE_LOCAL,
            accountName,
            calendarName,
        )
        var owned: Pair<Long, String>? = null
        resolver.query(
            CalendarContract.Calendars.CONTENT_URI,
            CALENDAR_PROJECTION,
            ownedCalendarSelection,
            args,
            null,
        ).use { cursor ->
            if (cursor == null) {
                throw CalendarSyncException(
                    CalendarSyncErrors.PROVIDER_UNAVAILABLE,
                    "calendar provider unavailable",
                )
            }
            val count = cursor.count
            if (count > 1) {
                throw CalendarSyncException(
                    CalendarSyncErrors.CALENDAR_UNAVAILABLE,
                    "duplicate owned local calendars",
                )
            }
            if (count == 1) {
                cursor.moveToFirst()
                val id = cursor.getLong(0)
                if (id <= 0L) {
                    throw CalendarSyncException(
                        CalendarSyncErrors.CALENDAR_UNAVAILABLE,
                        "owned local calendar has invalid id",
                    )
                }
                val displayName = cursor.getString(1) ?: CalendarSyncContract.LOCAL_DISPLAY_NAME
                val access = cursor.getInt(2)
                if (access < CalendarContract.Calendars.CAL_ACCESS_CONTRIBUTOR) {
                    throw CalendarSyncException(
                        CalendarSyncErrors.CALENDAR_UNAVAILABLE,
                        "owned local calendar is not writable",
                    )
                }
                owned = Pair(id, displayName)
            }
        }
        return owned
    }

    // ------------------------------------------------------------------ events

    /**
     * 查询目标 calendar 内本 App 拥有的（且 URI 前缀匹配的）事件。
     *
     * `opaqueIds == null` 查询该日历全部自有事件；显式传入列表（含空列表）则按其过滤。
     */
    fun queryOwnedEvents(calendarId: Long, opaqueIds: List<String>?): List<Map<String, Any?>> {
        if (opaqueIds != null && opaqueIds.isEmpty()) return emptyList()

        val selection = StringBuilder()
        selection.append("${CalendarContract.Events.CALENDAR_ID} = ? AND ")
        selection.append("${CalendarContract.Events.CUSTOM_APP_PACKAGE} = ? AND ")
        selection.append("${CalendarContract.Events.CUSTOM_APP_URI} LIKE ?")

        val args = mutableListOf(
            calendarId.toString(),
            packageName,
            "${CalendarSyncContract.EVENT_URI_PREFIX}%",
        )

        if (opaqueIds != null) {
            selection.append(" AND ${CalendarContract.Events.CUSTOM_APP_URI} IN (")
            selection.append(opaqueIds.joinToString(",") { "?" })
            selection.append(")")
            opaqueIds.forEach { args += CalendarSyncContract.eventUri(it) }
        }

        val projection = arrayOf(
            CalendarContract.Events._ID,
            CalendarContract.Events.CUSTOM_APP_URI,
        )

        val result = mutableListOf<Map<String, Any?>>()
        resolver.query(
            CalendarContract.Events.CONTENT_URI,
            projection,
            selection.toString(),
            args.toTypedArray(),
            null,
        ).use { cursor ->
            if (cursor == null) {
                throw CalendarSyncException(
                    CalendarSyncErrors.PROVIDER_UNAVAILABLE,
                    "calendar provider unavailable",
                )
            }
            while (cursor.moveToNext()) {
                val eventId = cursor.getLong(0)
                val opaqueId = CalendarSyncContract.opaqueIdFromUri(cursor.getString(1)) ?: continue
                result += mapOf("opaqueId" to opaqueId, "eventId" to eventId)
            }
        }
        return result
    }

    // ------------------------------------------------- orphan discovery (read-only)

    /**
     * 只读：跨**全部**日历扫描「当前真实 packageName + 合法 marker」证实的本 App
     * 遗留事件日历（Issue #48 第一阶段）。
     *
     * 纯读：绝不 create / insert / update / delete 任何行，不创建本地日历，不改绑定 /
     * 账本 / 控制态。返回固定 DTO `{calendars, complete, reason}`：
     * - 候选日历 id 由 events 查询（`CUSTOM_APP_PACKAGE = packageName` +
     *   `CUSTOM_APP_URI LIKE prefix%`）派生，逐行严格 `opaqueIdFromUri` 复核；
     * - 元数据**只**对命中的自有日历 id 查询 `DISPLAY_NAME + ACCESS_LEVEL`，绝不读
     *   账号 / 邮箱 / owner 名；缺失 / 查询失败按 `writable=null` 保守表示并令
     *   `complete=false`（`calendarUnavailable`）；
     * - 扫描上限 [CalendarSyncContract.MAX_SCAN_MARKER_ROWS] 行 /
     *   [CalendarSyncContract.MAX_OWNED_CALENDARS] 个日历，超限即 `complete=false`
     *   （`scanLimit`），绝不把部分结果当「全清」；
     * - provider / 权限异常整体降级为 `complete=false`（`unavailable` /
     *   `permissionDenied`），绝不返回「零个即干净」。
     */
    fun listOwnedEventCalendars(): Map<String, Any?> {
        val ownedCalendarIds = LinkedHashSet<Long>()
        var truncated = false

        val eventSelection =
            "${CalendarContract.Events.CUSTOM_APP_PACKAGE} = ? AND " +
                "${CalendarContract.Events.CUSTOM_APP_URI} LIKE ? AND " +
                "(${CalendarContract.Events.DELETED} IS NULL OR " +
                "${CalendarContract.Events.DELETED} = 0)"
        val eventArgs = arrayOf(
            packageName,
            "${CalendarSyncContract.EVENT_URI_PREFIX}%",
        )
        val eventProjection = arrayOf(
            CalendarContract.Events.CALENDAR_ID,
            CalendarContract.Events.CUSTOM_APP_URI,
        )

        try {
            resolver.query(
                CalendarContract.Events.CONTENT_URI,
                eventProjection,
                eventSelection,
                eventArgs,
                null,
            ).use { cursor ->
                if (cursor == null) {
                    throw CalendarSyncException(
                        CalendarSyncErrors.PROVIDER_UNAVAILABLE,
                        "calendar provider unavailable",
                    )
                }
                var scanned = 0
                while (cursor.moveToNext()) {
                    // 非法行同样消耗扫描预算，避免大量垃圾行绕过上限。
                    if (scanned >= CalendarSyncContract.MAX_SCAN_MARKER_ROWS) {
                        truncated = true
                        break
                    }
                    scanned++
                    val calendarId = cursor.getLong(0)
                    if (calendarId <= 0L) continue
                    if (CalendarSyncContract.opaqueIdFromUri(cursor.getString(1)) == null) continue
                    ownedCalendarIds += calendarId
                    if (ownedCalendarIds.size > CalendarSyncContract.MAX_OWNED_CALENDARS) {
                        truncated = true
                        break
                    }
                }
            }
        } catch (error: SecurityException) {
            Log.w(TAG, "discovery denied: ${error.javaClass.simpleName}")
            return discoveryResult(
                calendars = emptyList(),
                complete = false,
                reason = CalendarOwnedScanReasons.PERMISSION_DENIED,
            )
        } catch (error: Exception) {
            Log.w(TAG, "discovery scan failed: ${error.javaClass.simpleName}")
            return discoveryResult(
                calendars = emptyList(),
                complete = false,
                reason = CalendarOwnedScanReasons.UNAVAILABLE,
            )
        }

        var metadataFailed = false
        val metadata: Map<Long, CalendarMetadata> = if (ownedCalendarIds.isEmpty()) {
            emptyMap()
        } else {
            try {
                queryCalendarMetadata(ownedCalendarIds)
            } catch (error: Exception) {
                Log.w(TAG, "discovery metadata failed: ${error.javaClass.simpleName}")
                metadataFailed = true
                emptyMap()
            }
        }

        var unknownMetadata = false
        val calendars = ownedCalendarIds.map { calendarId ->
            val meta = metadata[calendarId]
            if (meta == null || meta.writable == null) unknownMetadata = true
            mapOf<String, Any?>(
                "calendarId" to calendarId,
                "displayName" to meta?.displayName,
                "writable" to meta?.writable,
            )
        }

        val reason: String? = when {
            truncated -> CalendarOwnedScanReasons.SCAN_LIMIT
            metadataFailed || unknownMetadata -> CalendarOwnedScanReasons.CALENDAR_UNAVAILABLE
            else -> null
        }

        return discoveryResult(calendars, reason == null, reason)
    }

    /**
     * 只读：扫描**单个** calendar 内本 App 拥有的全部事件（Issue #48 清理用）。
     *
     * 与 [queryOwnedEvents] 不同：**允许**同一 opaqueId 对应多个 eventId（历史重复），
     * 逐行严格 marker 复核；拒绝重复的 (opaqueId,eventId) 精确对与非法行（令
     * `complete=false`）；行数上限 [CalendarSyncContract.MAX_SCAN_MARKER_ROWS]。
     * 纯读：绝不 create / insert / update / delete 任何行。
     *
     * 返回固定 DTO `{events:[{opaqueId,eventId}], complete, reason}`；provider /
     * 权限异常整体降级为 `complete=false`（`unavailable` / `permissionDenied`），
     * 绝不返回「零个即干净」。
     */
    fun scanOwnedEvents(calendarId: Long): Map<String, Any?> {
        if (calendarId <= 0L) {
            throw CalendarSyncException(
                CalendarSyncErrors.INVALID_ARGS,
                "calendarId must be positive",
            )
        }

        val selection =
            "${CalendarContract.Events.CALENDAR_ID} = ? AND " +
                "${CalendarContract.Events.CUSTOM_APP_PACKAGE} = ? AND " +
                "${CalendarContract.Events.CUSTOM_APP_URI} LIKE ? AND " +
                "(${CalendarContract.Events.DELETED} IS NULL OR " +
                "${CalendarContract.Events.DELETED} = 0)"
        val args = arrayOf(
            calendarId.toString(),
            packageName,
            "${CalendarSyncContract.EVENT_URI_PREFIX}%",
        )
        val projection = arrayOf(
            CalendarContract.Events._ID,
            CalendarContract.Events.CUSTOM_APP_URI,
        )

        val events = mutableListOf<Map<String, Any?>>()
        val seenPairs = HashSet<String>()
        var truncated = false
        var invalid = false
        try {
            resolver.query(
                CalendarContract.Events.CONTENT_URI,
                projection,
                selection,
                args,
                null,
            ).use { cursor ->
                if (cursor == null) {
                    throw CalendarSyncException(
                        CalendarSyncErrors.PROVIDER_UNAVAILABLE,
                        "calendar provider unavailable",
                    )
                }
                var scanned = 0
                while (cursor.moveToNext()) {
                    if (scanned >= CalendarSyncContract.MAX_SCAN_MARKER_ROWS) {
                        truncated = true
                        break
                    }
                    scanned++
                    val eventId = cursor.getLong(0)
                    val opaqueId = CalendarSyncContract.opaqueIdFromUri(cursor.getString(1))
                    if (eventId <= 0L || opaqueId == null) {
                        invalid = true
                        continue
                    }
                    if (!seenPairs.add("$opaqueId#$eventId")) {
                        invalid = true
                        continue
                    }
                    events += mapOf("opaqueId" to opaqueId, "eventId" to eventId)
                }
            }
        } catch (error: SecurityException) {
            Log.w(TAG, "scan denied: ${error.javaClass.simpleName}")
            return ownedEventScanResult(
                emptyList(),
                complete = false,
                reason = CalendarOwnedScanReasons.PERMISSION_DENIED,
            )
        } catch (error: Exception) {
            Log.w(TAG, "scan failed: ${error.javaClass.simpleName}")
            return ownedEventScanResult(
                emptyList(),
                complete = false,
                reason = CalendarOwnedScanReasons.UNAVAILABLE,
            )
        }

        val reason: String? = when {
            truncated -> CalendarOwnedScanReasons.SCAN_LIMIT
            invalid -> CalendarOwnedScanReasons.UNAVAILABLE
            else -> null
        }
        return ownedEventScanResult(events, reason == null, reason)
    }

    private fun ownedEventScanResult(
        events: List<Map<String, Any?>>,
        complete: Boolean,
        reason: String?,
    ): Map<String, Any?> = mapOf(
        "events" to events,
        "complete" to complete,
        "reason" to reason,
    )

    private fun discoveryResult(
        calendars: List<Map<String, Any?>>,
        complete: Boolean,
        reason: String?,
    ): Map<String, Any?> = mapOf(
        "calendars" to calendars,
        "complete" to complete,
        "reason" to reason,
    )

    private data class CalendarMetadata(val displayName: String?, val writable: Boolean?)

    /**
     * 只按命中 id 读取日历展示名与可写性；projection 只含
     * `_ID + CALENDAR_DISPLAY_NAME + CALENDAR_ACCESS_LEVEL`，绝不读账号 / owner。
     * 访问级别为 null 时 `writable` 记为未知（null），由调用方保守处理。
     */
    private fun queryCalendarMetadata(ids: Set<Long>): Map<Long, CalendarMetadata> {
        val idList = ids.toList()
        val placeholders = idList.joinToString(",") { "?" }
        val projection = arrayOf(
            CalendarContract.Calendars._ID,
            CalendarContract.Calendars.CALENDAR_DISPLAY_NAME,
            CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL,
        )
        val result = HashMap<Long, CalendarMetadata>()
        resolver.query(
            CalendarContract.Calendars.CONTENT_URI,
            projection,
            "${CalendarContract.Calendars._ID} IN ($placeholders)",
            idList.map { it.toString() }.toTypedArray(),
            null,
        ).use { cursor ->
            if (cursor == null) {
                throw CalendarSyncException(
                    CalendarSyncErrors.PROVIDER_UNAVAILABLE,
                    "calendar provider unavailable",
                )
            }
            while (cursor.moveToNext()) {
                val id = cursor.getLong(0)
                if (id <= 0L) continue
                val displayName = CalendarSyncContract.sanitizeDisplayName(cursor.getString(1))
                val accessLevel = if (cursor.isNull(2)) null else cursor.getInt(2)
                val writable = accessLevel?.let {
                    it >= CalendarContract.Calendars.CAL_ACCESS_CONTRIBUTOR
                }
                result[id] = CalendarMetadata(displayName, writable)
            }
        }
        return result
    }

    /**
     * 批内 upsert：已有 → 带 owner/calendar/URI selection 的 UPDATE；否则 INSERT；
     * 事件写入与提醒写入放在同一个不 yield 的 `applyBatch`，任一步失败整体抛错。
     *
     * UPDATE 用 `withExpectedCount(1)`：执行时 0 行（被移走/删除）或 >1 行都会让整批事务
     * 回滚，避免误改；UPDATE 先于 reminder 增删，确保只在事件确认归属后才动它的提醒。
     * 同批出现重复 opaqueId 直接拒绝，native 侧再兜一层防止双插。
     */
    fun upsertEventBatch(
        calendarId: Long,
        events: List<CalendarEventInput>,
    ): Map<String, Any?> {
        val opaqueIds = events.map { it.opaqueId }
        if (opaqueIds.toSet().size != opaqueIds.size) {
            throw CalendarSyncException(
                CalendarSyncErrors.INVALID_ARGS,
                "duplicate opaqueId in batch",
            )
        }

        val operations = mutableListOf<ContentProviderOperation>()
        val planned = mutableListOf<PlannedEvent>()

        for (event in events) {
            val uri = CalendarSyncContract.eventUri(event.opaqueId)
            val existing = findEventByUri(uri)
            val values = eventContentValues(calendarId, event)

            if (existing == null) {
                operations += ContentProviderOperation.newInsert(CalendarContract.Events.CONTENT_URI)
                    .withValues(values)
                    .build()
                val eventOpIndex = operations.size - 1
                operations += reminderInsertOperation(event.reminderMinutes)
                    .withValueBackReference(CalendarContract.Reminders.EVENT_ID, eventOpIndex)
                    .build()
                planned += PlannedEvent(event, existingEventId = null, eventOpIndex = eventOpIndex)
            } else {
                val (existingEventId, existingCalendarId) = existing
                if (existingCalendarId != calendarId) {
                    // 同一 opaqueId 已落在别的 calendar，拒绝重复插入。
                    throw CalendarSyncException(
                        CalendarSyncErrors.OWNERSHIP_CONFLICT,
                        "owned event exists in another calendar",
                    )
                }
                // 1) 先按 owner 四元组 UPDATE 事件，expectedCount=1 令 0/多行整批回滚。
                operations += ContentProviderOperation.newUpdate(CalendarContract.Events.CONTENT_URI)
                    .withValues(values)
                    .withSelection(EVENT_OWNER_SELECTION, ownerArgs(existingEventId, calendarId, uri))
                    .withExpectedCount(1)
                    .build()
                val eventOpIndex = operations.size - 1
                // 2) 再删除该自有事件的全部旧提醒（按 EVENT_ID，不限定 METHOD，避免遗留重复）。
                operations += ContentProviderOperation.newDelete(CalendarContract.Reminders.CONTENT_URI)
                    .withSelection(
                        "${CalendarContract.Reminders.EVENT_ID} = ?",
                        arrayOf(existingEventId.toString()),
                    )
                    .build()
                // 3) 最后插入新的提醒。
                operations += reminderInsertOperation(event.reminderMinutes)
                    .withValue(CalendarContract.Reminders.EVENT_ID, existingEventId)
                    .build()
                planned += PlannedEvent(event, existingEventId, eventOpIndex)
            }
        }

        val results = applyBatch(operations)

        var insertedCount = 0
        var updatedCount = 0
        val eventIds = mutableMapOf<String, Any?>()
        for (item in planned) {
            val eventId: Long = item.existingEventId
                ?: insertedIdFrom(results.getOrNull(item.eventOpIndex))
            if (eventId <= 0L) {
                throw CalendarSyncException(
                    CalendarSyncErrors.BATCH_FAILED,
                    "event write returned no id",
                )
            }
            if (item.existingEventId == null) insertedCount++ else updatedCount++
            eventIds[item.input.opaqueId] = eventId
        }

        return mapOf(
            "insertedCount" to insertedCount,
            "updatedCount" to updatedCount,
            "eventIds" to eventIds,
        )
    }

    /**
     * 删除自有事件：每条 DELETE 的执行 selection 同时限定
     * `_id + calendar_id + custom_app_package + custom_app_uri`；0 行按 notDeleted 返回，
     * 不谎称成功，也绝不触碰日历行或其他事件。
     *
     * 仅前台单写者，selection 在执行时重新匹配；不做跨进程强一致承诺（用户可能在
     * 系统日历中同步改动），故 0 行只报告、留给下一次复核，不重试、不报成功。
     */
    fun deleteOwnedEventsByIds(
        calendarId: Long,
        items: List<Pair<String, Long>>,
    ): Map<String, Any?> {
        val operations = items.map { (opaqueId, eventId) ->
            ContentProviderOperation.newDelete(CalendarContract.Events.CONTENT_URI)
                .withSelection(
                    EVENT_OWNER_SELECTION,
                    ownerArgs(eventId, calendarId, CalendarSyncContract.eventUri(opaqueId)),
                )
                .build()
        }

        val results = applyBatch(operations)
        val deletedIds = mutableListOf<Long>()
        val notDeletedIds = mutableListOf<Long>()
        items.forEachIndexed { index, (_, eventId) ->
            val affected = results.getOrNull(index)?.count ?: 0
            if (affected > 0) deletedIds += eventId else notDeletedIds += eventId
        }

        return mapOf(
            "deletedIds" to deletedIds,
            "notDeletedIds" to notDeletedIds,
        )
    }

    /** provider 内同 URI 的已有事件（跨全部 calendar）；重复即冲突。 */
    private fun findEventByUri(uri: String): Pair<Long, Long>? {
        val projection = arrayOf(
            CalendarContract.Events._ID,
            CalendarContract.Events.CALENDAR_ID,
        )
        var existing: Pair<Long, Long>? = null
        resolver.query(
            CalendarContract.Events.CONTENT_URI,
            projection,
            "${CalendarContract.Events.CUSTOM_APP_PACKAGE} = ? AND " +
                "${CalendarContract.Events.CUSTOM_APP_URI} = ?",
            arrayOf(packageName, uri),
            null,
        ).use { cursor ->
            if (cursor == null) {
                throw CalendarSyncException(
                    CalendarSyncErrors.PROVIDER_UNAVAILABLE,
                    "calendar provider unavailable",
                )
            }
            val count = cursor.count
            if (count > 1) {
                throw CalendarSyncException(
                    CalendarSyncErrors.OWNERSHIP_CONFLICT,
                    "duplicate owned events for one opaque id",
                )
            }
            if (count == 1) {
                cursor.moveToFirst()
                existing = Pair(cursor.getLong(0), cursor.getLong(1))
            }
        }
        return existing
    }

    private fun eventContentValues(calendarId: Long, event: CalendarEventInput): ContentValues =
        ContentValues().apply {
            put(CalendarContract.Events.CALENDAR_ID, calendarId)
            put(CalendarContract.Events.TITLE, event.title)
            put(CalendarContract.Events.EVENT_LOCATION, event.location)
            put(CalendarContract.Events.DTSTART, event.startMillis)
            put(CalendarContract.Events.DTEND, event.endMillis)
            put(CalendarContract.Events.ALL_DAY, 0)
            put(CalendarContract.Events.EVENT_TIMEZONE, event.timeZone)
            put(CalendarContract.Events.CUSTOM_APP_PACKAGE, packageName)
            put(CalendarContract.Events.CUSTOM_APP_URI, CalendarSyncContract.eventUri(event.opaqueId))
        }

    private fun reminderInsertOperation(minutes: Int): ContentProviderOperation.Builder =
        ContentProviderOperation.newInsert(CalendarContract.Reminders.CONTENT_URI)
            .withValue(CalendarContract.Reminders.MINUTES, minutes)
            .withValue(CalendarContract.Reminders.METHOD, CalendarContract.Reminders.METHOD_ALERT)

    private fun ownerArgs(eventId: Long, calendarId: Long, uri: String): Array<String> =
        arrayOf(eventId.toString(), calendarId.toString(), packageName, uri)

    private fun insertedIdFrom(result: ContentProviderResult?): Long {
        val uri = result?.uri ?: return -1L
        return try {
            ContentUris.parseId(uri)
        } catch (_: NumberFormatException) {
            -1L
        } catch (_: UnsupportedOperationException) {
            -1L
        }
    }

    /** 不 yield 的单事务批量；任何失败整体抛出，绝不部分报成功。 */
    private fun applyBatch(
        operations: List<ContentProviderOperation>,
    ): Array<ContentProviderResult> {
        if (operations.isEmpty()) return emptyArray()
        return try {
            resolver.applyBatch(CalendarContract.AUTHORITY, ArrayList(operations))
        } catch (error: CalendarSyncException) {
            throw error
        } catch (error: Exception) {
            Log.w(TAG, "calendar batch failed: ${error.javaClass.simpleName}")
            throw CalendarSyncException(
                CalendarSyncErrors.BATCH_FAILED,
                "calendar provider batch failed",
            )
        }
    }

    private data class PlannedEvent(
        val input: CalendarEventInput,
        val existingEventId: Long?,
        val eventOpIndex: Int,
    )
}
