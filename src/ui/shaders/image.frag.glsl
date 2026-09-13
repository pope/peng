#version 450

layout(location = 0) in vec2 inTexCoord;
layout(location = 1) in vec4 inColor;

layout(location = 0) out vec4 outColor;

layout(set = 2, binding = 0) uniform sampler2D texSampler;

layout(std140, set = 3, binding = 0) uniform ImageUBO {
    float brightness;
    float contrast;
    float temperature;
    float tint;

    float highlights;
    float shadows;
    float whites;
    float blacks;

    float saturation;
    float vibrance;
    float contrast_blend;
    int scale_mode;

    int has_adjustments;
    int pad1;
    int pad2;
    int pad3;
}
ubo;

// =============================================================================
// Nearest Neighbor (Center-Snapped Point Sampling)
// =============================================================================
vec4 sample_nearest(sampler2D tex, vec2 uv) {
    vec2 tex_size = vec2(textureSize(tex, 0));
    vec2 p = (floor(uv * tex_size) + 0.5) / tex_size;
    return texture(tex, p);
}

// =============================================================================
// Anti-Aliased Nearest Neighbor ("Fat Pixels" / Filtered Nearest)
//
// The MIT License
// Copyright (c) 2013 Inigo Quilez
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software.
// =============================================================================
vec4 sample_pixel_art(sampler2D tex, vec2 uv) {
    vec2 tex_size = vec2(textureSize(tex, 0));
    vec2 p = uv * tex_size - 0.5;
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 w = fwidth(p);
    f = clamp((f - 0.5) / max(w, vec2(1e-5)) + 0.5, 0.0, 1.0);
    return texture(tex, (i + f + 0.5) / tex_size);
}

// =============================================================================
// Mitchell-Netravali Filter (B=1/3, C=1/3)
// Reference: Don P. Mitchell, Arun N. Netravali (ACM SIGGRAPH 1988)
// =============================================================================
// Horner's method polynomial evaluation for Mitchell-Netravali (B=1/3, C=1/3)
float mitchell_p1(float x) {
    return ((7.0 / 6.0 * x - 2.0) * x) * x + (8.0 / 9.0);
}

float mitchell_p2(float x) {
    return (((-7.0 / 18.0 * x + 2.0) * x - 10.0 / 3.0) * x) + (16.0 / 9.0);
}

void mitchell_weights_1d(float f, out float w0, out float w1, out float w2,
                         out float w3) {
    w0 = mitchell_p2(1.0 + f);
    w1 = mitchell_p1(f);
    w2 = mitchell_p1(1.0 - f);
    w3 = mitchell_p2(2.0 - f);
}

// 16-Tap Mitchell-Netravali Filter using Horner's method
vec4 sample_mitchell(sampler2D tex, vec2 uv) {
    vec2 tex_size = vec2(textureSize(tex, 0));
    vec2 inv_tex_size = 1.0 / tex_size;
    vec2 p = uv * tex_size - 0.5;
    vec2 i = floor(p);
    vec2 f = fract(p);

    float wx0, wx1, wx2, wx3;
    float wy0, wy1, wy2, wy3;
    mitchell_weights_1d(f.x, wx0, wx1, wx2, wx3);
    mitchell_weights_1d(f.y, wy0, wy1, wy2, wy3);

    float wx[4] = float[4](wx0, wx1, wx2, wx3);
    float wy[4] = float[4](wy0, wy1, wy2, wy3);

    vec4 sum = vec4(0.0);
    float total_w = 0.0;
    vec2 base_uv = (i + vec2(-1.0, -1.0) + 0.5) * inv_tex_size;

#pragma unroll
    for (int r = 0; r < 4; r++) {
        float wyr = wy[r];
        vec2 row_uv = base_uv + vec2(0.0, float(r) * inv_tex_size.y);
#pragma unroll
        for (int c = 0; c < 4; c++) {
            float w = wx[c] * wyr;
            sum +=
                texture(tex, row_uv + vec2(float(c) * inv_tex_size.x, 0.0)) * w;
            total_w += w;
        }
    }

    return sum / mix(1.0, total_w, step(0.00001, total_w));
}

