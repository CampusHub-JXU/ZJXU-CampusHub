#include <flutter/runtime_effect.glsl>

uniform vec2 u_size;
uniform sampler2D u_texture;
uniform float u_time;
uniform float u_intensity;
uniform float u_theme_r;
uniform float u_theme_g;
uniform float u_theme_b;
uniform float u_opacity;
uniform float u_monet_0_r;
uniform float u_monet_0_g;
uniform float u_monet_0_b;
uniform float u_monet_1_r;
uniform float u_monet_1_g;
uniform float u_monet_1_b;
uniform float u_monet_2_r;
uniform float u_monet_2_g;
uniform float u_monet_2_b;
uniform float u_complement_0_r;
uniform float u_complement_0_g;
uniform float u_complement_0_b;
uniform float u_complement_1_r;
uniform float u_complement_1_g;
uniform float u_complement_1_b;
uniform float u_complement_2_r;
uniform float u_complement_2_g;
uniform float u_complement_2_b;
uniform float u_is_dark_mode;

out vec4 frag_color;

// 丝绸 / 液态渐变：
// 低频正弦场反复扭曲坐标，得到大块、边缘顺滑、互相卷入的流动（不叠高频噪声，
// 所以不会像烟雾那样发散成一缕一缕）；再用扭曲后的相位做「褶皱」明暗和
// 偏移的窄高光带，模拟丝绸 / 液面的弧度和光泽。配色仍取 Monet 主色 + 互补色。

vec3 saturate_color(vec3 color, float saturation) {
  float gray = dot(color, vec3(0.299, 0.587, 0.114));
  return mix(vec3(gray), color, saturation);
}

vec4 random4(vec2 i) {
  vec4 d = vec4(
    dot(i, vec2(12.9898, 78.233)),
    dot(i + vec2(1.0, 0.0), vec2(12.9898, 78.233)),
    dot(i + vec2(0.0, 1.0), vec2(12.9898, 78.233)),
    dot(i + vec2(1.0, 1.0), vec2(12.9898, 78.233))
  );
  return fract(sin(d) * 43758.5453123);
}

float noise(vec2 st) {
  vec2 i = floor(st);
  vec2 f = fract(st);
  vec4 h = random4(i);
  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(h.x, h.y, u.x) + (h.z - h.x) * u.y * (1.0 - u.x) + (h.w - h.y) * u.x * u.y;
}

// 只取两层低频噪声，给流动加一点不规则，避免纯正弦场的周期感。
float soft_noise(vec2 p) {
  return noise(p) * 0.65 + noise(p * 1.9 + vec2(3.1, 1.7)) * 0.35;
}

vec3 gradient_color(float t, vec3 c0, vec3 c1, vec3 c2) {
  float first_half = 1.0 - smoothstep(0.35, 0.58, t);
  vec3 lower = mix(c0, c1, smoothstep(0.04, 0.58, t));
  vec3 upper = mix(c1, c2, smoothstep(0.42, 0.96, t));
  return mix(upper, lower, first_half);
}

