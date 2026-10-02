package edu.zjxu.campus_captcha_ocr

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.content.Context
import android.graphics.Bitmap
import java.nio.FloatBuffer

/**
 * 本地验证码 OCR 引擎：ddddocr `common_old` 字母数字裁剪版（ORT 格式）+ 自编精简
 * ONNX Runtime（CPU，minimal build，只能加载 `.ort`）。
 *
 * - 模型与字符集随插件 Android asset 分发（`assets/captcha_ocr/`），离线推理，
 *   不下载、不触网、不落临时文件、不记录图片或答案。
 * - 模型 = ddddocr 1.6.1 `common_old.onnx` 的最终分类层只保留 blank + 62 个 ASCII
 *   字母数字类（`tools/ocr_slim/make_variants.py`）：分类层按张量级量化，保留类的
 *   logits 与原模型逐位一致；差别只在原模型 argmax 落在非字母数字类的帧（原先被
 *   [CtcDecoder] 删除，现在落到 blank 或最佳字母数字类）。离线评估见
 *   `tools/ocr_slim/README.md`。
 * - ORT session 懒加载并跨调用复用；单线程（intra/inter op 均 1），detach 时关闭。
 * - CTC 解码与字母数字后处理见 [CtcDecoder]（纯 JVM，有固定向量单测）。
 *
 * 许可证边界（如实记录，不主张法律确定性）：
 * ddddocr 仓库与 PyPI wheel 元数据均为 MIT（`License: The MIT License (MIT)`、
 * `License-File: LICENSE`），即随 wheel 分发的 `common_old.onnx` 权重一并按 MIT
 * 分发；上游**没有**针对 ONNX 权重的独立/单独许可证声明。此处仅按「wheel 级
 * MIT 覆盖分发」的解读使用，权重许可与可分发边界的最终确认不在本实现范围内。
 * 裁剪 / ORT 格式转换属于对该权重的修改再分发（MIT 允许）。
 * 未使用 beta `common.onnx`，也未使用检测模型 `common_det.onnx`。
 */
internal class DdddocrEngine(private val context: Context) {

    data class Output(val text: String, val confidence: Double)

    private companion object {
        const val MODEL_ASSET = "captcha_ocr/common_old_alnum.ort"
        const val CHARSET_ASSET = "captcha_ocr/charset_alnum.txt"

        /** 模型输出类别数：blank + 62 个 ASCII 字母数字（裁剪后的分类层宽度）。 */
        const val EXPECTED_CHARSET_SIZE = 63

        /** 精简 ORT 只认 ORT 格式；显式声明，避免按字节嗅探格式。 */
        const val CONFIG_LOAD_MODEL_FORMAT = "session.load_model_format"

        /**
         * 输出帧数相对输入宽度的容差倍数。输入宽度 ≤
         * [OcrSizeBudget.MAX_NORMALIZED_WIDTH]（下采样 CNN 的时间步不会超过输入列数，
         * 这里仍留 4× 余量容忍 stride / layout 差异）。超过即视为异常输出而拒绝，
         * 避免 `Array(frames)` 因畸形输出无限放大。
         */
        private const val MAX_FRAMES_PER_INPUT_COLUMN = 4L
    }

    private val environment = OrtEnvironment.getEnvironment()
    private var session: OrtSession? = null
    private var charset: CharArray? = null

    @Synchronized
    private fun ensureInitialized(): Pair<OrtSession, CharArray> {
        val existingSession = session
        val existingCharset = charset
        if (existingSession != null && existingCharset != null) {
            return existingSession to existingCharset
        }

        val loadedCharset = loadCharset()
        val modelBytes = context.assets.open(MODEL_ASSET).use { it.readBytes() }
        val options = OrtSession.SessionOptions()
        try {
            options.setIntraOpNumThreads(1)
            options.setInterOpNumThreads(1)
            options.addConfigEntry(CONFIG_LOAD_MODEL_FORMAT, "ORT")
            // `.ort` 已在转换时按 ALL 级离线优化（Fixed 风格）；minimal build 不含
            // 图优化器，这里设置不会再改图，保留只为与转换参数一致。
            options.setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
            val created = environment.createSession(modelBytes, options)
            session = created
            charset = loadedCharset
            return created to loadedCharset
        } finally {
            runCatching { options.close() }
        }
    }

    private fun loadCharset(): CharArray {
        val raw =
            context.assets.open(CHARSET_ASSET).use {
                it.readBytes().toString(Charsets.UTF_8)
            }
        // asset 存的是去掉 blank 后的 62 个字母数字；索引 0 约定为 blank。
        val table = CharArray(raw.length + 1)
        table[0] = '\u0000'
        raw.toCharArray(table, 1)
        check(table.size == EXPECTED_CHARSET_SIZE) {
            "charset size ${table.size} != $EXPECTED_CHARSET_SIZE"
        }
        return table
    }

    /** 同步识别（调用方负责放在工作线程上）。 */
    @Synchronized
    fun recognize(bitmap: Bitmap): Output {
        val (activeSession, activeCharset) = ensureInitialized()
        val tensor = DdddocrPreprocessor.toInputTensor(bitmap)
        val inputName = activeSession.inputNames.first()
        val shape =
            longArrayOf(
                1,
                1,
                DdddocrPreprocessor.TARGET_HEIGHT.toLong(),
                tensor.width.toLong(),
            )

        OnnxTensor.createTensor(environment, tensor.buffer, shape).use { input ->
            activeSession.run(mapOf(inputName to input)).use { result ->
                val output = result.get(0) as OnnxTensor
                output.use { value ->
                    val logits = readLogits(value.floatBuffer, activeCharset.size, tensor.width)
                    return Output(
                        text = CtcDecoder.decode(logits, activeCharset),
                        confidence = CtcDecoder.meanMaxSoftmax(logits),
                    )
                }
            }
        }
    }

    /**
     * 读出 time-major `(T, 1, C)` 输出。ONNX metadata 声明的是 `[1, seqlen]`，与
     * 运行时形状不符，因此不依赖声明维度：按「总量 / C」推帧数，与 ddddocr
     * `output.shape[1] == 1` 分支的语义一致（layout 解释不变）。
     *
     * 防御性上界（避免 overflow / 异常分配，转 Int 前全部先验证）：
     * 元素数必须能被类别数整除，且帧数不得超过输入列数的
     * [MAX_FRAMES_PER_INPUT_COLUMN] 倍。
     */
    private fun readLogits(buffer: FloatBuffer, classes: Int, inputWidth: Int): Array<FloatArray> {
        val capacity = buffer.capacity().toLong()
        check(classes > 0 && capacity > 0L) {
            "unexpected output element count $capacity for $classes classes"
        }
        check(capacity % classes.toLong() == 0L) {
            "unexpected output element count $capacity for $classes classes"
        }
        val frames = capacity / classes
        val maxFrames = maxOf(1L, inputWidth.toLong()) * MAX_FRAMES_PER_INPUT_COLUMN
        check(frames <= maxFrames) {
            "unexpected output frame count $frames (capacity $capacity, classes $classes) " +
                "for input width $inputWidth"
        }
        check(frames <= Int.MAX_VALUE.toLong()) { "output frame count $frames overflows Int" }
        buffer.rewind()
        return Array(frames.toInt()) { FloatArray(classes).also { buffer.get(it) } }
    }

    @Synchronized
    fun close() {
        runCatching { session?.close() }
        session = null
        charset = null
    }
}
