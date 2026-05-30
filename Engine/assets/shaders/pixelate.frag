#version 460 core
#include <flutter/runtime_effect.glsl>

uniform float blockSize;
uniform vec2 uSize;
uniform vec2 uImageDimensions;
uniform vec2 uOffset;
uniform sampler2D image;
uniform float overallAlpha;

out vec4 fragColor;

void main() {
    if (uSize.x <= 0.0 || uSize.y <= 0.0 || uImageDimensions.x <= 0.0 || uImageDimensions.y <= 0.0) {
        fragColor = vec4(0.0);
        return;
    }

    vec2 localCoord = FlutterFragCoord().xy - uOffset;
    if (localCoord.x < 0.0 || localCoord.y < 0.0 || localCoord.x > uSize.x || localCoord.y > uSize.y) {
        fragColor = vec4(0.0);
        return;
    }

    float scale = max(uSize.x / uImageDimensions.x, uSize.y / uImageDimensions.y);
    vec2 scaledImageSize = uImageDimensions * scale;
    vec2 imageOffset = (uSize - scaledImageSize) * 0.5;
    vec2 blockCenter = (floor(localCoord / max(blockSize, 1.0)) + vec2(0.5)) * max(blockSize, 1.0);
    vec2 imageCoord = (blockCenter - imageOffset) / scale;
    vec2 uv = imageCoord / uImageDimensions;

    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        fragColor = vec4(0.0);
        return;
    }

    fragColor = texture(image, uv) * overallAlpha;
}
