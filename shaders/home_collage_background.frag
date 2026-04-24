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

vec3 saturate_color(vec3 color, float saturation) {
  float gray = dot(color, vec3(0.299, 0.587, 0.114));
  return mix(vec3(gray), color, saturation);
}

float random(vec2 st) {
  return fract(sin(dot(st, vec2(12.9898, 78.233))) * 43758.5453123);
}

float noise(vec2 st) {
  vec2 i = floor(st);
  vec2 f = fract(st);

  float a = random(i);
  float b = random(i + vec2(1.0, 0.0));
  float c = random(i + vec2(0.0, 1.0));
  float d = random(i + vec2(1.0, 1.0));

  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}

float fbm(vec2 p) {
  float value = 0.0;
  float freq = 1.0;
  float amp = 0.5;
  for (int i = 0; i < 7; i++) {
    value += amp * noise((p - vec2(1.0)) * freq);
    freq *= 1.9;
    amp *= 0.6;
  }
  return value;
}

float pattern(vec2 p, float time) {
  vec2 a_pos = vec2(sin(time * 0.05), sin(time * 0.10)) * 6.0;
  float a = fbm(p * 3.0 + a_pos);

  vec2 b_pos = vec2(sin(time * 0.10), sin(time * 0.10));
  float b = fbm((p + a) * 0.5 + b_pos);

  vec2 c_pos = vec2(-0.6, -0.5) + vec2(sin(-time * 0.01), sin(time * 0.10)) * 2.0;
  return fbm((p + b) * 2.0 + c_pos);
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
  float aspect = u_size.x / u_size.y;
  float intensity = clamp(u_intensity, 0.0, 1.0);
  float light_mode = 1.0 - step(0.5, u_is_dark_mode);
  float time = u_time * mix(0.70, 1.25, intensity);
  float fluid_speed = 2.0;
  float drift_time = time / fluid_speed;

  vec2 p = (frag_coord * 4.0 - u_size) / min(u_size.x, u_size.y);
  vec2 detail_p = uv;
  detail_p.x *= aspect;
  float organic = pow(pattern(detail_p * mix(1.35, 2.25, intensity), time), 2.0);
  vec2 swirl = vec2(
    sin(drift_time * 0.37),
    cos(drift_time * 0.29)
  );
  vec2 counter_swirl = vec2(
    cos(drift_time * 0.23 + 1.7),
    sin(drift_time * 0.31 - 0.8)
  );
  vec2 flow = p + swirl * 0.18;
  for (int i = 1; i < 10; i++) {
    float fi = float(i);
    float direction = mix(-1.0, 1.0, step(0.5, fract(fi * 0.5)));
    vec2 drift = mix(swirl, counter_swirl, fract(fi * 0.37));
    vec2 coupling = vec2(
      sin(flow.y * 0.72 + flow.x * 0.28 + drift_time * 0.21 + organic * 2.2),
      cos(flow.x * 0.68 - flow.y * 0.32 - drift_time * 0.18 + organic * 1.7)
    );
    vec2 next = flow + drift * time * mix(0.016, 0.040, intensity);
    next.x += 0.30 / fi * sin(fi * flow.y + direction * drift_time * (0.70 + 0.06 * fi) + 0.3 * fi);
    next.y += 0.52 / fi * sin(fi * flow.x - direction * drift_time * (0.58 + 0.05 * fi) + 0.3 * (fi + 10.0));
    next += vec2(
      sin(flow.x * 0.8 - flow.y * 0.6 + drift_time * 0.42),
      cos(flow.y * 0.7 + flow.x * 0.5 - drift_time * 0.36)
    ) * (0.028 / fi) * mix(0.45, 1.0, intensity);
    next += coupling * (0.022 / fi) * mix(0.35, 1.0, intensity);
    next.y -= 0.5;
    flow = next;
  }

  vec3 c0 = mix(vec3(u_monet_0_r, u_monet_0_g, u_monet_0_b), vec3(1.0), 0.48 * light_mode);
  vec3 c1 = mix(vec3(u_monet_1_r, u_monet_1_g, u_monet_1_b), vec3(1.0), 0.48 * light_mode);
  vec3 c2 = mix(vec3(u_monet_2_r, u_monet_2_g, u_monet_2_b), vec3(1.0), 0.48 * light_mode);
  vec3 k0 = mix(vec3(u_complement_0_r, u_complement_0_g, u_complement_0_b), vec3(1.0), 0.62 * light_mode);
  vec3 k1 = mix(vec3(u_complement_1_r, u_complement_1_g, u_complement_1_b), vec3(1.0), 0.62 * light_mode);
  vec3 k2 = mix(vec3(u_complement_2_r, u_complement_2_g, u_complement_2_b), vec3(1.0), 0.62 * light_mode);
  vec3 theme = vec3(u_theme_r, u_theme_g, u_theme_b);

  vec2 coupled_flow = flow + vec2(
    sin(flow.y * 0.64 + organic * 3.2 + drift_time * 0.17),
    cos(flow.x * 0.58 - organic * 2.6 - drift_time * 0.13)
  ) * mix(0.10, 0.28, intensity);
  vec2 flowed_uv = uv + vec2(
    sin(coupled_flow.x + time * 0.35),
    sin(coupled_flow.y - time * 0.25)
  ) * mix(0.035, 0.135, intensity);
  flowed_uv.x = (flowed_uv.x - 0.5) * aspect + 0.5;

  float fine = fbm(flowed_uv * mix(8.0, 15.0, intensity) + flow * 0.18 + time * 0.18);
  float micro = fbm(flowed_uv * mix(20.0, 36.0, intensity) - flow * 0.10 - time * 0.10);
  float grad_a = flowed_uv.y + sin(coupled_flow.x * 0.65 + time * 0.40) * 0.22;
  float grad_b = flowed_uv.x + cos(coupled_flow.y * 0.55 - time * 0.28) * 0.18;
  float t = clamp(
    mix(grad_a, grad_b, 0.38) +
    (organic - 0.5) * mix(0.18, 0.34, intensity) +
    (fine - 0.5) * mix(0.08, 0.18, intensity),
    0.0,
    1.0
  );

  vec3 base = gradient_color(t, c0, c1, c2);
  vec3 contrast = gradient_color(
    clamp(1.0 - t + sin(coupled_flow.x + coupled_flow.y + organic * 1.4) * 0.14, 0.0, 1.0),
    k0,
    k1,
    k2
  );
  vec3 secondary = gradient_color(
    clamp(t + cos(coupled_flow.x * 0.7 - coupled_flow.y + fine * 1.8) * 0.12, 0.0, 1.0),
    c2,
    k0,
    c1
  );
  float vein_raw = 0.5 + 0.5 * sin(
    coupled_flow.x * 1.4 +
    coupled_flow.y * 1.1 +
    organic * mix(4.0, 9.0, intensity) +
    fine * 2.4 +
    time * 0.9
  );
  float vein = smoothstep(0.16, 0.88, vein_raw);
  float blend_softness = smoothstep(0.12, 0.86, organic + fine * 0.34);
  float contrast_mix = vein * blend_softness * mix(0.18 + 0.24 * intensity, 0.08 + 0.14 * intensity, light_mode);
  float secondary_mix = (1.0 - vein) * (0.55 + 0.45 * blend_softness) * mix(0.08 + 0.16 * intensity, 0.04 + 0.08 * intensity, light_mode);
  vec3 color = mix(base, contrast, contrast_mix);
  color = mix(color, secondary, secondary_mix);
  float ridge = smoothstep(0.66, 0.98, vein_raw) * smoothstep(0.22, 0.78, organic);
  float speckle = smoothstep(mix(0.78, 0.86, light_mode), 1.0, micro + fine * 0.24);
  vec3 highlight = mix(vec3(1.0), mix(theme, c1, 0.55), mix(0.18, 0.34, light_mode));
  color = mix(color, theme, (0.04 + 0.10 * intensity) * mix(1.0, 0.45, light_mode));
  color = mix(color, highlight, ridge * (0.035 + 0.075 * intensity) * mix(1.0, 0.52, light_mode));
  color *= 0.92 + organic * mix(0.18, 0.30, intensity);
  color += speckle * (0.018 + 0.038 * intensity) * mix(1.0, 0.72, light_mode);
  color = saturate_color(color, mix(mix(1.08, 1.30, intensity), mix(1.00, 1.10, intensity), light_mode));
  color = mix(color, vec3(1.0), (0.32 + 0.22 * intensity) * light_mode);

  vec2 centered = uv - vec2(0.5);
  float vignette = smoothstep(0.92, 0.24, dot(centered, centered));
  color *= mix(
    mix(0.80, 1.05, vignette),
    mix(0.98, 1.04, vignette),
    light_mode
  );

  float alpha = texture(u_texture, uv).a * u_opacity;
  frag_color = vec4(clamp(color, 0.0, 1.0), alpha);
}
