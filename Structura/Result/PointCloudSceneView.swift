import SwiftUI
import SceneKit

/// Standalone, navigable 3D view of a Pro Scan point cloud, colored by
/// confidence (the same red→green heatmap as the live capture). Lives in
/// its own scene rather than fused into `DollhouseSceneView`'s room mesh:
/// Pro Scan runs in a separate ARKit session from RoomPlan's, so the two
/// point sets don't share a coordinate space — overlaying them onto the
/// same walls would be fabricated precision, not real alignment.
struct PointCloudSceneView: UIViewRepresentable {
    let points: [PointCloudExportPoint]

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = SceneBuilder.build(from: points)
        view.backgroundColor = .black
        view.allowsCameraControl = true
        view.antialiasingMode = .multisampling4X

        let controller = view.defaultCameraController
        controller.interactionMode = .orbitTurntable
        controller.inertiaEnabled = true

        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}
}

private enum SceneBuilder {
    /// Very-low-confidence samples are real data (kept in the export), but
    /// visually they're mostly noise that drowns out the readable parts of
    /// the scan in a wash of red — thin them out for viewing.
    private static let minimumDisplayConfidence: Float = 0.2

    static func build(from points: [PointCloudExportPoint]) -> SCNScene {
        let scene = SCNScene()
        let visiblePoints = points.filter { $0.confidence >= minimumDisplayConfidence }
        guard !visiblePoints.isEmpty else { return scene }

        let node = SCNNode(geometry: pointCloudGeometry(for: visiblePoints))
        scene.rootNode.addChildNode(node)
        scene.rootNode.addChildNode(cameraNode(framing: node))
        return scene
    }

    private static func pointCloudGeometry(for points: [PointCloudExportPoint]) -> SCNGeometry {
        var vertices: [SCNVector3] = []
        var colors: [SCNVector4] = []
        vertices.reserveCapacity(points.count)
        colors.reserveCapacity(points.count)

        for point in points {
            vertices.append(SCNVector3(point.position.x, point.position.y, point.position.z))
            let color = heatmapColor(confidence: point.confidence)
            colors.append(SCNVector4(color.0, color.1, color.2, 1))
        }

        let vertexSource = SCNGeometrySource(vertices: vertices)
        let colorData = Data(bytes: colors, count: colors.count * MemoryLayout<SCNVector4>.stride)
        let colorSource = SCNGeometrySource(
            data: colorData,
            semantic: .color,
            vectorCount: colors.count,
            usesFloatComponents: true,
            componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SCNVector4>.stride
        )

        let indices = Array(0..<UInt32(points.count))
        let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<UInt32>.size)
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .point,
            primitiveCount: points.count,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )
        element.pointSize = 6
        element.minimumPointScreenSpaceRadius = 2
        element.maximumPointScreenSpaceRadius = 8

        let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = true
        geometry.materials = [material]
        return geometry
    }

    /// Mirrors the Metal shader's confidence gradient: red (low) through
    /// yellow to green (high).
    private static func heatmapColor(confidence: Float) -> (Float, Float, Float) {
        let low: (Float, Float, Float) = (0.85, 0.18, 0.15)
        let mid: (Float, Float, Float) = (0.95, 0.75, 0.15)
        let high: (Float, Float, Float) = (0.20, 0.80, 0.30)
        let c = min(max(confidence, 0), 1)
        func mix(_ a: (Float, Float, Float), _ b: (Float, Float, Float), _ t: Float) -> (Float, Float, Float) {
            (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
        }
        return c < 0.5 ? mix(low, mid, c * 2) : mix(mid, high, (c - 0.5) * 2)
    }

    private static func cameraNode(framing node: SCNNode) -> SCNNode {
        let camera = SCNCamera()
        camera.fieldOfView = 45
        let cameraNode = SCNNode()
        cameraNode.camera = camera

        let (center, radius) = node.boundingSphere
        let verticalFOVRadians = Float(camera.fieldOfView) * .pi / 180
        let distance = max(radius / sin(verticalFOVRadians / 2) * 1.3, 0.5)

        cameraNode.position = SCNVector3(center.x, center.y, center.z + distance)
        cameraNode.look(at: center)
        return cameraNode
    }
}
