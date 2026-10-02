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

  // 液态扭曲：每层频率递增、幅度按 fi^1.45 衰减（高层压得更狠，弧线不出尖角），相位随时间缓慢漂移。
  float warp = mix(0.50, 0.92, intensity);
  for (int i = 1; i < 6; i++) {
    float fi = float(i);
    q += (warp / pow(fi, 1.45)) * vec2(
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
  float shade = mix(0.76, 1.07, smoothstep(0.0, 1.0, fold * 0.75 + fold2 * 0.25));
  color *= mix(shade, 1.0 + (shade - 1.0) * 0.85, light_mode);

  // 光泽：相位偏移后的窄高光（落在褶皱斜面上）+ 一层宽而柔的反光。
  float crest = sin(phase + 0.9);
  float sheen = pow(max(crest, 0.0), 8.0) * 0.55 + pow(max(crest, 0.0), 2.0) * 0.16;
  float sheen2 = pow(max(sin(phase2 + 0.7), 0.0), 18.0) * 0.35;
  vec3 highlight = mix(mix(vec3(0.94, 0.97, 1.0), light_tint, 0.35), mix(theme, c1, 0.5), 0.18);
  color = mix(color, highlight, clamp((sheen + sheen2) * (0.30 + 0.25 * intensity) * mix(1.0, 0.75, light_mode), 0.0, 1.0));

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
