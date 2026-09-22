package edu.zjxu.campus_captcha_ocr

/**
 * 尺寸预算（纯 Kotlin，无 Android 依赖 → 可在 JVM 单测，见 `OcrSizeBudgetTest`）。
 *
 * 目的：在 `BitmapFactory` 解码与预处理分配**之前**判定一张验证码图是否在处理预算内，
 * 避免「通过 2M 像素门但宽高比极端」的图把归一化宽度 / 中间缓冲 / 输出张量放大到 OOM。
 *
 * 规则（列表顺序即判定优先级，全部先用 Long 计算，转 Int 前必须已确认上界）：
 * 1. 宽高必须为正；
 * 2. 源像素 `W * H <= [MAX_SOURCE_PIXELS]`；
 * 3. 归一化宽度 `W' = max(1, W * 64 / H) <= [MAX_NORMALIZED_WIDTH]`；超界**直接拒绝**，
 *    不做扭曲缩放（4/6 位校园验证码远低于此值）；
 * 4. 横向中间缓冲 `W' * H <= [MAX_INTERMEDIATE_PIXELS]`（防御性复核，见下）。
 *
 * 数值边界如实记录，不暗改规则：
 * - `1 x 2_000_000`：源像素恰为 2M、`W' = 1`、中间像素恰为 2_000_000，**允许通过**
 *   （等于上界不算超界）。极端宽高比的合法性由规则 3 / 4 承担，不靠单独的面积规则。
 * - 规则 4 在规则 2 + 3 成立时不可达：`W' <= 1024` 且 `W * H <= 2M` 蕴含
 *   `W <= 1025H/64`，于是 `W' * H <= 64W <= 362_230 << 2M`；`W' = 1` 的退化分支
 *   （`W * 64 / H == 0`）则 `W' * H = H <= W * H <= 2M`。保留该规则作为防御性上界，
 *   其算术由 [exceedsIntermediateBudget] 单独单测覆盖。
 * - 未设单独的源边长上界（`MAX_SOURCE_DIMENSION`）：规则 2 已把解码 + 灰度内存
 *   限制在 ~24MB 内，而唯一「单边极大」的可通过形态是 `W = 1, H <= 2M`（工作量线性有界）；
 *   平台无法解码的超大单边会走 `decode_failed` 而不是崩溃。
 */
internal object OcrSizeBudget {

    /** ddddocr 归一化目标高度。 */
    const val TARGET_HEIGHT = 64

    /** 源图像素上界（与插件 `MAX_INPUT_PIXELS` 原值一致）。 */
    const val MAX_SOURCE_PIXELS: Long = 2_000_000L

    /** 归一化宽度 `W'` 上界；超过即拒绝，不缩放。 */
    const val MAX_NORMALIZED_WIDTH = 1024

    /** 横向 resize 中间缓冲像素上界。 */
    const val MAX_INTERMEDIATE_PIXELS: Long = 2_000_000L

    /** 最终 `(1,1,64,W')` 张量元素数上界 = [MAX_NORMALIZED_WIDTH] * [TARGET_HEIGHT]。 */
    const val MAX_TENSOR_PIXELS: Long = 1024L * 64L

    enum class Rejection {
        NON_POSITIVE_DIMENSIONS,
        SOURCE_PIXELS,
        NORMALIZED_WIDTH,
        INTERMEDIATE_PIXELS,
    }

    /** 判定结果；[allowed] 为 false 时 [targetWidth] 为 0 且 [rejection] 非空。 */
    data class Result(
        val allowed: Boolean,
        val targetWidth: Int,
        val sourcePixels: Long,
        val intermediatePixels: Long,
        val rejection: Rejection?,
    )

    /** `W * H`（Long，不溢出）。 */
    fun sourcePixels(sourceWidth: Int, sourceHeight: Int): Long =
        sourceWidth.toLong() * sourceHeight.toLong()

    /** `max(1, W * 64 / H)`；调用方须先确认宽高为正（否则返回值无意义）。 */
    fun normalizedWidth(sourceWidth: Int, sourceHeight: Int): Long {
        val scaled = sourceWidth.toLong() * TARGET_HEIGHT.toLong() / sourceHeight.toLong()
        return if (scaled < 1L) 1L else scaled
    }

    /** 规则 4 的算术本体：`W' * H > [MAX_INTERMEDIATE_PIXELS]`。 */
    fun exceedsIntermediateBudget(targetWidth: Int, sourceHeight: Int): Boolean =
        targetWidth.toLong() * sourceHeight.toLong() > MAX_INTERMEDIATE_PIXELS

    fun evaluate(sourceWidth: Int, sourceHeight: Int): Result {
        if (sourceWidth <= 0 || sourceHeight <= 0) {
            return Result(false, 0, 0L, 0L, Rejection.NON_POSITIVE_DIMENSIONS)
        }
        val pixels = sourcePixels(sourceWidth, sourceHeight)
        if (pixels > MAX_SOURCE_PIXELS) {
            return Result(false, 0, pixels, 0L, Rejection.SOURCE_PIXELS)
        }
        val targetWidth = normalizedWidth(sourceWidth, sourceHeight)
        if (targetWidth > MAX_NORMALIZED_WIDTH.toLong()) {
            return Result(false, 0, pixels, 0L, Rejection.NORMALIZED_WIDTH)
        }
        val intermediate = targetWidth * sourceHeight.toLong()
        if (exceedsIntermediateBudget(targetWidth.toInt(), sourceHeight)) {
            return Result(false, 0, pixels, intermediate, Rejection.INTERMEDIATE_PIXELS)
        }
        return Result(true, targetWidth.toInt(), pixels, intermediate, null)
    }
}

/**
 * 尺寸预算拒绝（[OcrSizeBudget]）。调用方必须映射为 `image_too_large`，
 * 且不得为此先解码位图或分配 tensor。
 */
internal class OcrSizeBudgetException(message: String) : IllegalArgumentException(message)
