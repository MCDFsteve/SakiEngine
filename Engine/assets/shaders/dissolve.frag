#version 460 core
#include <flutter/runtime_effect.glsl>

uniform float progress;
uniform vec2 uSize;
uniform vec2 u_imageFrom_dimensions;
uniform vec2 u_imageTo_dimensions;
uniform vec2 uOffset;
uniform sampler2D imageFrom;
uniform sampler2D imageTo;
uniform float overallAlpha;

out vec4 fragColor;

void main() {
    // 采样品质由引擎侧 setImageSampler(filterQuality) 控制：
    // - FilterQuality.none → 最近邻（像素风立绘保持锐利）
    // - FilterQuality.high → 双线性（平滑过渡）
    vec2 uv = (FlutterFragCoord().xy - uOffset) / uSize;
    // 按各图尺寸做半像素内缩，避免采样到边缘外（双线性模式下的边缘渗色）。
    vec2 from_halfTexel = 0.5 / max(u_imageFrom_dimensions, vec2(1.0));
    vec2 to_halfTexel = 0.5 / max(u_imageTo_dimensions, vec2(1.0));
    vec2 from_uv = clamp(uv, from_halfTexel, vec2(1.0) - from_halfTexel);
    vec2 to_uv = clamp(uv, to_halfTexel, vec2(1.0) - to_halfTexel);

    vec4 from_color = texture(imageFrom, from_uv);
    vec4 to_color = texture(imageTo, to_uv);

    fragColor = mix(from_color, to_color, progress) * overallAlpha;
}