void main() {
  vec2 frag_coord = FlutterFragCoord().xy;
  vec2 uv = frag_coord / u_size;
  float intensity = clamp(u_intensity, 0.0, 1.0);
  float light_mode = 1.0 - step(0.5, u_is_dark_mode);
  float time = u_time * mix(0.55, 1.0, intensity);

  vec2 q = (frag_coord - 0.5 * u_size) / min(u_size.x, u_size.y) * 2.2;

  // 液态扭曲：每层频率递增、幅度按 fi^1.3 衰减（高层保留一点折角，褶皱更利落），相位随时间缓慢漂移。
  float warp = mix(0.50, 0.92, intensity);
  for (int i = 1; i < 6; i++) {
    float fi = float(i);
    q += (warp / pow(fi, 1.3)) * vec2(
      sin(fi * 0.90 * q.y + time * (0.19 + 0.045 * fi) + fi * 1.3),
      cos(fi * 0.80 * q.x - time * (0.16 + 0.040 * fi) + fi * 2.1)
    );
  }

  float n = soft_noise(q * 0.55 + vec2(time * 0.04, -time * 0.03));

  // 主褶皱与次褶皱：方向略错开，叠出丝绸的交叠层次。
  float phase = q.x * 1.25 + q.y * 0.95 + n * 1.1;
  float fold = 0.5 + 0.5 * sin(phase);
  float phase2 = q.y * 1.55 - q.x * 0.55 + n * 0.9 + 1.3;
  float fold2 = 0.5 + 0.5 * sin(phase2);
  // 尖脊：1-|sin(x/2)| 在脊线处成尖角，只用于明暗和高光（配色仍用平滑褶皱，避免色块被压暗）。
  float ridge = pow(1.0 - abs(sin(phase * 0.5)), 2.0);
  float ridge2 = pow(1.0 - abs(sin(phase2 * 0.5)), 2.0);

  vec3 theme = vec3(u_theme_r, u_theme_g, u_theme_b);
  vec3 light_tint = mix(vec3(0.78, 0.88, 1.0), theme, 0.34);
  vec3 c0 = mix(vec3(u_monet_0_r, u_monet_0_g, u_monet_0_b), light_tint, 0.08 * light_mode);
  vec3 c1 = mix(vec3(u_monet_1_r, u_monet_1_g, u_monet_1_b), light_tint, 0.08 * light_mode);
  vec3 c2 = mix(vec3(u_monet_2_r, u_monet_2_g, u_monet_2_b), light_tint, 0.08 * light_mode);
  vec3 k0 = mix(vec3(u_complement_0_r, u_complement_0_g, u_complement_0_b), light_tint, 0.14 * light_mode);
  vec3 k1 = mix(vec3(u_complement_1_r, u_complement_1_g, u_complement_1_b), light_tint, 0.14 * light_mode);
  vec3 k2 = mix(vec3(u_complement_2_r, u_complement_2_g, u_complement_2_b), light_tint, 0.14 * light_mode);

  float t = clamp(mix(uv.y, fold, 0.55) + (fold2 - 0.5) * 0.25, 0.0, 1.0);
  vec3 color = gradient_color(t, c0, c1, c2);

  // 互补色只在次褶皱的鼓起处渗入，像另一股液体卷进来。
  vec3 accent = gradient_color(fold2, k0, k1, k2);
  float accent_mix = smoothstep(0.55, 1.0, fold2) * smoothstep(0.15, 0.85, n)
    * mix(0.34, 0.24, light_mode) * (0.6 + 0.4 * intensity);
  color = mix(color, accent, accent_mix);

  color = mix(color, theme, (0.08 + 0.14 * intensity) * mix(1.0, 0.68, light_mode));

  // 褶皱明暗：谷暗峰亮，给出曲面的体积感；浅色模式下收一点对比。
  float shade = mix(0.72, 1.10, smoothstep(0.0, 1.0, mix(fold * 0.75 + fold2 * 0.25, ridge * 0.75 + ridge2 * 0.25, 0.6)));
  color *= mix(shade, 1.0 + (shade - 1.0) * 0.85, light_mode);

  // 光泽：贴着尖脊的窄亮线 + 一层宽而柔的反光。
  float crest = 1.0 - abs(sin(phase * 0.5 + 0.2));
  float sheen = pow(crest, 20.0) * 0.80 + pow(crest, 5.0) * 0.20;
  float sheen2 = pow(1.0 - abs(sin(phase2 * 0.5 + 0.16)), 24.0) * 0.40;
  vec3 highlight = mix(mix(vec3(0.94, 0.97, 1.0), light_tint, 0.35), mix(theme, c1, 0.5), 0.18);
  color = mix(color, highlight, clamp((sheen + sheen2) * (0.30 + 0.25 * intensity) * mix(1.0, 0.75, light_mode), 0.0, 1.0));

  // 流麻亮片：格子取在扭曲后的流动坐标里，颗粒随流体漂移、被拉成细长亮片；
  // 每颗按各自节奏闪烁，主要聚在亮脊上；颜色取互补色板并偏白。
  vec2 gp = q * 40.0;
  vec2 cell = floor(gp);
  vec2 cf = gp - cell;
  float hb = dot(cell, vec2(12.9898, 78.233));
  vec4 gr = fract(sin(vec4(hb, hb + 1.7, hb + 3.1, hb + 5.3)) * 43758.5453123);
  float band = clamp(ridge * 0.8 + pow(crest, 3.0) * 0.5, 0.0, 1.0);
  float present = step(0.97 - 0.35 * band, gr.x);
  float rad = 0.10 + 0.10 * gr.w;
  float dist = length(cf - (gr.yz * 0.6 + 0.2));
  float grain = ((1.0 - smoothstep(rad * 0.25, rad, dist)) +
    0.35 * (1.0 - smoothstep(rad, rad * 3.2, dist))) * present;
  float twinkle = pow(0.5 + 0.5 * sin(time * (1.5 + 3.0 * gr.w) + gr.x * 40.0), 6.0);
  vec3 grain_color = mix(vec3(1.0), min(gradient_color(gr.w, k0, k1, k2) * 1.7, vec3(1.6)), 0.65);
  color += grain_color * grain * twinkle * (0.25 + 0.75 * band) * mix(0.75, 0.45, light_mode);

  color = saturate_color(color, mix(mix(1.08, 1.26, intensity), mix(1.30, 1.50, intensity), light_mode));
  color = mix(color, light_tint, (0.045 + 0.055 * intensity) * light_mode);

  vec2 centered = uv - vec2(0.5);
  float vignette = smoothstep(0.92, 0.24, dot(centered, centered));
  color *= mix(
    mix(0.82, 1.04, vignette),
    mix(0.90, 1.06, vignette),
    light_mode
  );

  float alpha = texture(u_texture, uv).a * u_opacity;
  frag_color = vec4(clamp(color, 0.0, 1.0), alpha);
}
