#include <metal_stdlib>
using namespace metal;

struct PointVertexIn {
    float3 position;
    float confidence;
};

struct PointCloudUniforms {
    float4x4 viewProjectionMatrix;
    float pointSize;
};

struct PointVertexOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    float4 color;
};

// Confidence heatmap: low confidence -> red, high confidence -> green.
static float3 heatmapColor(float confidence) {
    float3 low = float3(0.85, 0.18, 0.15);
    float3 mid = float3(0.95, 0.75, 0.15);
    float3 high = float3(0.20, 0.80, 0.30);
    float c = clamp(confidence, 0.0, 1.0);
    if (c < 0.5) {
        return mix(low, mid, c * 2.0);
    }
    return mix(mid, high, (c - 0.5) * 2.0);
}

vertex PointVertexOut pointCloudVertex(
    const device PointVertexIn *vertices [[buffer(0)]],
    constant PointCloudUniforms &uniforms [[buffer(1)]],
    uint vertexID [[vertex_id]]
) {
    PointVertexIn in = vertices[vertexID];
    PointVertexOut out;
    out.position = uniforms.viewProjectionMatrix * float4(in.position, 1.0);
    out.pointSize = uniforms.pointSize;
    out.color = float4(heatmapColor(in.confidence), 1.0);
    return out;
}

// Soft circular dot with a feathered edge and a brighter core, instead of a
// hard-edged square — reads as a glow rather than a raw pixel grid.
fragment float4 pointCloudFragment(
    PointVertexOut in [[stage_in]],
    float2 pointCoord [[point_coord]]
) {
    float2 centered = pointCoord - float2(0.5, 0.5);
    float distance = length(centered) * 2.0; // 0 at center, 1 at the edge
    if (distance > 1.0) {
        discard_fragment();
    }

    float core = smoothstep(1.0, 0.0, distance);
    float alpha = smoothstep(1.0, 0.55, distance);
    float3 color = mix(in.color.rgb, min(in.color.rgb * 1.35 + 0.15, 1.0), core);
    return float4(color, alpha * in.color.a);
}
