package edu.zjxu.campus_captcha_ocr

/**
 * ddddocr 1.6.1 的 CTC 解码，纯 JVM 实现（不引用任何 Android API），便于用固定
 * 向量做单元测试。行为对齐 `ddddocr/core/ocr_engine.py`：
 *
 * 1. 每帧在类别轴 argmax；
 * 2. 折叠连续相同的索引；
 * 3. 丢弃 blank（约定为索引 0，对应空字符）；
 * 4. 用字符集映射为字符，并做 **ASCII 字母数字后置过滤** —— 对应 ddddocr
 *    `set_ranges("<字母数字串>")` 的字符串形式：不在集合内的字符**直接删除**，
 *    绝不重排/纠正（它只会让结果变短，不会把误识字符改成合法字符）。
 *
 * 注意：`set_ranges(6)`（整数形式）在 1.6.1 里是「字符集前缀切片」，与字母数字
 * 毫无关系，本实现**不使用**该伪白名单，只用真正的字母数字字符串过滤。
 */
internal object CtcDecoder {

    /** blank 的类别索引，与 ddddocr 的 `charset[0] == ""` 约定一致。 */
    const val BLANK_INDEX = 0

    /** 每帧 argmax；返回长度 T 的原始索引序列（不折叠、不去 blank）。 */
    fun argmaxPerFrame(logits: Array<FloatArray>): IntArray {
        val out = IntArray(logits.size)
        for (t in logits.indices) {
            val row = logits[t]
            var bestIndex = 0
            var bestValue = Float.NEGATIVE_INFINITY
            for (c in row.indices) {
                val value = row[c]
                if (value > bestValue) {
                    bestValue = value
                    bestIndex = c
                }
            }
            out[t] = bestIndex
        }
        return out
    }

    /** CTC 折叠：跳过连续重复索引与 blank。 */
    fun collapse(indices: IntArray, blankIndex: Int = BLANK_INDEX): List<Int> {
        val out = ArrayList<Int>(indices.size)
        var previous = -1
        for (index in indices) {
            if (index != previous && index != blankIndex) {
                out.add(index)
            }
            previous = index
        }
        return out
    }

    /** 字符集映射 + ASCII 字母数字后置过滤；越界/blank 索引丢弃。 */
    fun mapAsciiAlnum(indices: List<Int>, charset: CharArray): String {
        val builder = StringBuilder(indices.size)
        for (index in indices) {
            if (index <= 0 || index >= charset.size) continue
            val character = charset[index]
            if (isAsciiAlnum(character)) {
                builder.append(character)
            }
        }
        return builder.toString()
    }

    fun isAsciiAlnum(character: Char): Boolean =
        (character in '0'..'9') ||
            (character in 'a'..'z') ||
            (character in 'A'..'Z')

    /** 完整解码：argmax → 折叠 → 去 blank → 字符集映射 → 字母数字过滤。 */
    fun decode(logits: Array<FloatArray>, charset: CharArray): String =
        mapAsciiAlnum(collapse(argmaxPerFrame(logits)), charset)

    /**
     * ddddocr 的 `confidence`：对所有 T 帧（含 blank 帧）取 max-softmax 再求均值。
     * 它不是逐字符置信度；不同长度图不可直接横向比较。
     */
    fun meanMaxSoftmax(logits: Array<FloatArray>): Double {
        if (logits.isEmpty()) return 0.0
        var total = 0.0
        for (row in logits) {
            if (row.isEmpty()) continue
            var max = Float.NEGATIVE_INFINITY
            for (value in row) {
                if (value > max) max = value
            }
            var denominator = 0.0
            for (value in row) {
                denominator += Math.exp((value - max).toDouble())
            }
            if (denominator > 0.0) {
                total += 1.0 / denominator
            }
        }
        return total / logits.size
    }
}
