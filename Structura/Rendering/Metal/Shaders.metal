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

fragment float4 pointCloudFragment(PointVertexOut in [[stage_in]]) {
    return in.color;
}
