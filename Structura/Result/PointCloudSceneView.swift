import SwiftUI
import SceneKit

/// Standalone, navigable 3D view of a Pro Scan point cloud, colored with
/// the real camera image sampled at capture time (not a confidence
/// heatmap — that's still what the live Pro Scan overlay shows, since
/// during capture the useful signal is scan quality, not appearance).
/// Lives in its own scene rather than fused into `DollhouseSceneView`'s
/// room mesh:
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
            colors.append(SCNVector4(point.color.x, point.color.y, point.color.z, 1))
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

    /// A straight-on start angle flattens a mostly-planar scan (a wall swept
    /// head-on) into what looks like a blob with no depth at all — you'd
    /// have to already know to orbit it to discover the shape. Start from
    /// the same elevated 3/4 angle `DollhouseSceneView` uses instead, so
    /// depth reads immediately.
    private static func cameraNode(framing node: SCNNode) -> SCNNode {
        let camera = SCNCamera()
        camera.fieldOfView = 45
        let cameraNode = SCNNode()
        cameraNode.camera = camera

        let (center, radius) = node.boundingSphere
        let verticalFOVRadians = Float(camera.fieldOfView) * .pi / 180
        let distance = max(radius / sin(verticalFOVRadians / 2) * 1.3, 0.5)

        let azimuth: Float = .pi / 4
        let elevation: Float = .pi / 4.6
        cameraNode.position = SCNVector3(
            center.x + distance * cos(elevation) * sin(azimuth),
            center.y + distance * sin(elevation),
            center.z + distance * cos(elevation) * cos(azimuth)
        )
        cameraNode.look(at: center)
        return cameraNode
    }
}
