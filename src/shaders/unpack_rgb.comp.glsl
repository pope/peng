#version 450

layout (local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// Output 2D Storage Texture
layout(set = 1, binding = 0, rgba8) writeonly uniform image2D outImage;

// Input Storage Buffer (packed bytes read as 32-bit uints)
layout(std430, set = 0, binding = 0) readonly buffer SrcBuffer {
    uint data[];
} src_buf;

// Uniform parameters pushed per dispatch
layout(std140, set = 2, binding = 0) uniform Params {
    uint width;
    uint height;
    uint is_bgr;     // 0 = RGB24, 1 = BGR24
    uint src_pitch;  // Row pitch of source buffer in bytes
} params;

uint getByte(uint byte_offset) {
    uint word_idx = byte_offset >> 2;
    uint byte_idx = byte_offset & 3u;
    uint word = src_buf.data[word_idx];
    return (word >> (byte_idx * 8u)) & 0xFFu;
}

void main() {
    uvec2 pos = gl_GlobalInvocationID.xy;
    if (pos.x >= params.width || pos.y >= params.height) {
        return;
    }

    uint byte_offset = pos.y * params.src_pitch + pos.x * 3u;

    uint b0 = getByte(byte_offset + 0u);
    uint b1 = getByte(byte_offset + 1u);
    uint b2 = getByte(byte_offset + 2u);

    float r, g, b;
    if (params.is_bgr == 1u) {
        r = float(b2) / 255.0;
        g = float(b1) / 255.0;
        b = float(b0) / 255.0;
    } else {
        r = float(b0) / 255.0;
        g = float(b1) / 255.0;
        b = float(b2) / 255.0;
    }

    imageStore(outImage, ivec2(pos), vec4(r, g, b, 1.0));
}
