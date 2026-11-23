#version 450

layout(location = 0) in vec2 inLocalPos;
layout(location = 1) in vec2 inHalfSize;
layout(location = 2) in vec4 inRadii;
layout(location = 3) in vec4 inBorder;
layout(location = 4) in vec4 inFillColor;
layout(location = 5) in vec4 inBorderColor;
layout(location = 6) in vec2 inScreenUv;
layout(location = 7) in vec2 inParams;

layout(location = 0) out vec4 outColor;

layout(set = 2, binding = 0) uniform sampler2D texSampler;

// r = (top_right, bottom_right, top_left, bottom_left) in Y-down screen space.
float sdRoundedBox(vec2 p, vec2 b, vec4 r) {
    vec2 r_side = (p.x > 0.0) ? r.xy : r.zw;
    float rad = (p.y > 0.0) ? r_side.y : r_side.x;
    rad = min(rad, min(b.x, b.y));
    vec2 q = abs(p) - b + vec2(rad);
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - rad;
}

void main() {
    float softness = max(inParams.x, 0.0);
    float aa = 0.5 + softness;

    float d_outer = sdRoundedBox(inLocalPos, inHalfSize, inRadii);
    float outer_cov = smoothstep(aa, -aa, d_outer);
    if (outer_cov <= 0.0001) {
        discard;
    }

    int flags = int(inParams.y + 0.5);
    bool is_blur = (flags & 1) != 0;
    bool is_border_only = (flags & 2) != 0;
    bool is_dashed = (flags & 4) != 0;

    vec4 col = vec4(0.0);
    if (!is_border_only) {
        if (is_blur) {
            vec4 tex_col = texture(texSampler, inScreenUv);
            vec3 frosted = mix(tex_col.rgb, inFillColor.rgb, inFillColor.a);
            float frosted_a = min(1.0, inFillColor.a * (255.0 / 191.0));
            col = vec4(frosted, frosted_a * outer_cov);
        } else {
            col = vec4(inFillColor.rgb, inFillColor.a * outer_cov);
        }
    }

    if (any(greaterThan(inBorder, vec4(0.0)))) {
        float bl = inBorder.x;
        float bt = inBorder.y;
        float br = inBorder.z;
        float bb = inBorder.w;
        vec2 inner_off = vec2((bl - br) * 0.5, (bt - bb) * 0.5);
        vec2 raw_inner = inHalfSize - vec2((bl + br) * 0.5, (bt + bb) * 0.5);
        float border_cov = outer_cov;
        if (raw_inner.x > 0.0 && raw_inner.y > 0.0) {
            vec4 inner_radii =
                max(vec4(0.0), inRadii - vec4(max(br, bt), max(br, bb),
                                              max(bl, bt), max(bl, bb)));
            float d_inner =
                sdRoundedBox(inLocalPos - inner_off, raw_inner, inner_radii);
            border_cov = outer_cov * smoothstep(-0.5, 0.5, d_inner);
        }
        if (is_dashed && border_cov > 0.0) {
            float r = min(inRadii.z, min(inHalfSize.x, inHalfSize.y));
            float sx = max(inHalfSize.x - r, 0.0);
            float sy = max(inHalfSize.y - r, 0.0);
            float arc = 1.57079632 * r;
            vec2 ap = abs(inLocalPos);
            float q_pos;
            if (ap.x <= sx && ap.y >= sy) {
                q_pos = ap.x;
            } else if (ap.x >= sx && ap.y <= sy) {
                q_pos = sx + arc + (sy - ap.y);
            } else {
                vec2 cp = ap - vec2(sx, sy);
                q_pos = sx + atan(cp.x, cp.y) * r;
            }
            float period = max(max(bl, bt), 1.0) * 7.0;
            float phase = fract(q_pos / period);
            border_cov *=
                smoothstep(0.0, 0.05, phase) * smoothstep(0.62, 0.57, phase);
        }
        float ba = inBorderColor.a * border_cov;
        if (is_border_only) {
            col = vec4(inBorderColor.rgb, ba);
        } else if (ba > 0.0) {
            float out_a = ba + col.a * (1.0 - ba);
            vec3 out_rgb =
                (inBorderColor.rgb * ba + col.rgb * col.a * (1.0 - ba)) /
                max(out_a, 0.0001);
            col = vec4(out_rgb, out_a);
        }
    }

    if (col.a <= 0.0001) {
        discard;
    }
    outColor = col;
}
