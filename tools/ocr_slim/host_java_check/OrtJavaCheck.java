import ai.onnxruntime.OnnxTensor;
import ai.onnxruntime.OrtEnvironment;
import ai.onnxruntime.OrtSession;

import java.io.DataInputStream;
import java.io.FileInputStream;
import java.io.BufferedInputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.Collections;

/**
 * Host-JVM check of the minimal ONNX Runtime build's Java API against the
 * shipped captcha model, using the same calls / session options as
 * DdddocrEngine.kt (byte[] model, intra/inter = 1, load_model_format=ORT,
 * ALL_OPT). Reads tensors + reference logits dumped by dump_reference.py and
 * reports the max |logit difference| and decoded-text mismatches.
 *
 * Usage: java -cp onnxruntime.jar:. OrtJavaCheck <model.ort> <charset.txt> <refs.bin>
 */
public final class OrtJavaCheck {
    public static void main(String[] args) throws Exception {
        byte[] model = Files.readAllBytes(Paths.get(args[0]));
        String charset = new String(Files.readAllBytes(Paths.get(args[1])), "UTF-8");
        int classes = charset.length() + 1;

        OrtEnvironment env = OrtEnvironment.getEnvironment();
        OrtSession.SessionOptions options = new OrtSession.SessionOptions();
        options.setIntraOpNumThreads(1);
        options.setInterOpNumThreads(1);
        options.addConfigEntry("session.load_model_format", "ORT");
        options.setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT);
        OrtSession session = env.createSession(model, options);
        options.close();
        String inputName = session.getInputNames().iterator().next();

        int samples = 0, textMismatch = 0;
        double maxDiff = 0;
        try (DataInputStream in = new DataInputStream(new BufferedInputStream(new FileInputStream(args[2])))) {
            int n = Integer.reverseBytes(in.readInt());
            for (int s = 0; s < n; s++) {
                int width = Integer.reverseBytes(in.readInt());
                int frames = Integer.reverseBytes(in.readInt());
                FloatBuffer input = ByteBuffer.allocateDirect(64 * width * 4).order(ByteOrder.nativeOrder()).asFloatBuffer();
                for (int i = 0; i < 64 * width; i++) input.put(Float.intBitsToFloat(Integer.reverseBytes(in.readInt())));
                input.rewind();
                float[] ref = new float[frames * classes];
                for (int i = 0; i < ref.length; i++) ref[i] = Float.intBitsToFloat(Integer.reverseBytes(in.readInt()));

                try (OnnxTensor tensor = OnnxTensor.createTensor(env, input, new long[] {1, 1, 64, width});
                     OrtSession.Result result = session.run(Collections.singletonMap(inputName, tensor))) {
                    FloatBuffer out = ((OnnxTensor) result.get(0)).getFloatBuffer();
                    if (out.capacity() != ref.length) {
                        throw new IllegalStateException("sample " + s + ": output " + out.capacity() + " != " + ref.length);
                    }
                    float[] got = new float[ref.length];
                    out.get(got);
                    for (int i = 0; i < got.length; i++) maxDiff = Math.max(maxDiff, Math.abs(got[i] - ref[i]));
                    if (!decode(got, frames, classes, charset).equals(decode(ref, frames, classes, charset))) textMismatch++;
                }
                samples++;
            }
        }
        session.close();
        System.out.printf("samples=%d textMismatch=%d maxAbsLogitDiff=%.6g%n", samples, textMismatch, maxDiff);
        if (textMismatch != 0) System.exit(1);
    }

    /** Same as CtcDecoder.decode: argmax, collapse, drop blank, alnum filter. */
    private static String decode(float[] logits, int frames, int classes, String charset) {
        StringBuilder sb = new StringBuilder();
        int prev = -1;
        for (int t = 0; t < frames; t++) {
            int best = 0;
            float bestValue = Float.NEGATIVE_INFINITY;
            for (int c = 0; c < classes; c++) {
                float v = logits[t * classes + c];
                if (v > bestValue) { bestValue = v; best = c; }
            }
            if (best != prev && best != 0) {
                char ch = charset.charAt(best - 1);
                if ((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')) sb.append(ch);
            }
            prev = best;
        }
        return sb.toString();
    }
}
