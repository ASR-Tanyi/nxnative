// Synthetic Metal 3 baseline for the mac15 port; no game shaders or data.
#include <metal_stdlib>
using namespace metal;

struct ProbeArgs {
    device const uint *input;
    device uint *output;
};

kernel void probe_compute(constant ProbeArgs &args [[buffer(0)]], uint i [[thread_position_in_grid]]) {
    args.output[i] = args.input[i] * 3u + 7u;
}

vertex float4 probe_vertex(uint i [[vertex_id]]) {
    const float2 positions[] = {float2(-1, -1), float2(3, -1), float2(-1, 3)};
    return float4(positions[i], 0, 1);
}

fragment float4 probe_fragment() {
    return float4(0, 1, 0, 1);
}
