package android.net

import java.net.URI
import java.io.File

class Uri private constructor(private val value: String) {
    private val uri = URI(value)
    val scheme get() = uri.scheme
    val userInfo get() = uri.userInfo
    val port get() = uri.port
    val fragment get() = uri.fragment
    val query get() = uri.query
    val host get() = uri.host
    val pathSegments get() = uri.path.split('/').filter { it.isNotEmpty() }
    override fun toString() = value
    companion object {
        fun parse(value: String) = Uri(value)
        fun fromFile(file: File) = Uri(file.toURI().toString())
    }
}
