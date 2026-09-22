package edu.zjxu.campus_captcha_ocr

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [OcrSizeBudget] 数值边界单测（纯 JVM，不依赖 Android）。
 *
 * 断言的是**预算边界本身**（等于上界允许、超出上界拒绝），不是「先定结论再找例子」：
 * 例如 `1 x 2_000_000` 的源像素与中间像素都恰为 2M，按规则允许通过；而 `32767 x 61`
 * 源像素虽在 2M 内，却因归一化宽度超界被拒绝。
 */
class OcrSizeBudgetTest {

    private fun allowed(width: Int, height: Int): OcrSizeBudget.Result {
        val result = OcrSizeBudget.evaluate(width, height)
        assertTrue("expected ${width}x$height allowed, got ${result.rejection}", result.allowed)
        return result
    }

    private fun rejected(
        width: Int,
        height: Int,
        reason: OcrSizeBudget.Rejection,
    ): OcrSizeBudget.Result {
        val result = OcrSizeBudget.evaluate(width, height)
        assertFalse("expected ${width}x$height rejected", result.allowed)
        assertEquals(reason, result.rejection)
        assertEquals(0, result.targetWidth)
        return result
    }

    // ---- 正常 4/6 位校园验证码尺寸 ----

    @Test
    fun normalFourDigitSize_isAllowed() {
        val result = allowed(128, 64)
        assertEquals(128, result.targetWidth)
        assertEquals(8192L, result.sourcePixels)
        assertEquals(8192L, result.intermediatePixels)
    }

    @Test
    fun normalSixDigitSize_isAllowed() {
        val result = allowed(250, 60)
        assertEquals(266, result.targetWidth) // floor(250 * 64 / 60)
        assertEquals(15000L, result.sourcePixels)
        assertEquals(15960L, result.intermediatePixels)
    }

    @Test
    fun typicalCaptchaSize_isAllowed() {
        val result = allowed(150, 50)
        assertEquals(192, result.targetWidth) // floor(150 * 64 / 50)
        assertEquals(7500L, result.sourcePixels)
        assertEquals(9600L, result.intermediatePixels)
    }

    @Test
    fun squareSize_isAllowed() {
        val result = allowed(64, 64)
        assertEquals(64, result.targetWidth)
        assertEquals(4096L, result.sourcePixels)
        assertEquals(4096L, result.intermediatePixels)
    }

    // ---- 极宽：源像素通过但归一化宽度超界 ----

    @Test
    fun extremelyWide32767x61_isRejectedByNormalizedWidth() {
        val result = rejected(32767, 61, OcrSizeBudget.Rejection.NORMALIZED_WIDTH)
        // 源像素确实在 2M 预算内（说明单靠面积门不够），targetWidth = floor(32767*64/61) = 34378。
        assertEquals(1_998_787L, result.sourcePixels)
        assertEquals(34_378L, OcrSizeBudget.normalizedWidth(32767, 61))
    }

    @Test
    fun extremelyWide2000000x1_isRejectedByNormalizedWidth() {
        val result = rejected(2_000_000, 1, OcrSizeBudget.Rejection.NORMALIZED_WIDTH)
        assertEquals(2_000_000L, result.sourcePixels) // 恰为源像素上界，仍允许
        assertEquals(128_000_000L, OcrSizeBudget.normalizedWidth(2_000_000, 1)) // Long，不溢出 Int
    }

    // ---- 极高：源像素上界与中间像素边界（1 x 2_000_000 允许） ----

    @Test
    fun extremelyTall1x2000000_isAllowedAtExactBoundaries() {
        val result = allowed(1, 2_000_000)
        assertEquals(1, result.targetWidth) // floor(1 * 64 / 2_000_000) == 0 → 至少 1 列
        assertEquals(OcrSizeBudget.MAX_SOURCE_PIXELS, result.sourcePixels)
        assertEquals(OcrSizeBudget.MAX_INTERMEDIATE_PIXELS, result.intermediatePixels)
    }

    @Test
    fun extremelyTall1x2000001_isRejectedBySourcePixels() {
        rejected(1, 2_000_001, OcrSizeBudget.Rejection.SOURCE_PIXELS)
    }

    @Test
    fun extremeNarrow61x32767_isAllowedBecauseIntermediateStaysBounded() {
        val result = allowed(61, 32767)
        assertEquals(1, result.targetWidth)
        assertEquals(1_998_787L, result.sourcePixels)
        assertEquals(32_767L, result.intermediatePixels)
    }

    // ---- 归一化宽度边界 1024 / 1025 ----

    @Test
    fun normalizedWidthExactly1024_isAllowed() {
        // 5120 * 64 / 320 == 1024（精确）；源像素 1_638_400 ≤ 2M，中间 327_680 ≤ 2M。
        val result = allowed(5120, 320)
        assertEquals(OcrSizeBudget.MAX_NORMALIZED_WIDTH, result.targetWidth)
        assertEquals(1_638_400L, result.sourcePixels)
        assertEquals(327_680L, result.intermediatePixels)
    }

