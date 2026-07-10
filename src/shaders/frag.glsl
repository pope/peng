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
                    // lanczos3
}
ubo;

float mitchell_weight(float x) {
    float ax = abs(x);
    if (ax < 1.0) {
        return (7.0 / 6.0) * ax * ax * ax - 2.0 * ax * ax + (8.0 / 9.0);
    } else if (ax < 2.0) {
        return (-7.0 / 18.0) * ax * ax * ax + 2.0 * ax * ax -
               (10.0 / 3.0) * ax + (16.0 / 9.0);
    }
    return 0.0;
}

float sinc(float x) {
    if (abs(x) < 0.0001)
        return 1.0;
    float pi_x = 3.141592653589793 * x;
    return sin(pi_x) / pi_x;
}

float lanczos3_weight(float x) {
    float ax = abs(x);
    if (ax < 3.0) {
        return sinc(ax) * sinc(ax / 3.0);
    }
    return 0.0;
}

vec4 sample_mitchell(sampler2D tex, vec2 uv) {
    vec2 tex_size = vec2(textureSize(tex, 0));
    vec2 p = uv * tex_size - 0.5;
    vec2 i = floor(p);
    vec2 f = fract(p);

    float wx[4];
    wx[0] = mitchell_weight(-1.0 - f.x);
    wx[1] = mitchell_weight(-f.x);
    wx[2] = mitchell_weight(1.0 - f.x);
    wx[3] = mitchell_weight(2.0 - f.x);

    float wy[4];
    wy[0] = mitchell_weight(-1.0 - f.y);
    wy[1] = mitchell_weight(-f.y);
    wy[2] = mitchell_weight(1.0 - f.y);
    wy[3] = mitchell_weight(2.0 - f.y);

    vec4 sum = vec4(0.0);
    float total_w = 0.0;

    for (int row = 0; row < 4; row++) {
        float wy_val = wy[row];
        for (int col = 0; col < 4; col++) {
            float w = wx[col] * wy_val;
            vec2 sample_uv =
                (i + vec2(float(col - 1), float(row - 1)) + 0.5) / tex_size;
            sum += texture(tex, sample_uv) * w;
            total_w += w;
        }
    }
    return sum / (total_w > 0.0 ? total_w : 1.0);
}

vec4 sample_lanczos3(sampler2D tex, vec2 uv) {
    vec2 tex_size = vec2(textureSize(tex, 0));
    vec2 p = uv * tex_size - 0.5;
    vec2 i = floor(p);
    vec2 f = fract(p);

    float wx[6];
    wx[0] = lanczos3_weight(-2.0 - f.x);
    wx[1] = lanczos3_weight(-1.0 - f.x);
    wx[2] = lanczos3_weight(-f.x);
    wx[3] = lanczos3_weight(1.0 - f.x);
    wx[4] = lanczos3_weight(2.0 - f.x);
    wx[5] = lanczos3_weight(3.0 - f.x);

    float wy[6];
    wy[0] = lanczos3_weight(-2.0 - f.y);
    wy[1] = lanczos3_weight(-1.0 - f.y);
    wy[2] = lanczos3_weight(-f.y);
    wy[3] = lanczos3_weight(1.0 - f.y);
    wy[4] = lanczos3_weight(2.0 - f.y);
    wy[5] = lanczos3_weight(3.0 - f.y);

    vec4 sum = vec4(0.0);
    float total_w = 0.0;

    for (int row = 0; row < 6; row++) {
        float wy_val = wy[row];
        for (int col = 0; col < 6; col++) {
            float w = wx[col] * wy_val;
            vec2 sample_uv =
                (i + vec2(float(col - 2), float(row - 2)) + 0.5) / tex_size;
            sum += texture(tex, sample_uv) * w;
            total_w += w;
        }
    }
    return sum / (total_w > 0.0 ? total_w : 1.0);
}

void main() {
    vec4 color;
    if (ubo.is_text_or_color == 0) {
        if (ubo.scale_mode == 3) {
            color = sample_mitchell(texSampler, inTexCoord) * inColor;
        } else if (ubo.scale_mode == 4) {
            color = sample_lanczos3(texSampler, inTexCoord) * inColor;
        } else {
            color = texture(texSampler, inTexCoord) * inColor;
        }

        // Apply brightness/contrast on GPU for images
        color.rgb = (color.rgb - 0.5) * ubo.contrast + 0.5 + ubo.brightness;
    } else {
        color = texture(texSampler, inTexCoord) * inColor;
    }
    outColor = color;
}
