#version 460 core

precision mediump float;

#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
uniform sampler2D uTexture;

out vec4 fragColor;

void main() {
  vec2 uv = FlutterFragCoord().xy / uSize;
  vec2 px = 1.0 / uSize;

  vec4 c = texture(uTexture, uv);
  vec4 n = texture(uTexture, uv + vec2(0.0, -px.y));
  vec4 s = texture(uTexture, uv + vec2(0.0, px.y));
  vec4 e = texture(uTexture, uv + vec2(px.x, 0.0));
  vec4 w = texture(uTexture, uv + vec2(-px.x, 0.0));
  vec4 ne = texture(uTexture, uv + vec2(px.x, -px.y));
  vec4 nw = texture(uTexture, uv + vec2(-px.x, -px.y));
  vec4 se = texture(uTexture, uv + vec2(px.x, px.y));
  vec4 sw = texture(uTexture, uv + vec2(-px.x, px.y));

  // 十字を強め、斜めを弱めたアンシャープ（文字境界の強調）。
  vec4 blur = (n + s + e + w) * 0.15 + (ne + nw + se + sw) * 0.05 + c * 0.20;
  vec4 sharp = c + (c - blur) * 1.6;
  fragColor = vec4(clamp(sharp.rgb, 0.0, 1.0), c.a);
}
