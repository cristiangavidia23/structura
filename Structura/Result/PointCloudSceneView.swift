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
    /// Measured off the same cloud; drives the reference grid's extent.
    /// `nil` simply means no grid layer is available to show.
    var statistics: PointCloudStatistics.Report?
    var showsReferenceGrid = false
    /// Multiplies the physically-derived point size — see
    /// `SceneBuilder.pointSize(forMultiplier:)`. 1 keeps points at roughly
    /// the cloud's own sample spacing.
    var pointSizeMultiplier: Float = 1

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

        // All of this mutates the existing scene in place. Rebuilding it
        // would re-parse every point and reset the camera the user had
        // orbited into position, on every toggle and every slider tick.
        if let scene = uiView.scene, let statistics {
            SceneBuilder.installReferenceGridIfNeeded(in: scene, statistics: statistics)
        }
        uiView.scene?.rootNode
            .childNode(withName: PointCloudReferenceGrid.nodeName, recursively: false)?
            .isHidden = !showsReferenceGrid

        let element = uiView.scene?.rootNode
            .childNode(withName: SceneBuilder.pointCloudNodeName, recursively: false)?
            .geometry?.elements.first
        element?.pointSize = SceneBuilder.pointSize(forMultiplier: pointSizeMultiplier)
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

    /// Name on the point cloud's own node, so `updateUIView` can reach its
    /// geometry to retune point size without rebuilding it — a rebuild of a
    /// several-hundred-thousand-point geometry on every slider tick would
    /// make the control unusable.
    static let pointCloudNodeName = "structura.pointCloud"

    static func build(from points: [PointCloudExportPoint]) -> SCNScene {
        let scene = SCNScene()
        let visiblePoints = points.filter { $0.confidence >= minimumDisplayConfidence }
        guard !visiblePoints.isEmpty else { return scene }

        let node = SCNNode(geometry: pointCloudGeometry(for: visiblePoints))
        node.name = pointCloudNodeName
        scene.rootNode.addChildNode(node)

        scene.rootNode.addChildNode(cameraNode(framing: node))
        return scene
    }

    /// Adds the reference layer the first time statistics are available, and
    /// does nothing on every call after that.
    ///
    /// The grid can't be built in `build(from:)`: the statistics it needs are
    /// measured in a background pass that finishes *after* the cloud is
    /// already on screen, and delaying the first render until they land would
    /// trade a visible improvement for a visible stall. Built once and then
    /// only hidden/shown, so toggling it never re-runs this.
    static func installReferenceGridIfNeeded(in scene: SCNScene, statistics: PointCloudStatistics.Report) {
        guard scene.rootNode.childNode(withName: PointCloudReferenceGrid.nodeName, recursively: false) == nil else { return }
        let grid = PointCloudReferenceGrid.makeNode(for: statistics.boundingBox)
        grid.isHidden = true
        scene.rootNode.addChildNode(grid)
    }

    // Tried and reverted (probado en dispositivo, 09/09/2026): lighting these
    // points by their exported normals (`.lambert` + an ambient fill and a
    // camera-mounted directional light), plus distance fog as a depth cue.
    // Both made the cloud visibly *worse* on a real scan and were backed out:
    //
    // - `.lambert` on `.point` primitives did not shade the sprites while
    //   keeping their per-vertex color the way it does for triangles — it
    //   washed the captured colors out to near-black instead. The real fix
    //   for shading a point cloud is screen-space (eye-dome lighting in a
    //   Metal pass), not a SceneKit lighting model.
    // - The fog range was simply wrong: `cameraNode(framing:)` starts the
    //   camera at ~3.4x the cloud's bounding radius, so a fog range ending at
    //   3.4x that radius put half the cloud in full fog before the user
    //   touched anything.
    //
    // Left as a note rather than deleted so the next attempt starts from what
    // was already measured, instead of re-deriving it.

    /// World-space point size for a given user multiplier.
    ///
    /// **`SCNGeometryElement.pointSize` is in world units — metres here —
    /// not pixels.** The screen-space clamps below it are what convert that
    /// into pixels. Getting this backwards is what previously made every
    /// point render at a fixed 8 px at every zoom level (it asked for
    /// 6-metre points, which the clamp then swallowed), so the base size is
    /// derived from the cloud's real spacing: fusion leaves one point per
    /// `ProScanConfig.voxelSizeMeters` cell, and 1.3x that overlaps
    /// neighbours slightly so surfaces read as surfaces rather than as
    /// scattered dust.
    static func pointSize(forMultiplier multiplier: Float) -> CGFloat {
        CGFloat(ProScanConfig.voxelSizeMeters * 1.3 * multiplier)
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
        // `pointSize` is in **world units**, not pixels — the two
        // `...ScreenSpaceRadius` values are the pixel clamps applied to
        // whatever that world size projects to. The previous `6` therefore
        // asked for 6-metre points, which every camera distance clamped to
        // the 8 px ceiling: points rendered at a fixed 8 px at *every* zoom
        // level, so zooming in spread them apart on screen without growing
        // them, opening black gaps between what is really a continuous
        // surface.
        //
        // Sized to the fused cloud's actual spacing instead: fusion dedups to
        // one point per `ProScanConfig.voxelSizeMeters` (2 cm) cell, so 2.6 cm
        // points overlap their neighbours by ~30% and read as a surface when
        // you zoom in, while still shrinking honestly as you pull away.
        element.pointSize = pointSize(forMultiplier: 1)
        // Floor: a point must stay visible when the whole scan is framed
        // (where 2.6 cm projects to well under a pixel).
        element.minimumPointScreenSpaceRadius = 1.5
        // Ceiling: high enough not to bind at close zoom (that ceiling is the
        // bug above), low enough that a single stray sample examined nose-to-
        // surface can't smear across the view.
        element.maximumPointScreenSpaceRadius = 24

        let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
        let material = SCNMaterial()
        // `.constant` — see the reverted-lighting note in `build(from:)` for
        // why the normals this cloud carries are *not* used to shade it.
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
