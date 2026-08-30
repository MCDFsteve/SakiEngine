#version 460 core
#include <flutter/runtime_effect.glsl>

uniform float progress;
uniform vec2 u_imageFrom_size;
uniform vec2 u_imageFrom_dimensions;
uniform vec2 u_imageTo_size;
uniform vec2 u_imageTo_dimensions;
uniform vec2 u_imageFrom_offset;
uniform vec2 u_imageTo_offset;
uniform sampler2D imageFrom;
uniform sampler2D imageTo;
uniform float overallAlpha;

out vec4 fragColor;

void main() {
    // 采样品质由引擎侧 setImageSampler(filterQuality) 控制：
    // - FilterQuality.none → 最近邻（像素风立绘保持锐利）
    // - FilterQuality.high → 双线性（平滑过渡）
    vec2 frag_coord = FlutterFragCoord().xy;
    vec2 from_uv = (frag_coord - u_imageFrom_offset) / u_imageFrom_size;
    vec2 to_uv = (frag_coord - u_imageTo_offset) / u_imageTo_size;
    bool inside_from = all(greaterThanEqual(from_uv, vec2(0.0))) &&
                       all(lessThanEqual(from_uv, vec2(1.0)));
    bool inside_to = all(greaterThanEqual(to_uv, vec2(0.0))) &&
                     all(lessThanEqual(to_uv, vec2(1.0)));

    // 按各图尺寸做半像素内缩，避免采样到边缘外（双线性模式下的边缘渗色）。
    vec2 from_halfTexel = 0.5 / max(u_imageFrom_dimensions, vec2(1.0));
    vec2 to_halfTexel = 0.5 / max(u_imageTo_dimensions, vec2(1.0));
    from_uv = clamp(from_uv, from_halfTexel, vec2(1.0) - from_halfTexel);
    to_uv = clamp(to_uv, to_halfTexel, vec2(1.0) - to_halfTexel);

    vec4 from_color = vec4(0.0);
    vec4 to_color = vec4(0.0);
    if (inside_from) {
        from_color = texture(imageFrom, from_uv);
    }
    if (inside_to) {
        to_color = texture(imageTo, to_uv);
    }

    fragColor = mix(from_color, to_color, progress) * overallAlpha;
}
