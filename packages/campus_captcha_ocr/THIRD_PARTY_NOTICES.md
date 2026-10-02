# Third-Party Notices — `campus_captcha_ocr`

本文件只登记 `packages/campus_captcha_ocr` 随包/随 APK 分发的**第三方**组件及其许可与来源。
本插件本身及整个 App 的授权条款见仓库根目录 `LICENSE`（**All Rights Reserved**，本文件不改变它）。
以下文本按上游发布物**原文**附上；标注「不明确」之处如实保留，**未做法律审核**，也不据此主张授权确定性。

随 APK 打包的许可文本位于：

- `android/src/main/assets/captcha_ocr/LICENSE-ddddocr.txt`
- `android/src/main/assets/captcha_ocr/LICENSE-onnxruntime.txt`
- `android/src/main/assets/captcha_ocr/THIRD_PARTY_NOTICES-onnxruntime.txt`

---

## 1. ddddocr `common_old.onnx` 权重（随包分发的是其裁剪 + ORT 格式派生物）

- 项目：ddddocr（带带弟弟OCR）
- 版本：`1.6.1`
- 上游仓库：https://github.com/sml2h3/ddddocr
- 发布源（PyPI）：https://pypi.org/project/ddddocr/1.6.1/
- 分发包：`ddddocr-1.6.1-py3-none-any.whl`
  - 下载 URL：https://files.pythonhosted.org/packages/0e/48/cbaed3981b8d8d51141b9b4779b811f4728e65d952a1e3e2e5e929539183/ddddocr-1.6.1-py3-none-any.whl
  - SHA-256：`c7c70f4ae2d0335440ae8b272eea48c9f6888ecef46785fe2311f0c97a133935`
  - 大小：`75,983,593` 字节
- wheel 内文件：`ddddocr/common_old.onnx`
- 上游原始文件（**不再随包分发**，可用 `tools/ocr_slim/make_variants.py` 从上述 wheel 重新提取并校验）：
  - 大小：`13,606,051` 字节
  - SHA-256：`b8f2ad9cbc1f2e3922a6cb9459e30824e7e2467f3fb4fd61420640e34ea0bf68`
  - 核实方式：从上述官方 wheel 中提取同名条目后逐字节比对，SHA-256 完全一致（v0.8.0 引入时核实；`make_variants.py` 每次运行都会重新校验 wheel 与条目的 SHA-256）。
- 本项目内文件：`android/src/main/assets/captcha_ocr/common_old_alnum.ort`（**修改后的派生物**）
  - 生成：`python tools/ocr_slim/make_variants.py --install`（onnx + onnxruntime `1.30.0` Python 包）
  - 修改内容：① 最终分类层（`135_quantized` `[1024, 8210]` uint8 + 偏置 `136`）只保留 blank + 62 个 ASCII 字母数字类的列，其余权重未改动（原模型本就是 ddddocr 发布的动态 int8 量化模型，未再量化）；② 用 `onnxruntime.tools.convert_onnx_models_to_ort`（`--optimization_style Fixed --target_platform arm`）转换为 ORT 格式。
  - 大小：`5,324,080` 字节；SHA-256：`0a39cd1315fff587c6ce27c75b43b4e6dae9ea5cdc63477d471079961e6c9ff8`
  - ORT 格式转换的字节输出与转换时的本地路径有关，重新生成的文件可能与仓库内文件存在少量字节差异；功能等价性由 `tools/ocr_slim/ocr_eval.py` 校验。
- wheel 内许可文件：`ddddocr-1.6.1.dist-info/licenses/LICENSE`（本目录 `android/src/main/assets/captcha_ocr/LICENSE-ddddocr.txt` 即其原文）
- 说明：`common_old.onnx` 是 ddddocr 1.6.1 的默认 OCR 模型（`beta=False` 时使用）；未使用 beta 的 `common.onnx`，也未使用检测模型 `common_det.onnx`。上述裁剪与格式转换属于 MIT 许可允许的修改与再分发，许可原文随派生物一并分发。

### 许可原文（MIT，含上游占位符版权行）

