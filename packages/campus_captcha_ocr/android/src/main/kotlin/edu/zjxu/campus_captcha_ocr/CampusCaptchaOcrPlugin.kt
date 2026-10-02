package edu.zjxu.campus_captcha_ocr

import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/**
 * 本地（离线）验证码 OCR 插件，唯一引擎为 ddddocr `common_old` 字母数字裁剪版（`.ort`）
 * + 自编精简 ONNX Runtime（见 [DdddocrEngine]）。
 *
 * - 只依赖 [FlutterPlugin]，**不依赖 Activity**，因此主引擎与 WorkManager
 *   创建的后台引擎都会经 GeneratedPluginRegistrant 自动注册本类。
 * - 通道 `edu.zjxu.jxucampushub/captcha_ocr` / 方法 `recognize`，参数
 *   `bytes`(PNG/JPEG 字节) + `expectedLength`(4 或 6)。
 * - 全程内存：BitmapFactory 解码，不落任何临时文件；不触网、不记录图片或识别答案。
 * - 输入 ≤ 512KB；`inJustDecodeBounds` 只读尺寸后先过 [OcrSizeBudget]，
 *   **超界在任何 decode / tensor 分配之前**回 `image_too_large`（不做扭曲缩放）；
 *   预处理分配前会用同一预算复核。
 * - 单实例最多 1 个未完成识别（[RecognitionAdmission]）：已有在途请求时立即回
 *   `busy`，不排队、不保留输入字节；Dart 侧超时不代表原生已停止（槽位仍占用到
 *   原生完成 / 失败 / detach）。
 * - 识别完成后回收 Bitmap；detach 后迟到回调一律丢弃，每次调用最多回复一次；
 *   detach 时不在调用线程阻塞等待推理中的 `engine.close()`，而是把清理排到同一
 *   worker 上、排在已接受任务之后（捕获本次 attachment 的引擎，不会关闭重新
 *   attach 的引擎）。
 * - 已完全替换此前的 ML Kit text-recognition 运行时，不保留第二套引擎。
 */
class CampusCaptchaOcrPlugin : FlutterPlugin, MethodCallHandler {

    companion object {
        const val CHANNEL_NAME = "edu.zjxu.jxucampushub/captcha_ocr"

        private const val METHOD_RECOGNIZE = "recognize"
        private const val ARG_BYTES = "bytes"
        private const val ARG_EXPECTED_LENGTH = "expectedLength"

        private const val MAX_INPUT_BYTES = 512 * 1024
        private val SUPPORTED_LENGTHS = setOf(4, 6)

        private const val ERR_INVALID_ARGS = "invalid_args"
        private const val ERR_IMAGE_TOO_LARGE = "image_too_large"
        private const val ERR_DECODE_FAILED = "decode_failed"
        private const val ERR_INFERENCE_FAILED = "inference_failed"
        private const val ERR_NOT_ATTACHED = "not_attached"
        private const val ERR_BUSY = "busy"
    }

    private var channel: MethodChannel? = null
    private var workExecutor: ExecutorService? = null
    private var engine: DdddocrEngine? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var detached = false

    private val admission = RecognitionAdmission()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        detached = false
        if (workExecutor == null) {
            workExecutor = Executors.newSingleThreadExecutor()
        }
        if (engine == null) {
            engine = DdddocrEngine(binding.applicationContext)
        }
        val methodChannel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
        methodChannel.setMethodCallHandler(this)
        channel = methodChannel
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        detached = true

        // 迟到回调绝不能再触碰已 detach 的引擎：失活并清空在途请求（不保留 bytes）。
        admission.deactivateCurrent()

        val executor = workExecutor
        workExecutor = null
        val detachedEngine = engine
        engine = null

        if (executor == null) {
            // 二次 detach：engine 已为 null，无需关闭。
            runCatching { detachedEngine?.close() }
            return
        }

