#version 450

layout(location = 0) in vec2 inTexCoord;
layout(location = 1) in vec4 inColor;

layout(location = 0) out vec4 outColor;

layout(set = 2, binding = 0) uniform sampler2D texSampler;

layout(set = 3, binding = 0) uniform UBO {
    float brightness;
    float contrast;
    int is_text_or_color;
} ubo;

void main() {
    vec4 color = texture(texSampler, inTexCoord) * inColor;
    if (ubo.is_text_or_color == 0) {
        // Apply brightness/contrast on GPU for images
        color.rgb = (color.rgb - 0.5) * ubo.contrast + 0.5 + ubo.brightness;
    }
    outColor = color;
}
