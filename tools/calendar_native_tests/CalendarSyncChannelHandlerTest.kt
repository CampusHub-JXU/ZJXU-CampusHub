package edu.zjxu.jxucampushub.platform.calendar

import android.app.Activity
import io.flutter.plugin.common.FakeBinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

private class CapturedResult : MethodChannel.Result {
    val done = CountDownLatch(1)
    @Volatile var value: Any? = null
    @Volatile var code: String? = null
    @Volatile var message: String? = null
    @Volatile var callbacks = 0
    override fun success(result: Any?) { value = result; callbacks++; done.countDown() }
    override fun error(code: String, message: String?, details: Any?) {
        this.code = code; this.message = message; callbacks++; done.countDown()
    }
    override fun notImplemented() { code = "not_implemented"; callbacks++; done.countDown() }
    fun await() { check(done.await(5, TimeUnit.SECONDS)) { "method result timed out" } }
}

fun main() {
    val activity = Activity()
    val messenger = FakeBinaryMessenger()
    val handler = CalendarSyncChannelHandler(activity)
    handler.register(messenger)
    check(messenger.channel.name == CalendarSyncContract.CHANNEL)
    check(messenger.channel.codec === io.flutter.plugin.common.StandardMethodCodec.INSTANCE)
    check(messenger.queue.serial) { "provider task queue must be serial" }

    // Provider work runs on the serial queue and a second provider operation cannot overlap it.
    CalendarProviderStore.invocations.clear()
    val entered = CountDownLatch(1)
    val release = CountDownLatch(1)
    CalendarProviderStore.blockFirstQuery = { entered.countDown(); check(release.await(5, TimeUnit.SECONDS)) }
    val query = CapturedResult()
    messenger.channel.invoke(MethodCall("queryOwnedEvents", mapOf("calendarId" to 7L)), query)
    check(entered.await(5, TimeUnit.SECONDS))
    val list = CapturedResult()
    messenger.channel.invoke(MethodCall("listWritableCalendars"), list)
    Thread.sleep(80)
    check(CalendarProviderStore.invocations.size == 1) { "second provider call overlapped first" }
    release.countDown()
    query.await(); list.await()
    check(CalendarProviderStore.invocations.map { it.first } == listOf("query", "list"))
    check(CalendarProviderStore.invocations.all { it.second == "flutter-calendar-queue" })
    CalendarProviderStore.blockFirstQuery = null

    // Permission dialog handoff happens on UI; a synchronous callback is safe and replies once.
    activity.granted = false
    var permissionCallbackCount = 0
    handler.onRequestPermissionsResult(0x7A1C, intArrayOf(0, 0))
    activity.onPermissionRequest = { _, requestCode ->
        check(Thread.currentThread().name == "android-main-test")
        check(requestCode == 0x7A1C)
        activity.granted = true
        permissionCallbackCount++
        handler.onRequestPermissionsResult(requestCode, intArrayOf(0, 0))
    }
    val permission = CapturedResult()
    messenger.channel.invoke(MethodCall("requestPermissions"), permission)
    permission.await()
    check(activity.requestPermissionsThread == "android-main-test")
    check(permission.value == true && permission.callbacks == 1)
    handler.onRequestPermissionsResult(0x7A1C, intArrayOf(0, 0))
    check(permission.callbacks == 1 && permissionCallbackCount == 1)

    // Validation and provider failures retain the established safe wire mapping.
    val invalid = CapturedResult()
    messenger.channel.invoke(MethodCall("scanOwnedEvents", mapOf("calendarId" to 0L)), invalid)
    invalid.await()
    check(invalid.code == CalendarSyncErrors.INVALID_ARGS)

    activity.granted = false
    val denied = CapturedResult()
    messenger.channel.invoke(MethodCall("listWritableCalendars"), denied)
    denied.await()
    check(denied.code == CalendarSyncErrors.PERMISSION_DENIED)
    activity.granted = true

    CalendarProviderStore.failList = true
    val failed = CapturedResult()
    messenger.channel.invoke(MethodCall("listWritableCalendars"), failed)
    failed.await()
    check(failed.code == CalendarSyncErrors.PROVIDER_UNAVAILABLE)
    check(failed.message == "calendar operation failed")
    CalendarProviderStore.failList = false

    messenger.queue.close()
    activity.close()
    println("CalendarSyncChannelHandler host tests passed")
}
