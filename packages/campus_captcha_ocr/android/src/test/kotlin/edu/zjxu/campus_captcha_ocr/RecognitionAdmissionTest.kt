package edu.zjxu.campus_captcha_ocr

import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [RecognitionAdmission] 单测（纯 JVM）：busy 拒绝、槽位释放、迟到释放不清新请求、
 * detach 失活、以及「一次回复 / 迟到不回调」的认领语义。
 *
 * Android 侧真正的 `RejectedExecutionException` 提交路径与 `MethodChannel.Result`
 * 回调不在此覆盖（见交付说明的运行覆盖缺口）。
 */
class RecognitionAdmissionTest {

    @Test
    fun tryAcquire_firstCallSucceedsAndSecondIsBusy() {
        val admission = RecognitionAdmission()
        val first = admission.tryAcquire()
        assertTrue(first != null)
        assertTrue(admission.hasActiveRequest)
        assertNull(admission.tryAcquire()) // 已有在途请求 → busy，不排队
    }

    @Test
    fun release_allowsNextAcquire() {
        val admission = RecognitionAdmission()
        val first = admission.tryAcquire()!!
        admission.release(first)
        assertFalse(admission.hasActiveRequest)
        val second = admission.tryAcquire()
        assertTrue(second != null)
    }

    @Test
    fun release_staleRequestDoesNotClearNewRequest() {
        val admission = RecognitionAdmission()
        val stale = admission.tryAcquire()!!
        admission.release(stale)
        val current = admission.tryAcquire()!!
        admission.release(stale) // 迟到释放：不得清掉新请求
        assertTrue(admission.hasActiveRequest)
        assertNull(admission.tryAcquire())
        admission.release(current)
        assertTrue(admission.tryAcquire() != null)
    }

    @Test
    fun deactivateCurrent_clearsSlotAndMarksRequestInactive() {
        val admission = RecognitionAdmission()
        val request = admission.tryAcquire()!!
        val deactivated = admission.deactivateCurrent()
        assertSame(request, deactivated)
        assertFalse(request.isActive)
        assertFalse(admission.hasActiveRequest)
        assertNull(admission.deactivateCurrent()) // 空闲时返回 null
    }

    @Test
    fun tryAcquire_afterDeactivateSucceeds() {
        val admission = RecognitionAdmission()
        admission.tryAcquire()
        admission.deactivateCurrent()
        assertTrue(admission.tryAcquire() != null)
    }

    @Test
    fun request_isActiveByDefault() {
        val admission = RecognitionAdmission()
        assertTrue(admission.tryAcquire()!!.isActive)
    }

    @Test
    fun claimReply_firstCallWinsAndLaterCallsAreRejected() {
        val admission = RecognitionAdmission()
        val request = admission.tryAcquire()!!
        assertTrue(request.claimReply(detached = false))
        assertFalse(request.claimReply(detached = false)) // 每次调用最多回复一次
    }

    @Test
    fun claimReply_rejectsInactiveRequestAndConsumesToken() {
        val admission = RecognitionAdmission()
        val request = admission.tryAcquire()!!
        admission.deactivateCurrent()
        assertFalse(request.claimReply(detached = false))
        assertFalse(request.claimReply(detached = false))
    }

    @Test
    fun claimReply_rejectsWhenDetached() {
        val admission = RecognitionAdmission()
        val request = admission.tryAcquire()!!
        assertFalse(request.claimReply(detached = true)) // detach 后迟到结果不回调
        assertFalse(request.claimReply(detached = false)) // 且不会在 re-attach 后补回调
    }

    @Test
    fun claimReply_survivesReleaseAsIndependentState() {
        // 释放槽位不等于已回复：占用者仍可认领一次（对应 complete/fail 的调用顺序）。
        val admission = RecognitionAdmission()
        val request = admission.tryAcquire()!!
        admission.release(request)
        assertTrue(request.claimReply(detached = false))
    }
}