        // 不在调用线程（可能是主线程）阻塞在 @Synchronized 的 close() 上等待推理结束：
        // 把关闭排到同一 worker、排在已接受任务之后。捕获的是本次 attachment 的引擎，
        // 因此不会关闭 detach 后重新 attach 的新引擎。shutdown() 让已入队任务跑完并
        // 拒绝新任务，worker 线程在队列清空后退出，不留常驻线程。
        val closeTask = Runnable { runCatching { detachedEngine?.close() } }
        val submitted = runCatching { executor.execute(closeTask) }
        if (submitted.isFailure) {
            // 不可达路径（只有本方法会 shutdown，且此时 executor / engine 均已置 null）：
            // 执行器已终止即无在途推理，直接关闭不会阻塞。
            runCatching { detachedEngine?.close() }
        }
        executor.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != METHOD_RECOGNIZE) {
            result.notImplemented()
            return
        }
        handleRecognize(call, result)
    }

    private fun handleRecognize(call: MethodCall, result: MethodChannel.Result) {
        val bytes = call.argument<ByteArray>(ARG_BYTES)
        val expectedLength = call.argument<Int>(ARG_EXPECTED_LENGTH) ?: -1

        if (bytes == null || bytes.isEmpty()) {
            result.error(ERR_INVALID_ARGS, "bytes must be a non-empty image", null)
            return
        }
        if (bytes.size > MAX_INPUT_BYTES) {
            result.error(ERR_INVALID_ARGS, "bytes exceeds $MAX_INPUT_BYTES", null)
            return
        }
        if (expectedLength !in SUPPORTED_LENGTHS) {
            result.error(ERR_INVALID_ARGS, "unsupported expectedLength", null)
            return
        }

        val executor = workExecutor
        val activeEngine = engine
        if (executor == null || activeEngine == null || detached) {
            result.error(ERR_NOT_ATTACHED, "plugin is not attached", null)
            return
        }

        // 单实例最多一个未完成识别：不排队、不保留 bytes，立即回 busy。
        val request = admission.tryAcquire()
        if (request == null) {
            result.error(ERR_BUSY, "a recognition is already in progress", null)
            return
        }

        try {
            executor.execute {
                try {
                    runRecognition(request, result, activeEngine, bytes)
                } catch (error: Throwable) {
                    mainHandler.post {
                        fail(request, result, ERR_INFERENCE_FAILED, error.message ?: "recognition failed")
                    }
                }
            }
        } catch (error: RejectedExecutionException) {
            // 提交被拒：清理槽位并只回一次失败；若此刻已 detach，fail() 不回调（迟到不回调）。
            fail(request, result, ERR_NOT_ATTACHED, "executor rejected the task")
        }
    }

    /** 在 worker 线程上执行：只读 bounds → 预算门 → 解码 → 推理。 */
    private fun runRecognition(
        request: RecognitionAdmission.Request,
        result: MethodChannel.Result,
        activeEngine: DdddocrEngine,
        bytes: ByteArray,
    ) {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        runCatching { BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds) }

        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
            mainHandler.post {
                fail(request, result, ERR_DECODE_FAILED, "image bounds unavailable")
            }
            return
        }

        // 预算门在任何 decode / tensor 分配之前：超界直接 image_too_large，不扭曲缩放。
        val budget = OcrSizeBudget.evaluate(bounds.outWidth, bounds.outHeight)
        if (!budget.allowed) {
            mainHandler.post {
                fail(
                    request,
                    result,
                    ERR_IMAGE_TOO_LARGE,
                    "image ${bounds.outWidth}x${bounds.outHeight} exceeds size budget (${budget.rejection})",
                )
            }
            return
        }

        val decoded =
            runCatching { BitmapFactory.decodeByteArray(bytes, 0, bytes.size) }.getOrNull()
        if (decoded == null) {
            mainHandler.post {
                fail(request, result, ERR_DECODE_FAILED, "image decode failed")
            }
            return
        }

        try {
            val output = activeEngine.recognize(decoded)
            mainHandler.post { complete(request, result, output) }
        } catch (error: OcrSizeBudgetException) {
            // 预处理复核拒绝（正常路径已在上面拦下）：仍映射为 image_too_large。
            mainHandler.post {
                fail(request, result, ERR_IMAGE_TOO_LARGE, error.message ?: "image exceeds size budget")
            }
        } catch (error: Throwable) {
            mainHandler.post {
                fail(request, result, ERR_INFERENCE_FAILED, error.message ?: "inference failed")
            }
        } finally {
            runCatching { if (!decoded.isRecycled) decoded.recycle() }
        }
    }

    private fun complete(
        request: RecognitionAdmission.Request,
        result: MethodChannel.Result,
        output: DdddocrEngine.Output,
    ) {
        val candidates = ArrayList<Map<String, Any?>>(1)
        if (output.text.isNotEmpty()) {
            candidates.add(mapOf("text" to output.text, "confidence" to output.confidence))
        }
        admission.release(request)
        if (!request.claimReply(detached)) return
        runCatching { result.success(candidates) }
    }

    private fun fail(
        request: RecognitionAdmission.Request,
        result: MethodChannel.Result,
        code: String,
        message: String,
    ) {
        admission.release(request)
        if (!request.claimReply(detached)) return
        runCatching { result.error(code, message, null) }
    }
}
