package android.app

import android.net.Uri
import android.content.Context
import java.io.Closeable
import java.io.File

class DownloadManager {
    companion object {
        const val ACTION_DOWNLOAD_COMPLETE = "download_complete"
        const val EXTRA_DOWNLOAD_ID = "download_id"
        const val COLUMN_ID = "id"
        const val COLUMN_URI = "uri"
        const val COLUMN_LOCAL_URI = "local"
        const val COLUMN_STATUS = "status"
        const val COLUMN_BYTES_DOWNLOADED_SO_FAR = "bytes"
        const val COLUMN_TOTAL_SIZE_BYTES = "total"
        const val COLUMN_REASON = "reason"
        const val STATUS_PENDING = 1
        const val STATUS_RUNNING = 2
        const val STATUS_PAUSED = 4
        const val STATUS_SUCCESSFUL = 8
        const val STATUS_FAILED = 16
        const val ERROR_INSUFFICIENT_SPACE = 1006
        const val ERROR_HTTP_DATA_ERROR = 1004
        const val ERROR_UNHANDLED_HTTP_CODE = 1002
        const val ERROR_TOO_MANY_REDIRECTS = 1005
    }
    class Query { var id: Long? = null; fun setFilterById(id: Long) = apply { this.id = id } }
    class Request(val uri: Uri) {
        companion object { const val VISIBILITY_VISIBLE = 0 }
        var destination = ""
        fun setTitle(v: String) {}
        fun setDescription(v: String) {}
        fun setMimeType(v: String) {}
        fun setNotificationVisibility(v: Int) {}
        fun setDestinationInExternalFilesDir(c: Context, t: String, path: String) {
            destination = File(c.getExternalFilesDir(t), path).toURI().toString().replaceFirst("file:/", "file:///")
        }
        fun setDestinationUri(uri: Uri) { destination = uri.toString() }
        fun setAllowedOverMetered(v: Boolean) {}
        fun setAllowedOverRoaming(v: Boolean) {}
    }
    data class Row(val id: Long, val url: String, val local: String,
        var status: Int = STATUS_PENDING, var reason: Int = 0)
    val rows = linkedMapOf<Long, Row>()
    var enqueues = 0
    var throwQuery = false
    var nullCursor = false
    var removeFails = false
    var throwEnqueue = false
    var afterEnqueue: (() -> Unit)? = null
    fun enqueue(request: Request): Long {
        check(!throwEnqueue)
        val id = (++enqueues).toLong()
        rows[id] = Row(id, request.uri.toString(), request.destination)
        afterEnqueue?.invoke()
        return id
    }
    fun remove(id: Long) { if (removeFails) error("remove failed"); rows.remove(id) }
    fun query(query: Query): Cursor? {
        if (throwQuery) error("query unavailable")
        if (nullCursor) return null
        return Cursor(rows.values.filter { query.id == null || query.id == it.id })
    }
    class Cursor(private val rows: List<Row>) : Closeable {
        private var index = -1
        private val columns = listOf(COLUMN_ID, COLUMN_URI, COLUMN_LOCAL_URI, COLUMN_STATUS,
            COLUMN_BYTES_DOWNLOADED_SO_FAR, COLUMN_TOTAL_SIZE_BYTES, COLUMN_REASON)
        fun moveToFirst(): Boolean { index = 0; return rows.isNotEmpty() }
        fun moveToNext(): Boolean { index++; return index < rows.size }
        fun getColumnIndex(name: String) = columns.indexOf(name)
        fun getColumnIndexOrThrow(name: String) = getColumnIndex(name).also { check(it >= 0) }
        fun getLong(column: Int): Long = if (column == 0) rows[index].id else 0L
        fun getInt(column: Int) = if (column == 3) rows[index].status else rows[index].reason
        fun getString(column: Int): String = if (column == 1) rows[index].url else rows[index].local
        override fun close() {}
    }
}
