#version 450

layout(location = 0) in vec4 inRect;        // x, y, w, h (physical px)
layout(location = 1) in vec4 inRadii;       // tr, br, tl, bl (physical px)
layout(location = 2) in vec4 inBorder;      // left, top, right, bottom (px)
layout(location = 3) in vec4 inFillColor;   // RGBA normalized
layout(location = 4) in vec4 inBorderColor; // RGBA normalized
layout(location = 5) in vec2 inParams;      // x: softness (px), y: flags

layout(std140, set = 1, binding = 0) uniform UiSdfVertUBO {
    vec2 win_dims;
    vec2 padding;
}
ubo;

layout(location = 0) out vec2 outLocalPos;
layout(location = 1) out vec2 outHalfSize;
layout(location = 2) out vec4 outRadii;
layout(location = 3) out vec4 outBorder;
layout(location = 4) out vec4 outFillColor;
layout(location = 5) out vec4 outBorderColor;
layout(location = 6) out vec2 outScreenUv;
layout(location = 7) out vec2 outParams;

void main() {
    const vec2 corners[6] =
        vec2[](vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(0.0, 1.0), vec2(1.0, 0.0),
               vec2(1.0, 1.0), vec2(0.0, 1.0));
    vec2 c = corners[gl_VertexIndex];

    // Expand quad by 1px (+ softness) per side so AA/shadow fringes never clip.
    float pad = 1.0 + max(inParams.x, 0.0);
    vec2 half_size = inRect.zw * 0.5;
    vec2 center = inRect.xy + half_size;
    vec2 local = (c - 0.5) * (inRect.zw + vec2(pad * 2.0));
    vec2 pos = center + local;

    vec2 uv = pos / ubo.win_dims;
    vec2 ndc = vec2(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);

    outLocalPos = local;
    outHalfSize = half_size;
    outRadii = inRadii;
    outBorder = inBorder;
    outFillColor = inFillColor;
    outBorderColor = inBorderColor;
    outScreenUv = uv;
    outParams = inParams;

    gl_Position = vec4(ndc, 0.0, 1.0);
}