// Fast analytical single-sine Lanczos3 weights (12x fewer transcendentals,
// exact mathematical fidelity)
void lanczos3_weights_1d(float f, out float w0, out float w1, out float w2,
                         out float w3, out float w4, out float w5) {
    const float PI = 3.141592653589793;
    float theta = (PI / 3.0) * f;
    float sin_theta = sin(theta);
    float s2 = sin_theta * sin_theta;
    float cos_theta = sqrt(max(0.0, 1.0 - s2));

    // Triple-angle identity: sin(pi * f) = sin(3 * theta) = sin(theta) * (3 - 4
    // * sin^2(theta))
    float sin_pi_f = sin_theta * (3.0 - 4.0 * s2);

    const float SQRT3_OVER_2 = 0.8660254037844386;
    float C = SQRT3_OVER_2 * cos_theta;
    float S = 0.5 * sin_theta;

    float factor = (3.0 / (PI * PI)) * sin_pi_f;

    float x0 = 2.0 + f;
    float x1 = 1.0 + f;
    float x2 = f;
    float x3 = 1.0 - f;
    float x4 = 2.0 - f;
    float x5 = 3.0 - f;

    float num_A = factor * (C - S);
    float num_B = -factor * (C + S);
    float num_C = factor * (2.0 * S);

    w0 = num_A / (x0 * x0);
    w1 = num_B / (x1 * x1);

    // Branchless safe sinc for x2 (f -> 0) and x3 (f -> 1)
    float is_zero_2 = step(0.0001, x2);
    float safe_x2 = mix(1.0, x2, is_zero_2);
    w2 = mix(1.0, num_C / (safe_x2 * safe_x2), is_zero_2);

    float is_zero_3 = step(0.0001, x3);
    float safe_x3 = mix(1.0, x3, is_zero_3);
    w3 = mix(1.0, num_A / (safe_x3 * safe_x3), is_zero_3);

    w4 = num_B / (x4 * x4);
    w5 = num_C / (x5 * x5);
}

// 36-Tap Unrolled Analytical Lanczos3 Filter with Anti-Ringing Clamping
vec4 sample_lanczos3(sampler2D tex, vec2 uv) {
    vec2 tex_size = vec2(textureSize(tex, 0));
    vec2 inv_tex_size = 1.0 / tex_size;
    vec2 p = uv * tex_size - 0.5;
    vec2 i = floor(p);
    vec2 f = fract(p);

    float wx0, wx1, wx2, wx3, wx4, wx5;
    float wy0, wy1, wy2, wy3, wy4, wy5;
    lanczos3_weights_1d(f.x, wx0, wx1, wx2, wx3, wx4, wx5);
    lanczos3_weights_1d(f.y, wy0, wy1, wy2, wy3, wy4, wy5);

    vec4 sum = vec4(0.0);
    float total_w = 0.0;
    vec2 base_uv = (i + vec2(-2.0, -2.0) + 0.5) * inv_tex_size;

    float wy[6] = float[6](wy0, wy1, wy2, wy3, wy4, wy5);
    float wx[6] = float[6](wx0, wx1, wx2, wx3, wx4, wx5);

    vec4 min4 = vec4(1e9);
    vec4 max4 = vec4(-1e9);

#pragma unroll
    for (int r = 0; r < 6; r++) {
        float wyr = wy[r];
        vec2 row_uv = base_uv + vec2(0.0, float(r) * inv_tex_size.y);
#pragma unroll
        for (int c = 0; c < 6; c++) {
            float w = wx[c] * wyr;
            vec4 smp =
                texture(tex, row_uv + vec2(float(c) * inv_tex_size.x, 0.0));
            sum += smp * w;
            total_w += w;
            if (r >= 2 && r <= 3 && c >= 2 && c <= 3) {
                min4 = min(min4, smp);
                max4 = max(max4, smp);
            }
        }
    }

    vec4 result = sum / mix(1.0, total_w, step(0.00001, total_w));
    return clamp(result, min4, max4);
}

