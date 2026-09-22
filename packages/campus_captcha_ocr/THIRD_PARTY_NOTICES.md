# Third-Party Notices — `campus_captcha_ocr`

本文件只登记 `packages/campus_captcha_ocr` 随包/随 APK 分发的**第三方**组件及其许可与来源。
本插件本身及整个 App 的授权条款见仓库根目录 `LICENSE`（**All Rights Reserved**，本文件不改变它）。
以下文本按上游发布物**原文**附上；标注「不明确」之处如实保留，**未做法律审核**，也不据此主张授权确定性。

随 APK 打包的许可文本位于：

- `android/src/main/assets/captcha_ocr/LICENSE-ddddocr.txt`
- `android/src/main/assets/captcha_ocr/LICENSE-onnxruntime.txt`
- `android/src/main/assets/captcha_ocr/THIRD_PARTY_NOTICES-onnxruntime.txt`

---

## 1. ddddocr `common_old.onnx` 权重

- 项目：ddddocr（带带弟弟OCR）
- 版本：`1.6.1`
- 上游仓库：https://github.com/sml2h3/ddddocr
- 发布源（PyPI）：https://pypi.org/project/ddddocr/1.6.1/
- 分发包：`ddddocr-1.6.1-py3-none-any.whl`
  - 下载 URL：https://files.pythonhosted.org/packages/0e/48/cbaed3981b8d8d51141b9b4779b811f4728e65d952a1e3e2e5e929539183/ddddocr-1.6.1-py3-none-any.whl
  - SHA-256：`c7c70f4ae2d0335440ae8b272eea48c9f6888ecef46785fe2311f0c97a133935`
  - 大小：`75,983,593` 字节
- wheel 内文件：`ddddocr/common_old.onnx`
- 本项目内文件：`android/src/main/assets/captcha_ocr/common_old.onnx`
  - 大小：`13,606,051` 字节（与 wheel 内条目一致）
  - SHA-256：`b8f2ad9cbc1f2e3922a6cb9459e30824e7e2467f3fb4fd61420640e34ea0bf68`
  - Git blob SHA-1：`8ce4807e1e68c3fa5c1344d281cc7d1623a020cc`
  - 核实方式：从上述官方 wheel 中提取同名条目后逐字节比对，SHA-256 完全一致。
- wheel 内许可文件：`ddddocr-1.6.1.dist-info/licenses/LICENSE`（本目录 `android/src/main/assets/captcha_ocr/LICENSE-ddddocr.txt` 即其原文）
- 说明：`common_old.onnx` 是 ddddocr 1.6.1 的默认 OCR 模型（`beta=False` 时使用）；未使用 beta 的 `common.onnx`，也未使用检测模型 `common_det.onnx`。

### 许可原文（MIT，含上游占位符版权行）

```
The MIT License (MIT)
Copyright © 2022 <copyright holders>

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the “Software”), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

---

## 2. ONNX Runtime（Android）

- 组件：ONNX Runtime — Android AAR
- 坐标：`com.microsoft.onnxruntime:onnxruntime-android:1.30.0`
- 上游仓库：https://github.com/microsoft/onnxruntime
- 版本标签：`v1.30.0`
- 许可：MIT License（`Copyright (c) Microsoft Corporation`）
- Maven 元数据（POM）：https://repo1.maven.org/maven2/com/microsoft/onnxruntime/onnxruntime-android/1.30.0/onnxruntime-android-1.30.0.pom
- 许可文本：https://github.com/microsoft/onnxruntime/blob/v1.30.0/LICENSE
- 第三方声明：https://github.com/microsoft/onnxruntime/blob/v1.30.0/ThirdPartyNotices.txt
  （随 APK 以 `android/src/main/assets/captcha_ocr/THIRD_PARTY_NOTICES-onnxruntime.txt` 打包）
- 说明：本组件经 Gradle 依赖引入；其 LICENSE / ThirdPartyNotices 已按上游原文随包附带。

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

## 3. 字符集 `charset_old.txt`

- 本项目内文件：`android/src/main/assets/captcha_ocr/charset_old.txt`（24,407 字节，UTF-8；含 8209 个字符 + 约定 blank 索引，共 8210 类，与 `common_old.onnx` 输出类别数一致）
  - SHA-256：`2ad1d606078ede388943ef28b2cab3ce2ee50f81d42ff275572a69a814d136f0`
- **不明确**：该文本不是 ddddocr wheel 中的同名文件；上游 1.6.1 把字符集编码在 `ddddocr/charsets.py` 与 `ddddocr/models/charset_manager.py` 中。本文件是随 `common_old.onnx` 使用的字符集序列化结果，来源可追溯到 ddddocr 1.6.1，但**未做与 wheel 条目的逐字节比对**。

---

## 4. 仍不明确 / 未主张的事项

- ddddocr 的 `LICENSE`（仓库与 wheel 内均同）版权行是占位符 `<copyright holders>`，**未指明具体版权人**；本文件原样保留，不擅自填写。
- 上游对 `common_old.onnx` 权重的授权仅体现为「wheel 整体按 MIT 分发」与 README 的「本项目采用 MIT 许可证」表述，**没有**针对 ONNX 权重的独立/单独许可声明。此处按「wheel 级 MIT 覆盖分发」的解读使用，权重可分发边界的最终确认**不在本实现范围内**。
- ONNX Runtime 的 `ThirdPartyNotices.txt` 所列传递性第三方组件由 ORT 官方构建一并提供；本项目只按原文附带，不单独核验其逐项条款。
- 本文件不构成法律审核意见。
