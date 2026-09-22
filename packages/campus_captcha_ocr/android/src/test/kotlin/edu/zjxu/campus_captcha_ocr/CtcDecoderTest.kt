package edu.zjxu.campus_captcha_ocr

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * [CtcDecoder] 固定向量单测：折叠/去 blank、空白帧、字母数字后置过滤（只删不重排）、
 * 以及长度行为（原生不做长度门，长度校验在 Dart 门面）。
 */
class CtcDecoderTest {

    // 索引：0=blank, 1='A', 2='b', 3='2', 4='掀', 5='-', 6='Z'
    private val charset = charArrayOf('\u0000', 'A', 'b', '2', '掀', '-', 'Z')

    /** 构造只有指定索引为 1.0、其余为 0.0 的帧，保证 argmax 确定。 */
    private fun frame(at: Int, classes: Int = 7): FloatArray =
        FloatArray(classes).also { it[at] = 1.0f }

    @Test
    fun argmaxPerFrame_picksHighestPerFrame() {
        val logits = arrayOf(floatArrayOf(0.1f, 0.9f, 0.2f), floatArrayOf(0.8f, 0.1f, 0.3f))
        val picked = CtcDecoder.argmaxPerFrame(logits)
        assertEquals(listOf(1, 0), picked.toList())
    }

    @Test
    fun collapse_dropsConsecutiveDuplicatesAndBlank() {
        // A A blank A 掀 掀 - → A, A, 掀, -
        val frames = intArrayOf(1, 1, 0, 1, 4, 4, 5)
        assertEquals(listOf(1, 1, 4, 5), CtcDecoder.collapse(frames))
    }

    @Test
    fun collapse_keepsNonConsecutiveRepeatsAcrossBlank() {
        // CTC 允许 c, blank, c 产生两个 c（标准行为，不是 bug）
        val frames = intArrayOf(1, 0, 1)
        assertEquals(listOf(1, 1), CtcDecoder.collapse(frames))
    }

    @Test
    fun collapse_dropsBlankFrames() {
        val frames = intArrayOf(0, 0, 3, 0, 0)
        assertEquals(listOf(3), CtcDecoder.collapse(frames))
    }

    @Test
    fun mapAsciiAlnum_deletesNonAlnumAndShortensOutput() {
        // 掀 和 - 被删除（只删，不改写），大小写保留
        assertEquals("AZ", CtcDecoder.mapAsciiAlnum(listOf(1, 4, 5, 6), charset))
        assertEquals("Ab2", CtcDecoder.mapAsciiAlnum(listOf(1, 2, 3), charset))
    }

    @Test
    fun mapAsciiAlnum_ignoresBlankOutOfRangeIndices() {
        assertEquals("A", CtcDecoder.mapAsciiAlnum(listOf(0, 1, 99, -1), charset))
    }

    @Test
    fun decode_endToEnd_fixedVector() {
        // blank A A 掀 - b Z Z → 折叠 → A 掀 - b Z → 过滤 → "AbZ"
        val logits =
            arrayOf(
                frame(0),
                frame(1),
                frame(1),
                frame(4),
                frame(5),
                frame(2),
                frame(6),
                frame(6),
            )
        assertEquals("AbZ", CtcDecoder.decode(logits, charset))
    }

    @Test
    fun decode_doesNotGateLengthNative() {
        // 原生只做解码+过滤，不做 4/6 位长度门：5 位原样返回，由 Dart 门面裁剪。
        val logits = arrayOf(frame(1), frame(2), frame(3), frame(6), frame(4))
        assertEquals("Ab2Z", CtcDecoder.decode(logits, charset))
    }

    @Test
    fun decode_allBlankYieldsEmptyString() {
        val logits = arrayOf(frame(0), frame(0), frame(0))
        assertEquals("", CtcDecoder.decode(logits, charset))
    }

    @Test
    fun meanMaxSoftmax_uniformRowsEqualReciprocalOfClasses() {
        val logits = arrayOf(FloatArray(7), FloatArray(7))
        assertEquals(1.0 / 7.0, CtcDecoder.meanMaxSoftmax(logits), 1e-9)
    }

    @Test
    fun meanMaxSoftmax_includesBlankFrames() {
        val classes = 7
        val sorted = frame(1, classes)
        val blank = FloatArray(classes)
        val expected = (1.0 / (1.0 + (classes - 1) * Math.exp(-1.0)) + 1.0 / classes) / 2.0
        assertEquals(expected, CtcDecoder.meanMaxSoftmax(arrayOf(sorted, blank)), 1e-9)
    }

    @Test
    fun meanMaxSoftmax_emptyLogitsIsZero() {
        assertEquals(0.0, CtcDecoder.meanMaxSoftmax(emptyArray()), 0.0)
    }
}