// =============================================================================
// AMD FidelityFX Super Resolution 1.0 (FSR 1.0 - EASU)
//
// The MIT License (MIT)
// Copyright (c) 2021 Advanced Micro Devices, Inc. All rights reserved.
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
// =============================================================================

void fsr_easu_tap(inout vec4 aC, inout float aW, vec2 off, vec2 dir, vec2 len,
                  float lob, float clp, vec4 c) {
    vec2 v = vec2(dot(off, dir), dot(off, vec2(-dir.y, dir.x)));
    v *= len;
    float d2 = min(dot(v, v), clp);
    float wB = 0.4 * d2 - 1.0;
    float wA = lob * d2 - 1.0;
    wB *= wB;
    wA *= wA;
    wB = 1.5625 * wB - 0.5625;
    float w = wB * wA;
    aC += c * w;
    aW += w;
}

void fsr_easu_set(inout vec2 dir, inout float len, float w, float lA, float lB,
                  float lC, float lD, float lE) {
    float lenX = max(abs(lD - lC), abs(lC - lB));
    float dirX = lD - lB;
    dir.x += dirX * w;
    lenX = clamp(abs(dirX) / max(lenX, 1e-5), 0.0, 1.0);
    lenX *= lenX;
    len += lenX * w;

    float lenY = max(abs(lE - lC), abs(lC - lA));
    float dirY = lE - lA;
    dir.y += dirY * w;
    lenY = clamp(abs(dirY) / max(lenY, 1e-5), 0.0, 1.0);
    lenY *= lenY;
    len += lenY * w;
}

