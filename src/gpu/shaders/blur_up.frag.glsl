#version 450

layout(location = 0) in vec2 inTexCoord;
layout(location = 1) in vec4 inColor;

layout(location = 0) out vec4 outColor;

layout(set = 2, binding = 0) uniform sampler2D texSampler;

layout(std140, set = 3, binding = 0) uniform BlurUBO {
    vec2 texel_size; // 1.0 / source_resolution
    float radius;    // blur offset multiplier
    float padding;
}
ubo;

void main() {
    vec2 uv = inTexCoord;
    vec2 d = ubo.texel_size * 0.5 * ubo.radius;

    // 8-tap Dual Kawase upsample / diffusion filter
    vec4 sum = vec4(0.0);
    sum += texture(texSampler, uv + vec2(-d.x * 2.0, 0.0));
    sum += texture(texSampler, uv + vec2(-d.x, d.y)) * 2.0;
    sum += texture(texSampler, uv + vec2(0.0, d.y * 2.0));
    sum += texture(texSampler, uv + vec2(d.x, d.y)) * 2.0;
    sum += texture(texSampler, uv + vec2(d.x * 2.0, 0.0));
    sum += texture(texSampler, uv + vec2(d.x, -d.y)) * 2.0;
    sum += texture(texSampler, uv + vec2(0.0, -d.y * 2.0));
    sum += texture(texSampler, uv + vec2(-d.x, -d.y)) * 2.0;

    outColor = sum * (1.0 / 12.0);
}
