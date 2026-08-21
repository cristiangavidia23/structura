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
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        view.antialiasingMode = .multisampling4X
        view.autoenablesDefaultLighting = false
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

        root.addChildNode(cameraNode(for: plan.bounds))
        return scene
    }

    private static func addLighting(to root: SCNNode) {
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 500
        ambient.color = UIColor(Theme.paper)
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        root.addChildNode(ambientNode)

        let sun = SCNLight()
        sun.type = .directional
        sun.intensity = 950
        sun.castsShadow = true
        sun.shadowRadius = 8
        sun.shadowColor = UIColor.black.withAlphaComponent(0.4)
        sun.color = UIColor.white
        let sunNode = SCNNode()
        sunNode.light = sun
        // Angled like a low afternoon sun so extruded walls actually cast a
        // readable shadow instead of lighting flat from straight above.
        sunNode.eulerAngles = SCNVector3(-Float.pi / 3.2, Float.pi / 4, 0)
        root.addChildNode(sunNode)
    }

    private static func floorPath(from plan: FloorPlan) -> UIBezierPath? {
        let walls = plan.walls
        guard !walls.isEmpty else { return nil }
        let path = UIBezierPath()
        path.move(to: walls[0].start)
        for wall in walls { path.addLine(to: wall.end) }
        path.close()
        return path
    }

    private static func floorNode(path: UIBezierPath) -> SCNNode {
        let shape = SCNShape(path: path, extrusionDepth: 0.02)
        shape.firstMaterial?.diffuse.contents = UIColor(Theme.cardBackground)
        shape.firstMaterial?.lightingModel = .physicallyBased
        shape.firstMaterial?.roughness.contents = 0.95
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
        box.firstMaterial?.roughness.contents = 0.85

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

        let node = SCNNode(geometry: box)
        node.castsShadow = true
        node.position = SCNVector3(
            Float((minX + maxX) / 2),
            Float(item.baseHeightMeters + item.heightMeters / 2),
            Float((minY + maxY) / 2)
        )
        return node
    }

    private static func cameraNode(for bounds: CGRect) -> SCNNode {
        let camera = SCNCamera()
        camera.fieldOfView = 42
        camera.wantsHDR = true

        let node = SCNNode()
        node.camera = camera

        let extent = max(Double(bounds.width), Double(bounds.height), 1)
        let distance = extent * 1.5
        node.position = SCNVector3(
            Float(bounds.midX) + Float(distance) * 0.6,
            Float(distance) * 0.55,
            Float(bounds.midY) + Float(distance) * 0.6
        )
        node.look(at: SCNVector3(Float(bounds.midX), 0, Float(bounds.midY)))
        return node
    }
}