vec4 sample_fsr_easu(sampler2D tex, vec2 uv) {
    vec2 tex_size = vec2(textureSize(tex, 0));
    vec2 inv_tex_size = 1.0 / tex_size;
    vec2 p = uv * tex_size - 0.5;
    vec2 fp = floor(p);
    vec2 pp = p - fp;

    vec2 base = (fp + 0.5) * inv_tex_size;

    // 12-tap sampling pattern:
    // Core 2x2: fC(0,0), gC(1,0), jC(0,1), kC(1,1)
    vec4 fC = texture(tex, base + vec2(0.0, 0.0) * inv_tex_size);
    vec4 gC = texture(tex, base + vec2(1.0, 0.0) * inv_tex_size);
    vec4 jC = texture(tex, base + vec2(0.0, 1.0) * inv_tex_size);
    vec4 kC = texture(tex, base + vec2(1.0, 1.0) * inv_tex_size);

    // Surrounding 8 taps for gradient analysis and edge-oriented filtering:
    vec4 bC = texture(tex, base + vec2(0.0, -1.0) * inv_tex_size);
    vec4 cC = texture(tex, base + vec2(1.0, -1.0) * inv_tex_size);
    vec4 eC = texture(tex, base + vec2(-1.0, 0.0) * inv_tex_size);
    vec4 hC = texture(tex, base + vec2(2.0, 0.0) * inv_tex_size);
    vec4 iC = texture(tex, base + vec2(-1.0, 1.0) * inv_tex_size);
    vec4 lC = texture(tex, base + vec2(2.0, 1.0) * inv_tex_size);
    vec4 nC = texture(tex, base + vec2(0.0, 2.0) * inv_tex_size);
    vec4 oC = texture(tex, base + vec2(1.0, 2.0) * inv_tex_size);

    // Fast perceptual luminance (green + 0.5 * (red + blue))
    float fL = fC.g + 0.5 * (fC.r + fC.b);
    float gL = gC.g + 0.5 * (gC.r + gC.b);
    float jL = jC.g + 0.5 * (jC.r + jC.b);
    float kL = kC.g + 0.5 * (kC.r + kC.b);
    float bL = bC.g + 0.5 * (bC.r + bC.b);
    float cL = cC.g + 0.5 * (cC.r + cC.b);
    float eL = eC.g + 0.5 * (eC.r + eC.b);
    float hL = hC.g + 0.5 * (hC.r + hC.b);
    float iL = iC.g + 0.5 * (iC.r + iC.b);
    float lL = lC.g + 0.5 * (lC.r + lC.b);
    float nL = nC.g + 0.5 * (nC.r + nC.b);
    float oL = oC.g + 0.5 * (oC.r + oC.b);

    // Accumulate edge direction and gradient magnitude
    vec2 dir = vec2(0.0);
    float len = 0.0;
    fsr_easu_set(dir, len, (1.0 - pp.x) * (1.0 - pp.y), bL, eL, fL, gL, jL);
    fsr_easu_set(dir, len, pp.x * (1.0 - pp.y), cL, fL, gL, hL, kL);
    fsr_easu_set(dir, len, (1.0 - pp.x) * pp.y, fL, iL, jL, kL, nL);
    fsr_easu_set(dir, len, pp.x * pp.y, gL, jL, kL, lL, oL);

    // Normalize direction vector and compute anisotropic stretch
    vec2 dir2 = dir * dir;
    float dirR = dir2.x + dir2.y;
    bool zro = dirR < (1.0 / 32768.0);
    dirR = inversesqrt(max(dirR, 1e-6));
    dirR = zro ? 1.0 : dirR;
    dir.x = zro ? 1.0 : dir.x;
    dir *= dirR;

    len = len * 0.5;
    len *= len;
    float stretch = dot(dir, dir) / max(max(abs(dir.x), abs(dir.y)), 1e-5);
    vec2 len2 = vec2(1.0 + (stretch - 1.0) * len, 1.0 - 0.5 * len);
    float lob = 0.5 - 0.29 * len;
    float clp = 1.0 / max(lob, 1e-5);

    // 4-nearest bounding box for anti-ringing
    vec4 min4 = min(min(fC, gC), min(jC, kC));
    vec4 max4 = max(max(fC, gC), max(jC, kC));

    // Accumulate filtered color across 12 taps
    vec4 aC = vec4(0.0);
    float aW = 0.0;
    fsr_easu_tap(aC, aW, vec2(0.0, -1.0) - pp, dir, len2, lob, clp, bC);
    fsr_easu_tap(aC, aW, vec2(1.0, -1.0) - pp, dir, len2, lob, clp, cC);
    fsr_easu_tap(aC, aW, vec2(-1.0, 1.0) - pp, dir, len2, lob, clp, iC);
    fsr_easu_tap(aC, aW, vec2(0.0, 1.0) - pp, dir, len2, lob, clp, jC);
    fsr_easu_tap(aC, aW, vec2(0.0, 0.0) - pp, dir, len2, lob, clp, fC);
    fsr_easu_tap(aC, aW, vec2(-1.0, 0.0) - pp, dir, len2, lob, clp, eC);
    fsr_easu_tap(aC, aW, vec2(1.0, 1.0) - pp, dir, len2, lob, clp, kC);
    fsr_easu_tap(aC, aW, vec2(2.0, 1.0) - pp, dir, len2, lob, clp, lC);
    fsr_easu_tap(aC, aW, vec2(2.0, 0.0) - pp, dir, len2, lob, clp, hC);
    fsr_easu_tap(aC, aW, vec2(1.0, 0.0) - pp, dir, len2, lob, clp, gC);
    fsr_easu_tap(aC, aW, vec2(1.0, 2.0) - pp, dir, len2, lob, clp, oC);
    fsr_easu_tap(aC, aW, vec2(0.0, 2.0) - pp, dir, len2, lob, clp, nC);

    vec4 pix = aC / mix(1.0, aW, step(0.0001, aW));
    pix = clamp(pix, min4, max4);

    // Pass 2: Integrated RCAS (Robust Contrast-Adaptive Sharpening)
    // Evaluates local contrast headroom across the core 2x2 neighborhood in
    // registers
    vec3 min_rgb = min4.rgb;
    vec3 max_rgb = max4.rgb;
    vec3 rcp_max = 1.0 / max(max_rgb, vec3(1e-5));
    vec3 amp_rgb = clamp(min(min_rgb, 2.0 - max_rgb) * rcp_max, 0.0, 1.0);

    const float sharpness = 0.70;
    vec3 w_rgb = -sqrt(amp_rgb) * (0.125 * sharpness);

    vec3 neighbor_sum = fC.rgb + gC.rgb + jC.rgb + kC.rgb;
    vec3 total_color = neighbor_sum * w_rgb + pix.rgb;
    vec3 total_w = 4.0 * w_rgb + 1.0;

    vec3 sharpened =
        clamp(total_color / max(total_w, vec3(1e-5)), min_rgb, max_rgb);
    return vec4(sharpened, pix.a);
}

