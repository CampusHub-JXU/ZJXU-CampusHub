package android.app

open class Activity : android.content.Context() {
    val isFinishing = false
    val isDestroyed = false
    fun startActivity(intent: android.content.Intent) {}
}
