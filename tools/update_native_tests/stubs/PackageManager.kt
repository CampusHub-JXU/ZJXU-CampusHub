package android.content.pm

class ApplicationInfo {
    companion object { const val FLAG_DEBUGGABLE = 2 }
    var flags = 0
}
class PackageInfo {
    var longVersionCode = 1L
    var versionCode = 1
    var versionName: String? = "0.1"
}
class PackageManager {
    var installsAllowed = false
    val installed = PackageInfo()
    var archive: PackageInfo? = PackageInfo().apply { longVersionCode = 100; versionName = "1.0" }
    fun canRequestPackageInstalls() = installsAllowed
    fun getPackageInfo(name: String, flags: Int) = installed
    fun getPackageArchiveInfo(path: String, flags: Int) = archive
}
