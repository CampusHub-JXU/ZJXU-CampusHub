package edu.zjxu.campus_captcha_ocr

import android.graphics.Bitmap
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * ddddocr 1.6.1 默认模型的图像预处理，对齐 `core/ocr_engine.py::_preprocess_image`：
 *
 * 1. resize：`target_height = 64`，`target_width = int(W * 64 / H)`，使用 Lanczos-3；
 * 2. 灰度：PIL `convert('L')` 的 ITU-R 601-2 luma（`299/587/114`）；
 * 3. 归一化：`float32 / 255.0`，**无 mean/std**；
 * 4. 维度：`(1, 1, 64, W')` CHW。
 *
 * 偏差说明（如实记录）：PIL 是「先对 RGB resize 再转 L」，本实现是「先转 L 再
 * resize」。Luma 与卷积都是线性运算，数学上等价，仅 8-bit 量化时机不同（最多
 * ±1 灰阶）。这是与 ddddocr 参考实现最接近而又不需要 3 通道中间缓冲的做法。
 *
 * 分配安全：进入本对象前必须已过 [OcrSizeBudget]（插件在 decode bounds 后先判）。
 * 本对象在**每次分配前**用同一预算复核（防御性），拒绝时抛 [OcrSizeBudgetException]，
 * 由调用方映射为 `image_too_large`；所有尺寸乘法先用 Long 并确认上界后才转 Int。
 * 预算内输入的数值结果与旧实现完全一致（同一 `W' = max(1, W * 64 / H)` 截断公式）。
 */
internal object DdddocrPreprocessor {

    const val TARGET_HEIGHT = OcrSizeBudget.TARGET_HEIGHT
    private const val LANCZOS_A = 3.0

    data class InputTensor(val buffer: FloatBuffer, val width: Int)

    /** 把解码后的位图转成 `(1,1,64,W')` 的 float32 CHW 输入张量。 */
    fun toInputTensor(bitmap: Bitmap): InputTensor {
        val sourceWidth = bitmap.width
        val sourceHeight = bitmap.height

        // 分配前复核预算（插件已在 decode 前判过一次；这里覆盖直接调用方与尺寸漂移）。
        val decision = OcrSizeBudget.evaluate(sourceWidth, sourceHeight)
        if (!decision.allowed) {
            throw OcrSizeBudgetException(
                "preprocessing rejected ${sourceWidth}x$sourceHeight " +
                    "(reason=${decision.rejection}, source=${decision.sourcePixels}px, " +
                    "intermediate=${decision.intermediatePixels}px)",
            )
        }
        val targetWidth = decision.targetWidth

        val grayscale = grayscale(bitmap)
        val horizontal = resizeHorizontal(grayscale, sourceWidth, sourceHeight, targetWidth)
        val resized = resizeVertical(horizontal, targetWidth, sourceHeight, TARGET_HEIGHT)

        // (1,1,64,W') float32：targetWidth <= MAX_NORMALIZED_WIDTH，故元素数有界。
        val tensorPixels = targetWidth.toLong() * TARGET_HEIGHT.toLong()
        check(tensorPixels <= OcrSizeBudget.MAX_TENSOR_PIXELS) {
            "tensor $tensorPixels pixels exceeds ${OcrSizeBudget.MAX_TENSOR_PIXELS}"
        }
        val byteCount = tensorPixels * 4L
        check(byteCount <= Int.MAX_VALUE.toLong()) { "tensor byte size $byteCount overflows Int" }

        val buffer =
            ByteBuffer.allocateDirect(byteCount.toInt())
                .order(ByteOrder.nativeOrder())
                .asFloatBuffer()
        for (value in resized) {
            buffer.put(value / 255f)
        }
        buffer.rewind()
        return InputTensor(buffer, targetWidth)
    }

