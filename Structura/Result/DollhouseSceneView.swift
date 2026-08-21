import SwiftUI
import SceneKit

/// The dollhouse, rendered as real solid geometry instead of a line drawing —
/// extruded walls with soft shading, a real floor slab, and SceneKit's own
/// orbit camera (drag to rotate with inertia, pinch to zoom) rather than a
/// hand-rolled single-axis gesture.
struct DollhouseSceneView: UIViewRepresentable {
    let plan: FloorPlan

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = SceneBuilder.build(from: plan)
        view.backgroundColor = .clear
        view.allowsCameraControl = true
        view.antialiasingMode = .multisampling4X
        view.autoenablesDefaultLighting = false

        let controller = view.defaultCameraController
        controller.interactionMode = .orbitTurntable
        controller.inertiaEnabled = true
        // Keeps the orbit from flipping past straight-down or below the
        // floor, where a dollhouse stops reading as a dollhouse.
        controller.minimumVerticalAngle = -5
        controller.maximumVerticalAngle = 85

        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}
}

private enum SceneBuilder {
    /// Interior wall thickness — walls are drawn as zero-thickness lines
    /// everywhere else in the app, but a real 3D wall needs a real thickness
    /// or it disappears edge-on from most camera angles.
    static let wallThickness: CGFloat = 0.12
    static let doorThickness: CGFloat = 0.06

    static func build(from plan: FloorPlan) -> SCNScene {
        let scene = SCNScene()
        let root = scene.rootNode

        addLighting(to: root)

        if let floorPath = floorPath(from: plan) {
            root.addChildNode(floorNode(path: floorPath))
        }

        for segment in plan.walls {
            root.addChildNode(wallNode(
                for: segment,
                thickness: wallThickness,
                color: UIColor(Theme.ink).withAlphaComponent(segment.isReliable ? 1 : 0.55)
            ))
        }
        for segment in plan.doors {
            root.addChildNode(wallNode(for: segment, thickness: doorThickness, color: UIColor(Theme.accent)))
        }
        for segment in plan.windows {
            root.addChildNode(wallNode(
                for: segment,
                thickness: doorThickness,
                color: UIColor(Theme.accent).withAlphaComponent(0.6)
            ))
        }
        for item in plan.furniture {
            root.addChildNode(furnitureNode(for: item))
        }

        // Framed from the scene's real bounding sphere rather than a 2D-bounds
        // heuristic, so furniture, wall height, and floor extent all factor
        // into what "fits in frame" actually means.
        root.addChildNode(cameraNode(framing: root))
        return scene
    }

    // MARK: - Lighting

    /// Three-point lighting, the standard product-render setup: a warm key
    /// light doing the actual modeling (and the only one casting shadows —
    /// a second shadow-casting light would double the shadows and look
    /// wrong), a cool fill opposite it so unlit faces don't crush to black,
    /// and a low ambient floor under both.
    private static func addLighting(to root: SCNNode) {
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 280
        ambient.color = UIColor(Theme.paper)
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        root.addChildNode(ambientNode)

        let key = SCNLight()
        key.type = .directional
        key.intensity = 1000
        key.castsShadow = true
        key.shadowRadius = 10
        key.shadowSampleCount = 16
        key.shadowColor = UIColor.black.withAlphaComponent(0.32)
        key.color = UIColor(red: 1.0, green: 0.97, blue: 0.92, alpha: 1)
        let keyNode = SCNNode()
        keyNode.light = key
        // Low afternoon-sun angle so extruded walls actually cast a readable
        // shadow instead of lighting flat from straight above.
        keyNode.eulerAngles = SCNVector3(-Float.pi / 3.2, Float.pi / 4, 0)
        root.addChildNode(keyNode)

        let fill = SCNLight()
        fill.type = .directional
        fill.intensity = 320
        fill.castsShadow = false
        fill.color = UIColor(red: 0.82, green: 0.87, blue: 0.95, alpha: 1)
        let fillNode = SCNNode()
        fillNode.light = fill
        fillNode.eulerAngles = SCNVector3(-Float.pi / 5, -Float.pi * 0.7, 0)
        root.addChildNode(fillNode)
    }

    // MARK: - Geometry

