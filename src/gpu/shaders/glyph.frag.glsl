#version 450

layout(location = 0) in vec2 inTexCoord;
layout(location = 1) in vec4 inColor;

layout(location = 0) out vec4 outColor;

layout(set = 2, binding = 0) uniform sampler2D texSampler;

void main() {
    float alpha = texture(texSampler, inTexCoord).r;
    outColor = vec4(inColor.rgb, inColor.a * alpha);
}
