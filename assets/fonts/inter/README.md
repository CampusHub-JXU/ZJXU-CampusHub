# Inter（拉丁 + 数字子集）

- 来源：Inter 4.1，<https://github.com/rsms/inter/releases/tag/v4.1>，`extras/ttf/` 下的静态字重
- 许可：SIL Open Font License 1.1，见同目录 `LICENSE.txt`（作为 asset 随安装包分发）
- 用途：`AppThemeBuilder` 的全局 `fontFamily: 'Inter'`。拉丁字母、数字、标点用 Inter；中文不在子集内，由系统字体回退渲染。这样 76 号读数等大数字在不同品牌手机上观感一致（见 `docs/ui-unification-plan.md` §0.3）。
- 字重：只保留代码实际使用的 400 / 500 / 600 / 700。w800、w900 会落到 700。

## 重新生成

```sh
pip install fonttools
U="U+0020-007E,U+00A0-00FF,U+0131,U+0152-0153,U+02C6,U+02DA,U+02DC,U+2002-200B,U+2010-2027,U+2030-203A,U+2044,U+20AC,U+20B9,U+2122,U+2190-2193,U+2212,U+2215,U+2248,U+2260,U+2264,U+2265,U+FEFF"
for w in Regular Medium SemiBold Bold; do
  pyftsubset Inter-4.1/extras/ttf/Inter-$w.ttf \
    --unicodes="$U" \
    --layout-features='kern,liga,calt,ccmp,locl,mark,mkmk,tnum,case,frac,sups,subs,zero' \
    --output-file=Inter-$w.ttf
done
```

子集保留了 `tnum`（等宽数字，读数与列表数值依赖它）、`·`（U+00B7，全 App 的分隔符）和 `¥`。四个文件合计约 336KB。