    private static func floorPath(from plan: FloorPlan) -> UIBezierPath? {
        let polygons = plan.floorPolygons
        guard !polygons.isEmpty else { return nil }
        let path = UIBezierPath()
        for polygon in polygons {
            path.move(to: polygon[0])
            for point in polygon.dropFirst() {
                path.addLine(to: point)
            }
            path.close()
        }
        return path
    }

    private static func floorNode(path: UIBezierPath) -> SCNNode {
        let shape = SCNShape(path: path, extrusionDepth: 0.02)
        shape.firstMaterial?.diffuse.contents = UIColor(Theme.cardBackground)
        shape.firstMaterial?.lightingModel = .physicallyBased
        shape.firstMaterial?.roughness.contents = 0.65
        shape.firstMaterial?.metalness.contents = 0.0
        let node = SCNNode(geometry: shape)
        // SCNShape extrudes in its own local XY plane; laying it flat as a
        // floor means rotating that plane down onto the world's XZ ground.
        node.eulerAngles.x = -Float.pi / 2
        node.castsShadow = false
        return node
    }

    private static func wallNode(for segment: FloorPlan.Segment, thickness: CGFloat, color: UIColor) -> SCNNode {
        let box = SCNBox(
            width: max(CGFloat(segment.lengthMeters), 0.02),
            height: max(CGFloat(segment.heightMeters), 0.02),
            length: thickness,
            chamferRadius: 0
        )
        box.firstMaterial?.diffuse.contents = color
        box.firstMaterial?.lightingModel = .physicallyBased
        box.firstMaterial?.roughness.contents = 0.82
        box.firstMaterial?.metalness.contents = 0.0

        let node = SCNNode(geometry: box)
        node.castsShadow = true
        let mid = segment.midpoint
        node.position = SCNVector3(
            Float(mid.x),
            Float(segment.baseHeightMeters + segment.heightMeters / 2),
            Float(mid.y)
        )
        // Rotate the box's local X (its "width", i.e. the wall's length) to
        // align with the wall's direction in the plan's XY, mapped to the
        // scene's XZ ground plane.
        node.eulerAngles.y = -Float(segment.angle)
        return node
    }

    private static func furnitureNode(for item: FloorPlan.Furniture) -> SCNNode {
        let xs = item.footprint.map(\.x)
        let ys = item.footprint.map(\.y)
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0, maxY = ys.max() ?? 0

        let box = SCNBox(
            width: max(CGFloat(maxX - minX), 0.05),
            height: max(CGFloat(item.heightMeters), 0.05),
            length: max(CGFloat(maxY - minY), 0.05),
            chamferRadius: 0.01
        )
        box.firstMaterial?.diffuse.contents = UIColor(Theme.ink).withAlphaComponent(0.32)
        box.firstMaterial?.lightingModel = .physicallyBased
        box.firstMaterial?.roughness.contents = 0.9
        box.firstMaterial?.metalness.contents = 0.0

        let node = SCNNode(geometry: box)
        node.castsShadow = true
        node.position = SCNVector3(
            Float((minX + maxX) / 2),
            Float(item.baseHeightMeters + item.heightMeters / 2),
            Float((minY + maxY) / 2)
        )
        return node
    }

    // MARK: - Camera

    /// Fits the camera to the scene's actual bounding sphere at a fixed 3/4
    /// elevation — the classic dollhouse angle — instead of estimating
    /// distance from the 2D floor bounds, which under- or over-frames as soon
    /// as furniture or wall height matters.
    private static func cameraNode(framing root: SCNNode) -> SCNNode {
        let camera = SCNCamera()
        camera.fieldOfView = 38
        camera.wantsHDR = true

        let node = SCNNode()
        node.camera = camera

        let (center, radius) = root.boundingSphere
        let verticalFOVRadians = Float(camera.fieldOfView) * .pi / 180
        // Margin so the model doesn't touch the viewport edges.
        let distance = max(radius / sin(verticalFOVRadians / 2) * 1.25, 1)

        let azimuth: Float = .pi / 4
        let elevation: Float = .pi / 4.6
        node.position = SCNVector3(
            center.x + distance * cos(elevation) * sin(azimuth),
            center.y + distance * sin(elevation),
            center.z + distance * cos(elevation) * cos(azimuth)
        )
        node.look(at: center)
        return node
    }
}
