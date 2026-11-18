#include <metal_stdlib>
using namespace metal;

kernel void m3_add(device uint *values [[buffer(0)]], constant uint &delta [[buffer(1)]], uint i [[thread_position_in_grid]]) {
    values[i] += delta;
}

kernel void m3_color(texture2d<float, access::write> image [[texture(0)]], uint2 xy [[thread_position_in_grid]]) {
    image.write(float4(0, 1, 0, 1), xy);
}

vertex float4 m3_vertex(uint i [[vertex_id]]) {
    const float2 positions[] = {float2(-1, -1), float2(3, -1), float2(-1, 3)};
    return float4(positions[i], 0, 1);
}

// A raw Metal 3 argument buffer: a pointer and resource IDs, exactly as the
// host's shader argument blocks represent these three kinds of resources.
struct M3Indirect {
    device const uint *values;
    texture2d<float> image;
    sampler image_sampler;
};
fragment float4 m3_fragment(constant M3Indirect &args [[buffer(0)]]) {
    return args.values[0] == 42 ? args.image.sample(args.image_sampler, float2(0.5)) : float4(1, 0, 0, 1);
}
