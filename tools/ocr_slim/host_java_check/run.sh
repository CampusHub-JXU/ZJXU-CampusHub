#!/usr/bin/env bash
# Host (Linux x86_64) check that the *same* minimal ORT configuration loads the
# shipped .ort through the Java API with DdddocrEngine.kt's session options and
# reproduces Python ORT's logits. This is not a device test: it builds ORT for
# the host from the same source tree / ops config as build_ort_minimal_aar.sh
# and runs on a desktop JVM.
#
# Usage: tools/ocr_slim/host_java_check/run.sh <ort work dir> <samples dir>
set -euo pipefail
# build.py refuses to run as root unless told to (CI containers often are root).
ROOT_FLAG=()
[ "$(id -u)" = 0 ] && ROOT_FLAG=(--allow_running_as_root)
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(cd "$1" && pwd)"
SAMPLES="$(cd "$2" && pwd)"
ASSETS="$HERE/../../../packages/campus_captcha_ocr/android/src/main/assets/captcha_ocr"
ORT="$WORK/onnxruntime"
BUILD="$WORK/build/host"

if [ ! -f "$BUILD/MinSizeRel/java/build/libs/onnxruntime.jar" ] && ! ls "$BUILD"/MinSizeRel/java/build/libs/onnxruntime*.jar >/dev/null 2>&1; then
  python3 "$ORT/tools/ci_build/build.py" \
    --build_dir "$BUILD" --config MinSizeRel \
    --minimal_build --include_ops_by_config "$HERE/../required_operators_and_types.config" \
    --enable_reduced_operator_type_support --disable_ml_ops --no_telemetry \
    --build_java --build_shared_lib --skip_tests --skip_submodule_sync \
    --cmake_extra_defines onnxruntime_BUILD_UNIT_TESTS=OFF \
    --path_to_protoc_exe "$WORK/protoc_host/bin/protoc" \
    "${ROOT_FLAG[@]}" --cmake_generator Ninja --parallel "${JOBS:-$(nproc)}" --update --build
fi
jar="$(ls "$BUILD"/MinSizeRel/java/build/libs/onnxruntime*.jar | grep -v -e sources -e javadoc | head -n1)"
out="$WORK/host_java_check"
mkdir -p "$out"
python3 "$HERE/dump_reference.py" "$ASSETS/common_old_alnum.ort" "$ASSETS/charset_alnum.txt" "$SAMPLES" "$out/refs.bin"
javac -cp "$jar" -d "$out" "$HERE/OrtJavaCheck.java"
java -cp "$jar:$out" OrtJavaCheck "$ASSETS/common_old_alnum.ort" "$ASSETS/charset_alnum.txt" "$out/refs.bin"