```
The MIT License (MIT)
Copyright © 2022 <copyright holders>

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the “Software”), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

---

## 2. ONNX Runtime（Android，自编精简版）

- 组件：ONNX Runtime — **从源码自行编译的精简（minimal）Android AAR**，不再使用 Maven Central 上的 `com.microsoft.onnxruntime:onnxruntime-android`
- 本项目内文件：`android/maven-repo/edu/zjxu/campus_captcha_ocr/onnxruntime-android-minimal/1.30.0/onnxruntime-android-minimal-1.30.0.aar`（同目录 `.pom` 为本项目手写的最小 POM，插件 `build.gradle` 把该目录注册为本地 Maven 仓库）
  - SHA-256：`1c06feb53429d4a163294513b8aa8486fb2d6c42f19d23d8617e476c30c02dde`（3,437,385 字节）
  - 内含 ABI：`arm64-v8a`、`armeabi-v7a`、`x86_64`；Java 包名仍为上游 `ai.onnxruntime`
- 上游仓库：https://github.com/microsoft/onnxruntime
- 版本标签：`v1.30.0`（commit `f2c39fe2f838cf35ce7da92824f5a5e3ee6e88a7`）
- 编译脚本：`tools/ocr_slim/build_ort_minimal_aar.sh`（版本号与参数固定）
- 编译参数（每个 ABI）：`--minimal_build --include_ops_by_config tools/ocr_slim/required_operators_and_types.config --enable_reduced_operator_type_support --disable_ml_ops --no_telemetry --build_java --build_shared_lib --config MinSizeRel --android_api 24`，`onnxruntime_BUILD_UNIT_TESTS=OFF`；Android NDK `28.2.13676358`
  - **未**使用 `--disable_exceptions`（Java 绑定依赖异常把原生错误转换成 `OrtException`）；RTTI 按 `--minimal_build` 默认关闭
  - `--no_telemetry`：不含遥测（官方 AAR 自带的 Android telemetry Java 桥与 1DS SDK 均未编入），与本插件「不触网」约束一致
- 第三方依赖源码：按 ORT `cmake/deps.txt` 固定的同一 commit / tag 获取（经 `git` 克隆后重新打包，见 `tools/ocr_slim/mirror_ort_deps.py`；只有打包方式不同，源码树相同）；编入的组件均已列于 ORT `ThirdPartyNotices.txt`
- AAR 组装：不经 AGP，直接打包 `AndroidManifest.xml` + `classes.jar`（`java/src/main/java` + `java/src/main/android`，`javac --release 17`）+ `jni/<abi>/*.so`，并附 ORT `LICENSE` 与 `ThirdPartyNotices.txt`
- 许可：MIT License（`Copyright (c) Microsoft Corporation`）
- 许可文本：https://github.com/microsoft/onnxruntime/blob/v1.30.0/LICENSE
- 第三方声明：https://github.com/microsoft/onnxruntime/blob/v1.30.0/ThirdPartyNotices.txt
  （随 APK 以 `android/src/main/assets/captcha_ocr/THIRD_PARTY_NOTICES-onnxruntime.txt` 打包，已核对与 v1.30.0 标签原文逐字节一致）

### 许可原文（MIT）

```
MIT License

Copyright (c) Microsoft Corporation

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## 3. 字符集 `charset_alnum.txt`（源自 `charset_old.txt`）

- 本项目内文件：`android/src/main/assets/captcha_ocr/charset_alnum.txt`（62 字节，UTF-8；62 个 ASCII 字母数字 + 约定 blank 索引，共 63 类，与 `common_old_alnum.ort` 输出类别数一致）
  - SHA-256：`940712f479045fca1705591447b0ecbc41ddac96dcb106e453be9beb26b52f0e`
  - 由 `make_variants.py` 从 `charset_old.txt` 中按原顺序抽取字母数字字符得到。
- 来源文件：`tools/ocr_slim/charset_old.txt`（24,407 字节，UTF-8；8209 个字符 + 约定 blank，共 8210 类；**不再随 APK 分发**，仅供重新生成）
  - SHA-256：`2ad1d606078ede388943ef28b2cab3ce2ee50f81d42ff275572a69a814d136f0`
- **不明确**：`charset_old.txt` 不是 ddddocr wheel 中的同名文件；上游 1.6.1 把字符集编码在 `ddddocr/charsets.py` 与 `ddddocr/models/charset_manager.py` 中。该文件是随 `common_old.onnx` 使用的字符集序列化结果，来源可追溯到 ddddocr 1.6.1，但**未做与 wheel 条目的逐字节比对**。

---

## 4. 仍不明确 / 未主张的事项

- ddddocr 的 `LICENSE`（仓库与 wheel 内均同）版权行是占位符 `<copyright holders>`，**未指明具体版权人**；本文件原样保留，不擅自填写。
- 上游对 `common_old.onnx` 权重的授权仅体现为「wheel 整体按 MIT 分发」与 README 的「本项目采用 MIT 许可证」表述，**没有**针对 ONNX 权重的独立/单独许可声明。此处按「wheel 级 MIT 覆盖分发」的解读使用，权重可分发边界的最终确认**不在本实现范围内**。
- ONNX Runtime 的 `ThirdPartyNotices.txt` 所列传递性第三方组件：精简构建只编入其中一部分（abseil、flatbuffers、date、GSL、Boost.MP11、SafeInt、Eigen、cpuinfo、KleidiAI 等），本项目按原文完整附带该文件，不单独核验其逐项条款。
- 本文件不构成法律审核意见。