    @Test
    fun normalizedWidth1025_isRejected() {
        // 5125 * 64 / 320 == 1025（精确）。
        rejected(5125, 320, OcrSizeBudget.Rejection.NORMALIZED_WIDTH)
    }

    @Test
    fun sourcePixelsExactlyAtLimit_isAllowed() {
        val result = allowed(2000, 1000)
        assertEquals(2_000_000L, result.sourcePixels)
        assertEquals(128, result.targetWidth)
        assertEquals(128_000L, result.intermediatePixels)
    }

    @Test
    fun sourcePixelsOneOverLimit_isRejected() {
        rejected(2_000_000, 2, OcrSizeBudget.Rejection.SOURCE_PIXELS)
    }

    // ---- 非正尺寸 ----

    @Test
    fun nonPositiveDimensions_areRejected() {
        val cases =
            listOf(
                0 to 64,
                64 to 0,
                0 to 0,
                -1 to 64,
                64 to -1,
                Int.MIN_VALUE to 64,
                64 to Int.MIN_VALUE,
            )
        for ((width, height) in cases) {
            val result = rejected(width, height, OcrSizeBudget.Rejection.NON_POSITIVE_DIMENSIONS)
            assertEquals(0L, result.sourcePixels)
            assertEquals(0L, result.intermediatePixels)
        }
    }

    // ---- Int 溢出 ----

    @Test
    fun intMaxDimensions_doNotOverflowLongMath() {
        val both = rejected(Int.MAX_VALUE, Int.MAX_VALUE, OcrSizeBudget.Rejection.SOURCE_PIXELS)
        assertEquals(Int.MAX_VALUE.toLong() * Int.MAX_VALUE.toLong(), both.sourcePixels)

        val wide = rejected(Int.MAX_VALUE, 1, OcrSizeBudget.Rejection.SOURCE_PIXELS)
        assertEquals(Int.MAX_VALUE.toLong(), wide.sourcePixels)
    }

    @Test
    fun normalizedWidthOfIntMax_usesLongMath() {
        assertEquals(Int.MAX_VALUE.toLong() * OcrSizeBudget.TARGET_HEIGHT, OcrSizeBudget.normalizedWidth(Int.MAX_VALUE, 1))
        assertEquals(1L, OcrSizeBudget.normalizedWidth(1, Int.MAX_VALUE))
    }

    // ---- 中间像素规则本体（防御性上界；evaluate 中先被规则 3 拦下） ----

    @Test
    fun intermediateBudgetArithmetic_rejectsAboveLimitOnly() {
        assertTrue(OcrSizeBudget.exceedsIntermediateBudget(34_378, 61)) // 2_097_058 > 2M
        assertTrue(OcrSizeBudget.exceedsIntermediateBudget(1024, 2000)) // 2_048_000 > 2M
        assertFalse(OcrSizeBudget.exceedsIntermediateBudget(1, 2_000_000)) // 恰为上界
        assertFalse(OcrSizeBudget.exceedsIntermediateBudget(1024, 1953)) // 1_999_872 ≤ 2M
        assertFalse(OcrSizeBudget.exceedsIntermediateBudget(0, 0))
    }

    // ---- 常量漂移守卫 + 全量不变量 ----

    @Test
    fun tensorPixelCeiling_matchesNormalizedWidthTimesTargetHeight() {
        assertEquals(
            OcrSizeBudget.MAX_NORMALIZED_WIDTH.toLong() * OcrSizeBudget.TARGET_HEIGHT,
            OcrSizeBudget.MAX_TENSOR_PIXELS,
        )
    }

    @Test
    fun allowedResults_neverExceedAnyBudget() {
        val widths = listOf(1, 2, 3, 7, 16, 61, 64, 100, 128, 255, 256, 1000, 1024, 2000, 5120, 32767, 2_000_000)
        val heights = listOf(1, 2, 7, 61, 64, 100, 320, 353, 1000, 1953, 32767, 2_000_000)
        for (width in widths) {
            for (height in heights) {
                val result = OcrSizeBudget.evaluate(width, height)
                if (!result.allowed) continue
                assertTrue(result.sourcePixels <= OcrSizeBudget.MAX_SOURCE_PIXELS)
                assertTrue(result.targetWidth in 1..OcrSizeBudget.MAX_NORMALIZED_WIDTH)
                assertTrue(result.intermediatePixels <= OcrSizeBudget.MAX_INTERMEDIATE_PIXELS)
                assertEquals(
                    result.targetWidth.toLong() * height.toLong(),
                    result.intermediatePixels,
                )
            }
        }
    }
}
