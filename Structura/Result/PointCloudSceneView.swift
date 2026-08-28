import SwiftUI
import SceneKit
import simd

/// Standalone, navigable 3D view of a Pro Scan point cloud, colored with
/// the real camera image sampled at capture time (not a confidence
/// heatmap — that's still what the live Pro Scan overlay shows, since
/// during capture the useful signal is scan quality, not appearance).
/// Lives in its own scene rather than fused into `DollhouseSceneView`'s
/// room mesh:
/// Pro Scan runs in a separate ARKit session from RoomPlan's, so the two
/// point sets don't share a coordinate space — overlaying them onto the
/// same walls would be fabricated precision, not real alignment.
///
/// Also hosts tap-to-measure: since the exported point cloud has no
/// triangle mesh to hit-test against (see `PointCloudRaycast`'s doc
/// comment), taps are custom-raycast against the points themselves and,
/// where the local neighborhood is flat enough, snapped onto a fitted
/// plane (`PlaneSnapping`) rather than landing on a single noisy sample.
struct PointCloudSceneView: UIViewRepresentable {
    let points: [PointCloudExportPoint]
    @ObservedObject var measurement: MeasurementSession

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = SceneBuilder.build(from: points)
        view.backgroundColor = .black
        view.allowsCameraControl = true
        view.antialiasingMode = .multisampling4X

        let controller = view.defaultCameraController
        controller.interactionMode = .orbitTurntable
        controller.inertiaEnabled = true

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)

        context.coordinator.sceneView = view
        context.coordinator.points = points
        context.coordinator.measurement = measurement
        context.coordinator.hapticEngine.start()

        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.points = points
        context.coordinator.measurement = measurement
        context.coordinator.syncMeasurementNodes()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    static func dismantleUIView(_ uiView: SCNView, coordinator: Coordinator) {
        coordinator.hapticEngine.stop()
    }

    /// Owns the actual SceneKit interaction: raycasting a tap into the
    /// point cloud, attempting a plane snap, feeding the result into
    /// `MeasurementSession`, and drawing/clearing the marker + line nodes
    /// that mirror that session's state. `@MainActor` because
    /// `MeasurementSession` is: UIKit always invokes gesture-recognizer
    /// targets on the main thread, so this matches runtime reality rather
    /// than fighting it.
    @MainActor
    final class Coordinator: NSObject {
        weak var sceneView: SCNView?
        var points: [PointCloudExportPoint] = []
        weak var measurement: MeasurementSession?

        let hapticEngine = HapticEngineManager()
        private lazy var haptics = HapticFeedbackAdapter(engineManager: hapticEngine)

        private var markerNodes: [SCNNode] = []
        private var lineNode: SCNNode?

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let sceneView, let measurement else { return }
            let location = gesture.location(in: sceneView)

            // SceneKit's own raycast/hit-test targets triangle geometry;
            // this scene has none (see `PointCloudRaycast`'s doc comment),
            // so the ray is built by hand from two unprojected depths
            // (near/far clip) and matched against the points directly.
            let near = sceneView.unprojectPoint(SCNVector3(Float(location.x), Float(location.y), 0))
            let far = sceneView.unprojectPoint(SCNVector3(Float(location.x), Float(location.y), 1))
            let origin = SIMD3<Float>(near.x, near.y, near.z)
            let direction = SIMD3<Float>(far.x - near.x, far.y - near.y, far.z - near.z)

            guard let hit = PointCloudRaycast.nearestPoint(
                in: points,
                rayOrigin: origin,
                rayDirection: direction,
                maxPerpendicularDistance: ProScanConfig.raycastMaxPerpendicularDistanceMeters
            ) else { return }

            var finalPosition = hit.position
            var didSnap = false
            if let plane = PlaneSnapping.fitPlane(
                around: hit.position,
                in: points,
                radius: ProScanConfig.planeFitNeighborhoodRadiusMeters,
                minimumNeighbors: ProScanConfig.minimumPlaneFitNeighborCount,
                maxAngularSpreadRadians: ProScanConfig.maximumPlanarAngularSpreadRadians
            ) {
                finalPosition = PlaneSnapping.project(hit.position, onto: plane)
                didSnap = true
            }

            let wasSecondPoint = measurement.firstPoint != nil && measurement.secondPoint == nil
            measurement.addTappedPoint(.init(position: finalPosition, didSnapToPlane: didSnap))
            syncMeasurementNodes()

            // See `PointCloudSceneView`'s doc comment for why each pattern
            // was picked: acquiring a plane snap is the positive "locked
            // on" tick; falling back to a raw, noisier point reuses the
            // same escalating cue Pro Scan's capture flow uses for
            // "trust this less"; completing the second point is the same
            // confirmation cue capture uses for finishing a scan.
            if wasSecondPoint {
                haptics.meshClosed()
            } else if didSnap {
                haptics.samplingTick()
            } else {
                haptics.trackingLostProgressive()
            }
        }

        /// Rebuilds the marker/line nodes from `measurement`'s current
        /// state — cheap enough (at most 2 spheres + 1 line) to just
        /// clear and redraw rather than diff.
        func syncMeasurementNodes() {
            guard let sceneView, let measurement else { return }
            let scene = sceneView.scene

            markerNodes.forEach { $0.removeFromParentNode() }
            markerNodes.removeAll()
            lineNode?.removeFromParentNode()
            lineNode = nil

            if let first = measurement.firstPoint {
                markerNodes.append(addMarker(at: first.position, snapped: first.didSnapToPlane, to: scene))
            }
            if let second = measurement.secondPoint {
                markerNodes.append(addMarker(at: second.position, snapped: second.didSnapToPlane, to: scene))
            }
            if let first = measurement.firstPoint, let second = measurement.secondPoint {
                lineNode = addLine(from: first.position, to: second.position, to: scene)
            }
        }

        private func addMarker(at position: SIMD3<Float>, snapped: Bool, to scene: SCNScene?) -> SCNNode {
            let sphere = SCNSphere(radius: 0.012)
            sphere.firstMaterial?.diffuse.contents = snapped ? UIColor.systemGreen : UIColor.systemYellow
            sphere.firstMaterial?.lightingModel = .constant
            let node = SCNNode(geometry: sphere)
            node.position = SCNVector3(position.x, position.y, position.z)
            scene?.rootNode.addChildNode(node)
            return node
        }

        private func addLine(from a: SIMD3<Float>, to b: SIMD3<Float>, to scene: SCNScene?) -> SCNNode {
            let vertexSource = SCNGeometrySource(vertices: [SCNVector3(a.x, a.y, a.z), SCNVector3(b.x, b.y, b.z)])
            let indices: [Int32] = [0, 1]
            let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<Int32>.size)
            let element = SCNGeometryElement(data: indexData, primitiveType: .line, primitiveCount: 1, bytesPerIndex: MemoryLayout<Int32>.size)
            let geometry = SCNGeometry(sources: [vertexSource], elements: [element])
            geometry.firstMaterial?.diffuse.contents = UIColor.white
            geometry.firstMaterial?.lightingModel = .constant
            let node = SCNNode(geometry: geometry)
            scene?.rootNode.addChildNode(node)
            return node
        }
    }
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
