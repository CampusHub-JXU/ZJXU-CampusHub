#!/usr/bin/env bash
# Build the reduced ("minimal") ONNX Runtime Android AAR used by
# packages/campus_captcha_ocr. Reproducible inputs, all pinned:
#
#   ONNX Runtime  v1.30.0 (commit f2c39fe2f838cf35ce7da92824f5a5e3ee6e88a7)
#   Android NDK   28.2.13676358 (= Flutter 3.47.2 default ndkVersion), API 24
#   ABIs          arm64-v8a, armeabi-v7a (release), x86_64 (emulator debug)
#   Ops           tools/ocr_slim/required_operators_and_types.config, generated
#                 by make_variants.py from the shipped captcha_ocr/*.ort model
#
# ORT build flags (per ABI):
#   --minimal_build --include_ops_by_config <config>
#   --enable_reduced_operator_type_support --disable_ml_ops --no_telemetry
#   --build_java --build_shared_lib --config MinSizeRel --android_api 24
#   (+ onnxruntime_BUILD_UNIT_TESTS=OFF, --skip_tests alone still configures them;
#    onnxruntime_SKIP_ANDROID_AAR_GRADLE=ON, a local CMake guard, see below)
# Not used: --disable_exceptions (build.py turns it into "no Java", and the
# Java API reports native failures as OrtException) and --disable_rtti beyond
# what --minimal_build already implies.
#
# Usage:
#   ANDROID_HOME=... ANDROID_NDK_HOME=... tools/ocr_slim/build_ort_minimal_aar.sh [work dir]
# Output:
#   <work dir>/aar_out/onnxruntime-android-minimal-1.30.0.aar (assembled without AGP)
#   copy it to packages/campus_captcha_ocr/android/libs/ (see README.md).
#
# Needs: git, python3, cmake >= 3.28, ninja, zip, JDK 17+, an Android SDK with
# platforms;android-34 and the NDK above, and network access to
# github.com over git (the FetchContent archives are mirrored via git by
# mirror_ort_deps.py).
set -euo pipefail
# build.py refuses to run as root unless told to (CI containers often are root).
ROOT_FLAG=()
[ "$(id -u)" = 0 ] && ROOT_FLAG=(--allow_running_as_root)

ORT_TAG=v1.30.0
ORT_COMMIT=f2c39fe2f838cf35ce7da92824f5a5e3ee6e88a7
NDK_VERSION=28.2.13676358
API=24
ABIS=(arm64-v8a armeabi-v7a x86_64)
CONFIG=MinSizeRel

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mkdir -p "${1:-$HERE/../../.ocr_work/ort_build}" && cd "${1:-$HERE/../../.ocr_work/ort_build}" && pwd)"
OPS_CONFIG="$HERE/required_operators_and_types.config"
: "${ANDROID_HOME:?set ANDROID_HOME}"
ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$ANDROID_HOME/ndk/$NDK_VERSION}"
JOBS="${JOBS:-$(nproc)}"

ORT="$WORK/onnxruntime"
MIRROR="$WORK/deps_mirror"

# 1. Sources ------------------------------------------------------------------
if [ ! -d "$ORT/.git" ]; then
  git clone --depth 1 --branch "$ORT_TAG" https://github.com/microsoft/onnxruntime.git "$ORT"
fi
actual="$(git -C "$ORT" rev-parse HEAD)"
[ "$actual" = "$ORT_COMMIT" ] || { echo "unexpected ORT commit $actual" >&2; exit 1; }

# FetchContent dependencies reached by this configuration (minimal build,
# CPU EP only, no tests). Everything else in deps.txt is never downloaded.
python3 "$HERE/mirror_ort_deps.py" "$ORT" "$MIRROR" \
  abseil_cpp date eigen flatbuffers microsoft_gsl mp11 onnx protobuf \
  pytorch_cpuinfo safeint kleidiai json re2 fp16 psimd fxdiv pthreadpool

# ORT's CMake runs java/build-android.gradle (AGP 7.4.2, Google Maven) as a
# POST_BUILD step of onnxruntime4j_jni to make its own AAR. We assemble the AAR
# in step 4 instead, so put that one step behind an option (default unchanged).
python3 - "$ORT/cmake/onnxruntime_java.cmake" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
start = "  # Generate the Android AAR package\n  add_custom_command(TARGET onnxruntime4j_jni"
end = "      --stacktrace\n    WORKING_DIRECTORY ${JAVA_ROOT})\n"
if "onnxruntime_SKIP_ANDROID_AAR_GRADLE" not in s:
    i = s.index(start)
    j = s.index(end, i) + len(end)
    s = s[:i] + "  if (NOT onnxruntime_SKIP_ANDROID_AAR_GRADLE)\n" + s[i:j] + "  endif()\n" + s[j:]
    open(p, "w").write(s)
PY