    /** ARGB_8888 → 8-bit luma（PIL `convert('L')` 的 ITU-R 601-2 系数）。 */
    private fun grayscale(bitmap: Bitmap): IntArray {
        val width = bitmap.width
        val height = bitmap.height
        val pixelCount = width.toLong() * height.toLong()
        check(pixelCount <= OcrSizeBudget.MAX_SOURCE_PIXELS) {
            "source $pixelCount pixels exceeds ${OcrSizeBudget.MAX_SOURCE_PIXELS}"
        }
        val size = pixelCount.toInt()
        val pixels = IntArray(size)
        bitmap.getPixels(pixels, 0, width, 0, 0, width, height)
        val out = IntArray(pixels.size)
        for (index in pixels.indices) {
            val color = pixels[index]
            val red = (color shr 16) and 0xFF
            val green = (color shr 8) and 0xFF
            val blue = color and 0xFF
            out[index] =
                ((red * 299 + green * 587 + blue * 114) / 1000.0).roundToInt().coerceIn(0, 255)
        }
        return out
    }

    private fun resizeHorizontal(
        source: IntArray,
        sourceWidth: Int,
        sourceHeight: Int,
        targetWidth: Int,
    ): IntArray {
        if (targetWidth == sourceWidth) return source
        val intermediatePixels = targetWidth.toLong() * sourceHeight.toLong()
        check(intermediatePixels <= OcrSizeBudget.MAX_INTERMEDIATE_PIXELS) {
            "intermediate $intermediatePixels pixels exceeds ${OcrSizeBudget.MAX_INTERMEDIATE_PIXELS}"
        }
        val out = IntArray(intermediatePixels.toInt())
        val scale = sourceWidth.toDouble() / targetWidth
        val filterScale = if (scale < 1.0) 1.0 else scale
        val support = LANCZOS_A * filterScale
        for (y in 0 until sourceHeight) {
            val sourceRow = y * sourceWidth
            val targetRow = y * targetWidth
            for (x in 0 until targetWidth) {
                val center = (x + 0.5) * scale - 0.5
                val left = ceil(center - support).toInt()
                val right = floor(center + support).toInt()
                var sum = 0.0
                var weightSum = 0.0
                for (i in left..right) {
                    val weight = lanczos((i - center) / filterScale)
                    if (weight == 0.0) continue
                    sum += source[sourceRow + i.coerceIn(0, sourceWidth - 1)] * weight
                    weightSum += weight
                }
                out[targetRow + x] =
                    if (weightSum != 0.0) {
                        (sum / weightSum).roundToInt().coerceIn(0, 255)
                    } else {
                        0
                    }
            }
        }
        return out
    }

    private fun resizeVertical(
        source: IntArray,
        width: Int,
        sourceHeight: Int,
        targetHeight: Int,
    ): IntArray {
        if (targetHeight == sourceHeight) return source
        val outputPixels = width.toLong() * targetHeight.toLong()
        check(outputPixels <= OcrSizeBudget.MAX_TENSOR_PIXELS) {
            "output $outputPixels pixels exceeds ${OcrSizeBudget.MAX_TENSOR_PIXELS}"
        }
        val out = IntArray(outputPixels.toInt())
        val scale = sourceHeight.toDouble() / targetHeight
        val filterScale = if (scale < 1.0) 1.0 else scale
        val support = LANCZOS_A * filterScale
        for (x in 0 until width) {
            for (y in 0 until targetHeight) {
                val center = (y + 0.5) * scale - 0.5
                val top = ceil(center - support).toInt()
                val bottom = floor(center + support).toInt()
                var sum = 0.0
                var weightSum = 0.0
                for (j in top..bottom) {
                    val weight = lanczos((j - center) / filterScale)
                    if (weight == 0.0) continue
                    sum += source[j.coerceIn(0, sourceHeight - 1) * width + x] * weight
                    weightSum += weight
                }
                out[y * width + x] =
                    if (weightSum != 0.0) {
                        (sum / weightSum).roundToInt().coerceIn(0, 255)
                    } else {
                        0
                    }
            }
        }
        return out
    }

    /** PIL `Image.LANCZOS` 核：`sinc(x) * sinc(x/3)`，半径 3。 */
    private fun lanczos(x: Double): Double {
        if (x == 0.0) return 1.0
        val absolute = abs(x)
        if (absolute >= LANCZOS_A) return 0.0
        val pix = Math.PI * x
        val pixDivided = pix / LANCZOS_A
        return (sin(pix) / pix) * (sin(pixDivided) / pixDivided)
    }
}
