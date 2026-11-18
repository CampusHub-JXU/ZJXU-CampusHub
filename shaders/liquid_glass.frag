#include <flutter/runtime_effect.glsl>

// 液态玻璃（Dock）边缘折射 —— 作为 ImageFilter.shader 使用。
//
// 与「普通磨砂」的区别只在几何：磨砂只做背景模糊，肉眼看到的仍是背后画面
// 的原样拷贝；真实玻璃的边缘会把背景像素沿曲面法线掰弯，并在最外圈产生
// 极窄的色散与镜面高光。这里不去采样噪声贴图，而是用圆角矩形的有符号
// 距离场（SDF）描述玻璃曲面：中心位移为 0，弯折只出现在轮廓内侧的一条
// 边带里，所以 Dock 上的图标与文字不会被掰弯。
//
// uniform 约定（ImageFilter.shader 要求首个 uniform 是 vec2、且至少一个采样器；
// 引擎会把 0–1 号 float 填成输入纹理尺寸，自定义 uniform 从 2 号开始）：
//   u_size     : 输入纹理尺寸 px（引擎自动填，BackdropFilter 下往往是整屏/对齐尺寸）
//   u_bounds   : (控件中心 x px, 控件中心 y px, 半宽 px, 半高 px) —— 屏幕物理坐标
//   u_shape    : (圆角半径 px, 折射带宽度 px)
//   u_strength : (最大背景位移 px, RGB 色散偏移 px, 纵向镜面位移 px)
//
// 坐标约定：BackdropFilter 下 FlutterFragCoord() 是当前输出 pass 的屏幕物理
// 像素坐标，u_size 是整屏背面纹理尺寸，两者都在屏幕原点空间，因此 `p / u_size`
// 才是纹理 uv，而 SDF 必须相对控件自己的 u_bounds（否则全屏边缘之外的 Dock
// 或卡片会永远落在带外，折射与色散全部归零）。
// Impeller 的 GLES 后端输入纹理上下翻转，只在采样时补一次 y 镜像。

uniform vec2 u_size;
uniform vec4 u_bounds;
uniform vec2 u_shape;
uniform vec3 u_strength;
uniform sampler2D u_texture_input;

out vec4 frag_color;

// 圆角矩形有符号距离场：轮廓上为 0，内部为负。
float sd_round_rect(vec2 p, vec2 half_size, float r) {
  vec2 q = abs(p) - half_size + vec2(r);
  return min(max(q.x, q.y), 0.0) + length(max(q, vec2(0.0))) - r;
}

// 曲面法线 = SDF 梯度（中心差分）。早期版本用「中心指向外」的方向近似，
// 直边上法线是对的，但圆角处完全错位（斜向 45° 而不是沿圆弧），弯折方向
// 一眼能看出是假的。中心差分在直边、圆角上都是真实外向法线。
vec2 normal_round_rect(vec2 p, vec2 half_size, float r) {
  float dx = sd_round_rect(p + vec2(1.0, 0.0), half_size, r) -
             sd_round_rect(p - vec2(1.0, 0.0), half_size, r);
  float dy = sd_round_rect(p + vec2(0.0, 1.0), half_size, r) -
             sd_round_rect(p - vec2(0.0, 1.0), half_size, r);
  vec2 g = vec2(dx, dy);
  float len = length(g);
  return len < 1e-6 ? vec2(0.0) : g / len;
}

vec4 sample_backdrop_px(vec2 px, vec2 min_px, vec2 max_px, vec2 tex_size) {
  // 采样点夹在控件自身的 bounded 模糊区域内：既防越出纹理，也防采到
  // 外部透明/未模糊像素拉出一圈重影描边。
  // OpenGLES 实验：暂时取消 Y 翻转，用来验证黑底和横向接缝是否来自
  // 输入纹理与采样坐标的方向不一致。尚需在受影响模拟器上做 A/B 验证。
  vec2 clamped_uv = clamp(clamp(px, min_px, max_px) / tex_size, vec2(0.0), vec2(1.0));
  return texture(u_texture_input, clamped_uv);
}