# 2. Host protoc (same protobuf release as the target build) -----------------
PROTOC="$WORK/protoc_host/bin/protoc"
if [ ! -x "$PROTOC" ]; then
  pb_src="$WORK/protoc_src"
  if [ ! -f "$pb_src/CMakeLists.txt" ]; then
    mkdir -p "$pb_src/third_party/abseil-cpp"
    tar -xzf "$MIRROR"/protobuf-*.tar.gz -C "$pb_src" --strip-components=1
    tar -xzf "$MIRROR"/abseil_cpp-*.tar.gz -C "$pb_src/third_party/abseil-cpp" --strip-components=1
  fi
  cmake -S "$pb_src" -B "$WORK/protoc_build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -Dprotobuf_BUILD_TESTS=OFF -Dprotobuf_ABSL_PROVIDER=module \
    -DCMAKE_INSTALL_PREFIX="$WORK/protoc_host"
  cmake --build "$WORK/protoc_build" --target protoc -j "$JOBS"
  mkdir -p "$(dirname "$PROTOC")" && cp "$WORK/protoc_build/protoc" "$PROTOC"
fi

# 3. Native libraries per ABI --------------------------------------------------
for abi in "${ABIS[@]}"; do
  python3 "$ORT/tools/ci_build/build.py" \
    --build_dir "$WORK/build/$abi" --config "$CONFIG" \
    --android --android_abi "$abi" --android_api "$API" \
    --android_sdk_path "$ANDROID_HOME" --android_ndk_path "$ANDROID_NDK_HOME" \
    --minimal_build --include_ops_by_config "$OPS_CONFIG" \
    --enable_reduced_operator_type_support --disable_ml_ops --no_telemetry \
    --build_java --build_shared_lib --skip_tests --skip_submodule_sync \
    --cmake_extra_defines onnxruntime_BUILD_UNIT_TESTS=OFF onnxruntime_SKIP_ANDROID_AAR_GRADLE=ON \
    --path_to_protoc_exe "$PROTOC" \
    "${ROOT_FLAG[@]}" --cmake_generator Ninja --parallel "$JOBS" --update --build
  mkdir -p "$WORK/jnilibs/$abi"
  for lib in libonnxruntime.so libonnxruntime4j_jni.so; do
    cp "$WORK/build/$abi/$CONFIG/$lib" "$WORK/jnilibs/$abi/$lib"
  done
done

# 4. AAR -------------------------------------------------------------------------
# Assembled directly instead of via ORT's java/build-android.gradle: that file
# pins AGP 7.4.2 and needs Google Maven, while the AAR itself is only
#   AndroidManifest.xml + classes.jar + jni/<abi>/*.so + R.txt
# classes.jar = the same sources build-android.gradle compiles
# (src/main/java + src/main/android; the telemetry bridge is not included since
# --no_telemetry), javac --release 17 against android-34, like upstream.
ANDROID_JAR="$ANDROID_HOME/platforms/android-34/android.jar"
[ -f "$ANDROID_JAR" ] || { echo "missing $ANDROID_JAR (sdkmanager 'platforms;android-34')" >&2; exit 1; }
AAR_ROOT="$WORK/aar_build/root"
rm -rf "$WORK/aar_build" && mkdir -p "$AAR_ROOT" "$WORK/aar_build/classes"
find "$ORT/java/src/main/java" "$ORT/java/src/main/android" -name '*.java' > "$WORK/aar_build/sources.txt"
javac --release 17 -encoding UTF-8 -nowarn -cp "$ANDROID_JAR" \
  -d "$WORK/aar_build/classes" @"$WORK/aar_build/sources.txt"
(cd "$WORK/aar_build/classes" && find . -type f | LC_ALL=C sort | TZ=UTC zip -q -X -D "$AAR_ROOT/classes.jar" -@)
cat > "$AAR_ROOT/AndroidManifest.xml" <<MANIFEST
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="ai.onnxruntime">
    <uses-sdk android:minSdkVersion="$API" />
</manifest>
MANIFEST
: > "$AAR_ROOT/R.txt"
for abi in "${ABIS[@]}"; do
  mkdir -p "$AAR_ROOT/jni/$abi"
  cp "$WORK/jnilibs/$abi/"*.so "$AAR_ROOT/jni/$abi/"
done
cp "$ORT/LICENSE" "$AAR_ROOT/LICENSE"
cp "$ORT/ThirdPartyNotices.txt" "$AAR_ROOT/ThirdPartyNotices.txt"
mkdir -p "$WORK/aar_out"
out="$WORK/aar_out/onnxruntime-android-minimal-1.30.0.aar"
rm -f "$out"
(cd "$AAR_ROOT" && find . -type f | LC_ALL=C sort | TZ=UTC zip -q -X -D "$out" -@)
ls -l "$out"
sha256sum "$out"
