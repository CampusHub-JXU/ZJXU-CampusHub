# ONNX Runtime resolves its Java classes from JNI by literal name
# (e.g. FindClass("ai/onnxruntime/TensorInfo")), so R8 must not strip or rename
# the ai.onnxruntime package even though TensorInfo has no Java callers.
# The ONNX Runtime AAR only ships telemetry keep rules, so the consumer (this
# plugin, which owns the dependency) must ship the keep rule itself.
# Without this, release builds abort (SIGABRT) on the first captcha OCR call.
-keep class ai.onnxruntime.** { *; }