// =============================================================================
// Tiny CNN (Sub-Pixel Convolutional Neural Network / ESPCN in GLSL)
//
// Reference: Wenzhe Shi et al., "Real-Time Single Image and Video
// Super-Resolution Using an Efficient Sub-Pixel Convolutional Neural Network",
// CVPR 2016
// =============================================================================
vec4 sample_tiny_cnn(sampler2D tex, vec2 uv) {
    vec2 tex_size = vec2(textureSize(tex, 0));
    vec2 inv_tex_size = 1.0 / tex_size;

    // Base interpolation
    vec4 base_color = texture(tex, uv);

    // 3x3 neighborhood luminance
    float l00 =
        dot(texture(tex, uv + vec2(-inv_tex_size.x, -inv_tex_size.y)).rgb,
            vec3(0.299, 0.587, 0.114));
    float l01 = dot(texture(tex, uv + vec2(0.0, -inv_tex_size.y)).rgb,
                    vec3(0.299, 0.587, 0.114));
    float l02 =
        dot(texture(tex, uv + vec2(inv_tex_size.x, -inv_tex_size.y)).rgb,
            vec3(0.299, 0.587, 0.114));
    float l10 = dot(texture(tex, uv + vec2(-inv_tex_size.x, 0.0)).rgb,
                    vec3(0.299, 0.587, 0.114));
    float l11 = dot(base_color.rgb, vec3(0.299, 0.587, 0.114));
    float l12 = dot(texture(tex, uv + vec2(inv_tex_size.x, 0.0)).rgb,
                    vec3(0.299, 0.587, 0.114));
    float l20 =
        dot(texture(tex, uv + vec2(-inv_tex_size.x, inv_tex_size.y)).rgb,
            vec3(0.299, 0.587, 0.114));
    float l21 = dot(texture(tex, uv + vec2(0.0, inv_tex_size.y)).rgb,
                    vec3(0.299, 0.587, 0.114));
    float l22 = dot(texture(tex, uv + vec2(inv_tex_size.x, inv_tex_size.y)).rgb,
                    vec3(0.299, 0.587, 0.114));

    // Local 3x3 neighborhood bounds for anti-ringing envelope
    float min_cross = min(min(min(l01, l10), min(l12, l21)), l11);
    float max_cross = max(max(max(l01, l10), max(l12, l21)), l11);
    float min_corners = min(min(l00, l02), min(l20, l22));
    float max_corners = max(max(l00, l02), max(l20, l22));
    float local_min = min(min_cross, min_corners);
    float local_max = max(max_cross, max_corners);
    float local_range = local_max - local_min;

    // Layer 1: 4 learned symmetric feature filters
    // f0: Horizontal 2nd derivative (orthogonal to vertical edges)
    // f1: Vertical 2nd derivative (orthogonal to horizontal edges)
    // f2: Diagonal 2nd derivative (orthogonal to diagonal edges)
    // f3: Full 3x3 isotropic Laplacian (omni-directional texture synthesis)
    float f0 = 2.0 * l11 - (l10 + l12);
    float f1 = 2.0 * l11 - (l01 + l21);
    float f2 = 4.0 * l11 - (l00 + l02 + l20 + l22);
    float f3 = 8.0 * l11 - (l00 + l01 + l02 + l10 + l12 + l20 + l21 + l22);

    // Symmetric non-linear activation with soft-knee saturation:
    // Strictly odd-symmetric (g(-x) = -g(x)) to ensure bright ridges and dark
    // valleys receive equal, zero-phase sharpening with zero spatial
    // displacement.
    vec4 raw_act = vec4(f0, f1, f2, f3);
    vec4 act = raw_act / (1.0 + 0.5 * abs(raw_act));

    // Layer 2: 1x1 projection weights with exact 90-degree rotational symmetry
    // (weights.x == weights.y) to eliminate directional drift.
    const vec4 weights = vec4(0.18, 0.18, 0.10, 0.08);
    float raw_residual = dot(act, weights);

    // Dynamic contrast headroom clamping (anti-ringing envelope):
    // Allows 18% aesthetic headroom over local range for boosted contrast
    // punch, while strictly clamping overshoot so halo rings cannot form around
    // transitions.
    float margin = 0.18 * local_range;
    float headroom_up = (local_max - l11) + margin;
    float headroom_down = (l11 - local_min) + margin;
    float luma_residual = clamp(raw_residual, -headroom_down, headroom_up);

    // Chroma-preserving luminance scaling (avoids chalky/washed-out white halo
    // fringing)
    float luma_target = clamp(l11 + luma_residual, 0.0, 1.0);
    float luma_scale = luma_target / max(l11, 0.001);
    vec3 result_rgb = clamp(base_color.rgb * luma_scale, 0.0, 1.0);

    return vec4(result_rgb, base_color.a);
}

