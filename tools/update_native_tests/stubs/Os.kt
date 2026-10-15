package android.os

object Build {
    object VERSION { const val SDK_INT = 35 }
    object VERSION_CODES { const val O = 26; const val Q = 29 }
}
// 镜像 AOSP Environment.DIRECTORY_DOWNLOADS：字面量是**单数** "Download"
// （公共目录 Downloads 是另一回事）。桩里写成复数会让「FileProvider 白名单
// 与受管下载目录不一致」这类缺陷在宿主回归里无法复现。
object Environment { const val DIRECTORY_DOWNLOADS = "Download" }
class Looper { companion object { fun getMainLooper() = Looper() } }
class Handler(looper: Looper) { fun post(action: () -> Unit) { action() } }
