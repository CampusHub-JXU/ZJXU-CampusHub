#include <flutter/runtime_effect.glsl>

uniform vec2 u_size;
uniform sampler2D u_texture;
uniform float u_time;
uniform float u_intensity;
uniform float u_theme_r;
uniform float u_theme_g;
uniform float u_theme_b;
uniform float u_opacity;
uniform float u_is_dark_mode;

out vec4 frag_color;

const float PI = 3.14159265359;
const float INV_PI = 0.31830988618;

float random(float x) {
  return fract(sin(x * 12.9898) * 43758.5453);
}

float srandom(float x) {
  return 2.0 * random(x) - 1.0;
}

mat2 rotate(float r) {
  float c = cos(r);
  float s = sin(r);
  return mat2(c, s, -s, c);
}

float luminance(vec3 color) {
  return dot(color, vec3(0.299, 0.587, 0.114));
}

vec3 saturate_color(vec3 color, float saturation) {
  float gray = luminance(color);
  return mix(vec3(gray), color, saturation);
}

void main() {
  vec2 frag_coord = FlutterFragCoord().xy;
  vec2 uv = frag_coord / u_size;
  vec2 st = (2.0 * frag_coord - u_size) / min(u_size.x, u_size.y);
  float intensity = clamp(u_intensity, 0.0, 1.0);
  float light_mode = 1.0 - step(0.5, u_is_dark_mode);
  float time = u_time * (0.65 + 0.55 * intensity);

  vec2 warped = st;
  for (float i = 1.0; i <= 5.0; i += 1.0) {
    warped.y += 0.5 * sin(
      0.5 * i * warped.x + 0.1 * time + random(i * 1.53)
    );
    warped *= rotate(i * 5.0 * PI * srandom(i * 1.42));
  }

  vec2 ribbon_space = vec2(warped.y, -warped.x);
  float y = ribbon_space.y * mix(72.0, 112.0, intensity);
  float band = floor(y * INV_PI);
  float ribbon_mask = pow(abs(sin(y)), mix(1.25, 0.95, intensity));

  vec2 texture_uv = uv;
  texture_uv.x += (random(band + 1.7) - 0.5) * mix(0.05, 0.20, intensity);
  texture_uv.y += (random(band + 8.3) - 0.5) * mix(0.018, 0.07, intensity);
  texture_uv += vec2(
    sin(ribbon_space.y * 0.7 + time * 0.16),
    sin(ribbon_space.x * 0.8 - time * 0.12)
  ) * mix(0.006, 0.028, intensity);

  vec4 sampled = texture(u_texture, fract(texture_uv));
  vec3 src = sampled.rgb * mix(
    mix(0.54, 0.38, intensity),
    mix(1.02, 0.92, intensity),
    light_mode
  );
  vec3 theme = vec3(u_theme_r, u_theme_g, u_theme_b);

  vec3 ribbon = saturate_color(src, mix(1.20, 1.05, intensity));
  ribbon = mix(ribbon, theme * 0.68, 0.04 + 0.10 * intensity);
  ribbon *= ribbon_mask;

  float seam = smoothstep(0.04, 0.00, ribbon_mask);
  ribbon *= 1.0 - seam * (0.12 + 0.18 * intensity);

  float highlight = pow(ribbon_mask, mix(7.0, 5.4, intensity));
  ribbon = mix(ribbon, vec3(0.92, 0.88, 1.0), highlight * (0.08 + 0.10 * intensity));

  vec3 paper = mix(vec3(0.0), vec3(1.0), light_mode);
  vec3 color = mix(paper, ribbon, mix(1.0, 0.58, light_mode));
  vec2 centered = uv - vec2(0.5);
  float vignette = smoothstep(0.88, 0.20, dot(centered, centered));
  color *= mix(
    mix(0.72, 0.94, vignette),
    mix(0.99, 1.04, vignette),
    light_mode
  );

  frag_color = vec4(clamp(color, 0.0, 1.0), sampled.a * u_opacity);
}
