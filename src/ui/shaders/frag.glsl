#version 450

layout(location = 0) in vec2 inTexCoord;
layout(location = 1) in vec4 inColor;

layout(location = 0) out vec4 outColor;

layout(set = 2, binding = 0) uniform sampler2D texSampler;

layout(std140, set = 3, binding = 0) uniform UBO {
    float brightness;
    float contrast;
    int is_text_or_color;
    int scale_mode; // 0 = nearest, 1 = linear, 2 = pixel_art, 3 = mitchell, 4 =
                    // lanczos3, 5 = lanczos3_spline
}
ubo;

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

// 36-Tap Unrolled Analytical Lanczos3 Filter
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

#pragma unroll
    for (int r = 0; r < 6; r++) {
        float wyr = wy[r];
        vec2 row_uv = base_uv + vec2(0.0, float(r) * inv_tex_size.y);
#pragma unroll
        for (int c = 0; c < 6; c++) {
            float w = wx[c] * wyr;
            sum +=
                texture(tex, row_uv + vec2(float(c) * inv_tex_size.x, 0.0)) * w;
            total_w += w;
        }
    }

    return sum / mix(1.0, total_w, step(0.00001, total_w));
}

// Horner's polynomial spline evaluation for Lanczos3 segments on [0, 1] (Pure
// FMA ALU)
float lanczos3_spline_p0(float t) {
    return ((((-0.5863178 * t + 1.5360549) * t - 0.1446258) * t - 1.8036159) *
                t -
            0.0015766) *
               t +
           1.0000228;
}

float lanczos3_spline_p1(float t) {
    return ((((0.4109854 * t - 1.1136012) * t + 0.3772881) * t + 1.1529428) *
                t -
            0.8275555) *
               t +
           0.0000243;
}

float lanczos3_spline_p2(float t) {
    return ((((-0.1947629 * t + 0.4508454) * t - 0.1122383) * t - 0.3531353) *
                t +
            0.2092624) *
               t -
           0.0000649;
}

void lanczos3_spline_weights_1d(float f, out float w0, out float w1,
                                out float w2, out float w3, out float w4,
                                out float w5) {
    float inv_f = 1.0 - f;
    w0 = lanczos3_spline_p2(f);
    w1 = lanczos3_spline_p1(f);
    w2 = lanczos3_spline_p0(f);
    w3 = lanczos3_spline_p0(inv_f);
    w4 = lanczos3_spline_p1(inv_f);
    w5 = lanczos3_spline_p2(inv_f);
}

// 36-Tap Unrolled Lanczos3 Polynomial Spline Filter (Zero Transcendentals)
vec4 sample_lanczos3_spline(sampler2D tex, vec2 uv) {
    vec2 tex_size = vec2(textureSize(tex, 0));
    vec2 inv_tex_size = 1.0 / tex_size;
    vec2 p = uv * tex_size - 0.5;
    vec2 i = floor(p);
    vec2 f = fract(p);

    float wx0, wx1, wx2, wx3, wx4, wx5;
    float wy0, wy1, wy2, wy3, wy4, wy5;
    lanczos3_spline_weights_1d(f.x, wx0, wx1, wx2, wx3, wx4, wx5);
    lanczos3_spline_weights_1d(f.y, wy0, wy1, wy2, wy3, wy4, wy5);

    vec4 sum = vec4(0.0);
    float total_w = 0.0;
    vec2 base_uv = (i + vec2(-2.0, -2.0) + 0.5) * inv_tex_size;

    float wy[6] = float[6](wy0, wy1, wy2, wy3, wy4, wy5);
    float wx[6] = float[6](wx0, wx1, wx2, wx3, wx4, wx5);

#pragma unroll
    for (int r = 0; r < 6; r++) {
        float wyr = wy[r];
        vec2 row_uv = base_uv + vec2(0.0, float(r) * inv_tex_size.y);
#pragma unroll
        for (int c = 0; c < 6; c++) {
            float w = wx[c] * wyr;
            sum +=
                texture(tex, row_uv + vec2(float(c) * inv_tex_size.x, 0.0)) * w;
            total_w += w;
        }
    }

    return sum / mix(1.0, total_w, step(0.00001, total_w));
}

void main() {
    vec4 texColor;
    if (ubo.scale_mode == 3) {
        texColor = sample_mitchell(texSampler, inTexCoord);
    } else if (ubo.scale_mode == 4) {
        texColor = sample_lanczos3(texSampler, inTexCoord);
    } else if (ubo.scale_mode == 5) {
        texColor = sample_lanczos3_spline(texSampler, inTexCoord);
    } else {
        texColor = texture(texSampler, inTexCoord);
    }

    vec4 color = texColor * inColor;

    vec3 adjColor = (color.rgb - 0.5) * ubo.contrast + 0.5 + ubo.brightness;
    float isImg = step(float(ubo.is_text_or_color), 0.5);
    color.rgb = mix(color.rgb, adjColor, isImg);

    outColor = color;
}