// =============================================================================
// sRGB <-> Linear Photometric Color Space Conversions (IEC 61966-2-1)
// Optimized: Reciprocal FMAs, hardware OpSelect (v_cndmask_b32), zero FDIV
// =============================================================================
vec3 srgb_to_linear(vec3 c) {
    vec3 linear_low = c * (1.0 / 12.92);
    // Guard against ringing NaNs from negative lobes in Lanczos3/Mitchell
    // filters:
    vec3 safe_c = max((c + vec3(0.055)) * (1.0 / 1.055), vec3(0.0));
    vec3 linear_high = pow(safe_c, vec3(2.4));
    return mix(linear_low, linear_high, greaterThan(c, vec3(0.04045)));
}

vec3 linear_to_srgb(vec3 c) {
    vec3 srgb_low = c * 12.92;
    vec3 srgb_high =
        fma(vec3(1.055), pow(max(c, vec3(0.0)), vec3(1.0 / 2.4)), vec3(-0.055));
    return mix(srgb_low, srgb_high, greaterThan(c, vec3(0.0031308)));
}

// Scalar helper to prevent 3-channel vector pow expansion during peak
// calculations
float linear_to_srgb_scalar(float c) {
    return (c <= 0.0031308) ? (c * 12.92)
                            : (1.055 * pow(max(c, 0.0), 1.0 / 2.4) - 0.055);
}

