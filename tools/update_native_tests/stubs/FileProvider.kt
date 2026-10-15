package androidx.core.content
object FileProvider {
    fun getUriForFile(context: android.content.Context, authority: String, file: java.io.File) =
        android.net.Uri.fromFile(file)
}
