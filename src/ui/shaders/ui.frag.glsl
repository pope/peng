#version 450

layout(location = 0) in vec2 inTexCoord;
layout(location = 1) in vec4 inColor;

layout(location = 0) out vec4 outColor;

layout(set = 2, binding = 0) uniform sampler2D texSampler;

layout(std140, set = 3, binding = 0) uniform UiUBO {
    int is_blurred_surface; // 0 = standard UI element (rectangles, text,
                            // icons), 1 = frosted glass surface
    float padding1;
    float padding2;
    float padding3;
}
ubo;

void main() {
    vec4 texColor = texture(texSampler, inTexCoord);
    vec4 color = texColor * inColor;

    // Frosted glass blurred surface:
    // When is_blurred_surface == 1, texColor is sampled from blur_texture.
    // inColor provides the panel's tint color and its alpha.
    // We mix blurred background with tint color based on inColor.a.
    float isBlur = step(0.5, float(ubo.is_blurred_surface));
    vec3 frostedColor = mix(texColor.rgb, inColor.rgb, inColor.a);
    color.rgb = mix(color.rgb, frostedColor, isBlur);
    color.a = mix(color.a, min(1.0, inColor.a * (255.0 / 245.0)), isBlur);

    outColor = color;
}
