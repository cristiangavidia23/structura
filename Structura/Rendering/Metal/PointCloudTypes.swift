import simd

/// Per-vertex layout shared between Swift and `Shaders.metal`. Matches
/// float3 + float exactly so the Swift-side buffer can be uploaded directly
/// with no bridging header.
struct PointVertex {
    var position: SIMD3<Float>
    var confidence: Float
}

/// Uniforms for the point-cloud vertex shader.
struct PointCloudUniforms {
    var viewProjectionMatrix: simd_float4x4
    var pointSize: Float
}
