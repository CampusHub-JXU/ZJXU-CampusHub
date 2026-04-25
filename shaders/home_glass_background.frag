#include <flutter/runtime_effect.glsl>

uniform vec2 u_size;
uniform sampler2D u_texture;
uniform float u_intensity;
uniform float u_levels;
uniform float u_theme_r;
uniform float u_theme_g;
uniform float u_theme_b;
uniform float u_opacity;
uniform float u_is_dark_mode;

out vec4 frag_color;

float luminance(vec3 color) {
  return dot(color, vec3(0.299, 0.587, 0.114));
}

float hash(vec2 p) {
  return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

vec3 saturate_color(vec3 color, float saturation) {
  float gray = luminance(color);
  return mix(vec3(gray), color, saturation);
}

vec3 contrast_color(vec3 color, float contrast) {
  return (color - 0.5) * contrast + 0.5;
}

vec3 soft_blur_sample(vec2 uv, vec2 px, float radius) {
  vec3 color = texture(u_texture, uv).rgb * 0.24;
  color += texture(u_texture, uv + px * vec2( radius,  0.0)).rgb * 0.12;
  color += texture(u_texture, uv + px * vec2(-radius,  0.0)).rgb * 0.12;
  color += texture(u_texture, uv + px * vec2( 0.0,  radius)).rgb * 0.12;
  color += texture(u_texture, uv + px * vec2( 0.0, -radius)).rgb * 0.12;
  color += texture(u_texture, uv + px * vec2( radius * 0.72,  radius * 0.72)).rgb * 0.07;
  color += texture(u_texture, uv + px * vec2(-radius * 0.72,  radius * 0.72)).rgb * 0.07;
  color += texture(u_texture, uv + px * vec2( radius * 0.72, -radius * 0.72)).rgb * 0.07;
  color += texture(u_texture, uv + px * vec2(-radius * 0.72, -radius * 0.72)).rgb * 0.07;
  return color;
}

float edge_sobel(vec2 uv, vec2 px) {
  float tl = luminance(texture(u_texture, uv + px * vec2(-1.0, -1.0)).rgb);
  float  t = luminance(texture(u_texture, uv + px * vec2( 0.0, -1.0)).rgb);
  float tr = luminance(texture(u_texture, uv + px * vec2( 1.0, -1.0)).rgb);
  float  l = luminance(texture(u_texture, uv + px * vec2(-1.0,  0.0)).rgb);
  float  r = luminance(texture(u_texture, uv + px * vec2( 1.0,  0.0)).rgb);
  float bl = luminance(texture(u_texture, uv + px * vec2(-1.0,  1.0)).rgb);
  float  b = luminance(texture(u_texture, uv + px * vec2( 0.0,  1.0)).rgb);
  float br = luminance(texture(u_texture, uv + px * vec2( 1.0,  1.0)).rgb);

  float gx = -tl - 2.0 * l - bl + tr + 2.0 * r + br;
  float gy = -tl - 2.0 * t - tr + bl + 2.0 * b + br;
  return smoothstep(0.10, 0.38, length(vec2(gx, gy)));
}

void main() {
  vec2 uv = FlutterFragCoord().xy / u_size;
  vec2 px = 1.0 / u_size;
  float intensity = clamp(u_intensity, 0.0, 1.0);
  float light_mode = 1.0 - step(0.5, u_is_dark_mode);

  vec4 src = texture(u_texture, uv);
  vec3 theme = vec3(u_theme_r, u_theme_g, u_theme_b);

  float wave_a = sin((uv.y * 8.0 + uv.x * 2.8) + intensity * 0.8);
  float wave_b = sin((uv.x * 7.0 - uv.y * 3.2) - intensity * 0.6);
  vec2 refract_uv = uv + px * vec2(wave_a, wave_b) * (0.8 + 2.8 * intensity);

  float radius = mix(3.0, 16.0, intensity);
  vec3 blurred = soft_blur_sample(refract_uv, px, radius);

  float levels = max(u_levels, 4.0);
  float quantize_mix = 0.10 + 0.18 * intensity;
  vec3 quantized = floor(blurred * levels + 0.5) / levels;
  vec3 glass = mix(blurred, quantized, quantize_mix);

  glass = saturate_color(glass, mix(1.08, 0.78, intensity));
  glass = contrast_color(glass, mix(1.04, 0.88, intensity));

  float lum = luminance(glass);
  vec3 theme_wash = mix(vec3(lum), theme, mix(0.58, 0.72, light_mode));
  glass = mix(glass, theme_wash, (0.24 + 0.40 * intensity) * mix(1.0, 0.78, light_mode));
  glass = mix(glass, mix(vec3(0.84, 0.92, 1.0), theme, 0.24), mix(0.05 + 0.12 * intensity, 0.06 + 0.09 * intensity, light_mode));

  float edge = edge_sobel(uv, px);
  glass = mix(glass, glass * mix(0.82, 0.94, light_mode), edge * (0.05 + 0.12 * intensity));

  vec2 centered = uv - vec2(0.5);
  float vignette = smoothstep(0.88, 0.22, dot(centered, centered));
  glass *= mix(
    mix(0.88, 1.05, vignette),
    mix(0.98, 1.08, vignette),
    light_mode
  );

  float grain = hash(FlutterFragCoord().xy) - 0.5;
  glass += grain * (0.006 + 0.010 * intensity);

  vec3 color = mix(src.rgb, clamp(glass, 0.0, 1.0), intensity);
  color = mix(color, mix(mix(vec3(0.82, 0.91, 1.0), theme, 0.26), color, 0.74 + 0.18 * intensity), light_mode);
  frag_color = vec4(color, src.a * u_opacity);
}
