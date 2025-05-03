#version 300 es
precision mediump float;

// Include Flutter built-ins
#include <flutter/runtime_effect.glsl>

// Uniforms supplied by the DissolvingSprite component
uniform sampler2D texA; // Current texture (Sprite A)
uniform sampler2D texB; // New texture (Sprite B)
uniform float progress; // Transition progress: 0.0 (A) to 1.0 (B)
uniform vec2 uResolution; // Resolution (size) of the rendering area

// Input varying from vertex shader (texture coordinates) - REMOVED
// in vec2 vTexCoord;

// Output fragment color
out vec4 fragColor;

void main() {
  // Calculate UV coordinates from fragment coordinates and resolution
  // Make sure uResolution is not zero to avoid division by zero
  vec2 uv = vec2(0.0, 0.0);
  if (uResolution.x > 0.0 && uResolution.y > 0.0) {
    uv = FlutterFragCoord().xy / uResolution;
  }

  // Sample colors from both textures using the calculated UV
  vec4 colorA = texture(texA, uv);
  vec4 colorB = texture(texB, uv);

  // Linearly interpolate (mix) between the two colors based on progress
  fragColor = mix(colorA, colorB, progress);

  // You might want to handle alpha differently, e.g.,
  // ensure the result is fully opaque if either source is,
  // or simply mix the alpha as well (which mix does by default).
  // Example: fragColor.a = max(colorA.a, colorB.a);
} 