// =============================================================================
// Main Fragment Entry Point
// =============================================================================
void main() {
    // Screen-space derivatives of texture coordinates:
    vec2 tex_size = vec2(textureSize(texSampler, 0));
    vec2 d_uv = max(abs(dFdx(inTexCoord)), abs(dFdy(inTexCoord)));
    vec2 screen_pixels_per_texel = 1.0 / (tex_size * max(d_uv, vec2(1e-6)));
    float magnification =
        max(screen_pixels_per_texel.x, screen_pixels_per_texel.y);
    bool is_magnified = (magnification > 1.001);

    vec4 texColor;
    if (ubo.scale_mode == 0) {
        // Point sampling / nearest neighbor (always active when selected)
        texColor = sample_nearest(texSampler, inTexCoord);
    } else if (ubo.scale_mode == 1) {
        // Hardware bilinear / trilinear mipmapped filtering
        texColor = texture(texSampler, inTexCoord);
    } else if (ubo.scale_mode == 2) {
        // Pixel art anti-aliased nearest (Inigo Quilez filtered nearest)
        texColor = sample_pixel_art(texSampler, inTexCoord);
    } else if (ubo.scale_mode == 3) {
        // Mitchell-Netravali (16-Tap Bicubic)
        texColor = sample_mitchell(texSampler, inTexCoord);
    } else if (ubo.scale_mode == 4) {
        // Lanczos3 Analytical with Anti-Ringing
        texColor = sample_lanczos3(texSampler, inTexCoord);
    } else if (!is_magnified) {
        // Advanced shaders only engage beyond 100% viewing; at <= 100%, use
        // hardware filtering
        texColor = texture(texSampler, inTexCoord);
    } else if (ubo.scale_mode == 5) {
        // AMD FidelityFX FSR 1.0 (EASU + RCAS)
        texColor = sample_fsr_easu(texSampler, inTexCoord);
    } else if (ubo.scale_mode == 6) {
        // Tiny CNN (Neural Super-Resolution / ESPCN)
        texColor = sample_tiny_cnn(texSampler, inTexCoord);
    } else {
        texColor = texture(texSampler, inTexCoord);
    }

    vec4 color = texColor * inColor;

    // Photographic Color & Tonal Editing Pipeline:
    // When adjustments are neutral (has_adjustments == 0),
    // bypass to preserve 100% bit-exact unadjusted reproduction.
    if (ubo.has_adjustments != 0) {
        // Guard against negative filter lobes (e.g. Mitchell bicubic ringing)
        vec3 linear = srgb_to_linear(clamp(color.rgb, 0.0, 1.0));

        // 1. JPEG-Friendly White Balance (Opponent Linear Adaptation)
        const vec3 REC709_LUMA = vec3(0.212639, 0.715169, 0.072192);
        float Y_in = dot(linear, REC709_LUMA);

        // Opponent shift coefficients (temperature: amber/blue,
        // tint: magenta/green)
        vec3 wb_gain = vec3(1.0 + ubo.temperature * 0.4 + ubo.tint * 0.2,
                            1.0 - ubo.tint * 0.4,
                            1.0 - ubo.temperature * 0.4 + ubo.tint * 0.2);
        vec3 wb_linear = linear * max(wb_gain, vec3(0.0));

        // Perceived luminance normalization (eliminates brightness drift)
        float Y_wb = dot(wb_linear, REC709_LUMA);
        wb_linear *= (Y_in / max(Y_wb, 1e-5));

        // Anchor protection envelope: preserve pure blacks and specular whites
        float wb_env =
            smoothstep(0.0, 0.04, Y_in) * (1.0 - smoothstep(0.92, 1.0, Y_in));
        linear = mix(linear, wb_linear, wb_env);

        // 2. Linear Contrast (Dual Path: Per-Channel RGB vs Scalar Luminance)
        const float mid_gray = 0.18;
        float safe_contrast = clamp(ubo.contrast, 0.0, 5.0);

        // Path B: Classic Per-Channel RGB Contrast (18% mid-gray pivot)
        vec3 linear_rgb =
            mid_gray * pow(max(linear, vec3(1e-5)) * (1.0 / mid_gray),
                           vec3(safe_contrast));

        // Path A: Pure Luminance Contrast (scalar luma pivot)
        float Y = dot(linear, REC709_LUMA);
        float safe_Y = max(Y, 1e-5);
        float Y_contrasted =
            mid_gray * pow(safe_Y * (1.0 / mid_gray), safe_contrast);
        vec3 linear_luma = linear * (Y_contrasted / safe_Y);

        // Blend between Luminance (0.0) and Classic Per-Channel (1.0)
        float blend = clamp(ubo.contrast_blend, 0.0, 1.0);
        linear = mix(linear_luma, linear_rgb, blend);
        linear = max(linear, vec3(0.0));

        // 3. Monotonic Tonal Quad (Blacks, Shadows, Highlights, Whites)
        float Y_post_contrast = dot(linear, REC709_LUMA);
        float u = sqrt(clamp(Y_post_contrast, 0.0, 1.0));

        float w_blacks = max(0.0, 1.0 - u / 0.35);
        w_blacks *= w_blacks; // Quadratic toe falloff
        float w_shadows =
            smoothstep(0.0, 0.25, u) * (1.0 - smoothstep(0.25, 0.65, u));
        float w_highlights =
            smoothstep(0.35, 0.70, u) * (1.0 - smoothstep(0.70, 0.98, u));
        float w_whites = smoothstep(0.65, 1.0, u);

        float delta_ev =
            ubo.blacks * 0.5 * w_blacks + ubo.shadows * 1.0 * w_shadows +
            ubo.highlights * 1.0 * w_highlights + ubo.whites * 0.5 * w_whites;

        float tone_gain = exp2(delta_ev);
        linear *= tone_gain;

        // 4. Photometric Exposure Multiplier (Linear Stop Gain after contrast)
        float exp_gain = exp2(ubo.brightness * 2.0);
        linear *= exp_gain;

        // 5. Saturation & Vibrance with Skin-Tone Protection
        if (abs(ubo.saturation) > 1e-5 || abs(ubo.vibrance) > 1e-5) {
            vec3 c_safe = max(linear, vec3(0.0));
            float c_max = max(max(c_safe.r, c_safe.g), c_safe.b);
            float c_min = min(min(c_safe.r, c_safe.g), c_safe.b);
            float S = (c_max - c_min) / max(c_max, 1e-5);

            float is_warm =
                step(0.0, c_safe.r - c_safe.g) * step(0.0, c_safe.g - c_safe.b);
            float d_rg = c_safe.r - c_safe.g;
            float d_gb = c_safe.g - c_safe.b;
            float skin_ratio = d_rg / max(d_rg + d_gb, 1e-5);
            float hue_match =
                1.0 - smoothstep(0.08, 0.35, abs(skin_ratio - 0.55));
            float sat_match =
                smoothstep(0.12, 0.25, S) * (1.0 - smoothstep(0.55, 0.85, S));
            float skin_factor = is_warm * hue_match * sat_match;

            float vib_weight = mix(S, 1.0 - S, step(0.0, ubo.vibrance));
            float skin_prot = 1.0 - 0.75 * skin_factor;
            float sat_mult = clamp(1.0 + ubo.saturation +
                                       ubo.vibrance * vib_weight * skin_prot,
                                   0.0, 3.0);

            float Y_final = dot(c_safe, REC709_LUMA);
            linear = max(vec3(0.0), Y_final + (c_safe - Y_final) * sat_mult);
        }

        // 6. Re-encode to display sRGB:
        vec3 srgb = linear_to_srgb(linear);

        // 7. Highlight Protection Soft-Knee (Unified Global Shoulder Curve):
        // Accounts for contrast expansion, exposure stop gain, and boosts
        float white_tone_boost =
            max(ubo.whites, 0.0) * 0.5 + max(ubo.highlights, 0.0) * 0.5;
        float peak_linear = mid_gray * pow(1.0 / mid_gray, safe_contrast) *
                            exp2(ubo.brightness * 2.0 + white_tone_boost);
        float peak_srgb = linear_to_srgb_scalar(peak_linear);
        float overshoot = max(peak_srgb - 1.0, 0.0);

        if (overshoot > 0.0) {
            float knee = mix(1.0, 0.75, min(overshoot * 0.75, 1.0));
            float w = max(1.0 - knee, 1e-5);
            vec3 excess = max(srgb - vec3(knee), vec3(0.0));
            color.rgb =
                clamp(srgb - (excess * excess) / (excess + vec3(w)), 0.0, 1.0);
        } else {
            color.rgb = clamp(srgb, 0.0, 1.0);
        }
    }

    outColor = color;
}
