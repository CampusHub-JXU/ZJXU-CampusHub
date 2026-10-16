package android.app

open class Activity : android.content.Context() {
    var isFinishing = false
    var isDestroyed = false
    var launches = 0
    var launchAction: (() -> Unit)? = null
    fun startActivity(intent: android.content.Intent) { launchAction?.invoke(); launches++ }
}