void main() {
  vec2 size = max(u_size, vec2(1.0));
  vec2 p = FlutterFragCoord().xy;
  // u_bounds 未提供（z <= 0）时退回整张纹理矩形。
  vec2 center = u_bounds.z > 0.0 ? u_bounds.xy : size * 0.5;
  vec2 half_size = u_bounds.z > 0.0 ? max(u_bounds.zw, vec2(1.0)) : size * 0.5;
  vec2 local = p - center;

  float min_half = min(half_size.x, half_size.y);
  float radius = clamp(u_shape.x, 0.0, min_half);
  // 折射带最多覆盖短边的 45%，控件中心一段保持位移为 0、内容不变形
  // （同 OpenDesign 位移贴图的中性中心区）。
  float band = clamp(u_shape.y, 2.0, min_half * 0.9);
  float dist = sd_round_rect(local, half_size, radius);

  // t：0 在玻璃轮廓上，1 在折射带内缘；带外与中心恒为 1。
  float t = clamp(-dist / band, 0.0, 1.0);
  float e = 1.0 - t;

  // 透镜剖面：位移在轮廓处最大、向内平滑归零。取 smoothstep 形状
  // （两端斜率为 0、中段最陡）避免轮廓处导数转负把最外圈折成重影。
  float lens = e * e * (3.0 - 2.0 * e);

  float max_shift = max(min_half - 1.0, 0.0);
  float displace = min(lens * u_strength.x, max_shift);

  // 法线朝外、采样点朝内：
  // 1) 水平方向只在左右圆弧带内做温柔的向内弯折（直边区 normal.x == 0，
  //    中心更完全不变形）；
  // 2) 竖直方向把法线折射 + 纵向镜面折叠合进同一个平滑单调的采样曲线，
  //    并用连续过零的 `y_norm = local.y / half_size.y` 替代阶跃的 `sign`，
  //    彻底消除左右圆弧中线 `local.y = 0` 处的横切接缝；同时总竖直位移
  //    严格控在带内（<= displace + mirror 合理分配），不折返成三层重影。
  vec2 normal = normal_round_rect(local, half_size, radius);
  vec2 inward = -normal;
  float y_norm = clamp(local.y / max(half_size.y, 1.0), -1.0, 1.0);

  // 竖直方向的连续透镜剖面：中心缓慢缩放（0.08 * local.y），靠近上下轮廓
  // 时在镜面带里平滑加力把采样点往中心折进（最高 ~displacement），但绝不
  // 在圆弧中线处突变、也绝不过度折叠产生三层重影。
  float vertical_pull = -local.y * 0.08
      + inward.y * displace * 0.55
      - y_norm * (u_strength.z * lens * 0.5);
  vec2 total_off = vec2(inward.x * displace * 0.7, vertical_pull);
  vec2 base_px = p + total_off;

  // 不同波长等效 IOR 略异：三个通道沿着实际位移方向微弱错开
  // u_strength.y（随折射剖面同步衰减），全部严格夹在控件内部纹理中，
  // 绝不越界采黑，也不在中线处发生方向跳变。
  float disp_len = length(total_off);
  vec2 disp_dir = disp_len > 1e-4 ? (total_off / disp_len) : vec2(0.0);
  vec2 chroma_vec = disp_dir * (lens * u_strength.y);

  // 严格夹在控件自身矩形内，绝不越出 Impeller 背面纹理范围。
  vec2 min_px = center - half_size + vec2(1.0);
  vec2 max_px = center + half_size - vec2(1.0);

  // 三个通道各错开 chroma_vec（红光偏移最大、蓝光最小，等效 IOR 差）。
  // 浅 / 深色都不在 shader 内侧叠加泛白高光带，轮廓高光统一由 Dart 侧
  // _NavLiquidEdgePainter 的锐利方向描边负责。
  vec3 col;
  col.r = sample_backdrop_px(base_px - chroma_vec, min_px, max_px, size).r;
  col.g = sample_backdrop_px(base_px, min_px, max_px, size).g;
  col.b = sample_backdrop_px(base_px + chroma_vec, min_px, max_px, size).b;

  frag_color = vec4(clamp(col, 0.0, 1.0), 1.0);
}
