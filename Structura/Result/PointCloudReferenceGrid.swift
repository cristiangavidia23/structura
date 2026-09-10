import SceneKit
import simd

/// The engineering reference layer drawn around a Pro Scan point cloud: a
/// metric floor grid under it, a wireframe box around it, and the box's own
/// dimensions labelled on three edges.
///
/// A bare point cloud floating on black gives the eye nothing to judge size
/// or orientation against — every scan looks the same size no matter how far
/// the camera is. The grid supplies that reference at a known spacing, so
/// scale becomes readable directly from the drawing instead of only from the
/// statistics panel.
///
/// Everything here is derived from the cloud's own measured bounds. Nothing
/// is invented: the grid sits at the lowest observed point, not at an assumed
/// floor level, and the box is the real extent rather than a rounded-off
/// tidy volume.
enum PointCloudReferenceGrid {

    /// Name on the root node, so the viewer can toggle the whole layer
    /// without rebuilding it or touching the point cloud's own node.
    static let nodeName = "structura.referenceGrid"

    /// Grid spacings offered, in metres, coarsest last. The first one that
    /// keeps the line count reasonable for the scan's footprint wins — a
    /// 1 m grid over a 200 m site would be several hundred lines of pure
    /// visual noise, and a 5 m grid over a desk would draw nothing at all.
    private static let candidateSpacingsMeters: [Float] = [0.5, 1, 2, 5, 10, 20]

    /// Target upper bound on grid lines per axis.
    private static let maximumLinesPerAxis = 24

    static func makeNode(for box: PointCloudStatistics.BoundingBox) -> SCNNode {
        let root = SCNNode()
        root.name = nodeName

        let extent = box.extent
        let spacing = spacingForFootprint(width: extent.x, depth: extent.z)

        root.addChildNode(floorGridNode(for: box, spacing: spacing))
        root.addChildNode(boundingBoxNode(for: box))
        for label in dimensionLabelNodes(for: box) {
            root.addChildNode(label)
        }
        return root
    }

    // MARK: - Escala de la grilla

    private static func spacingForFootprint(width: Float, depth: Float) -> Float {
        let largestSide = max(width, depth)
        for spacing in candidateSpacingsMeters where largestSide / spacing <= Float(maximumLinesPerAxis) {
            return spacing
        }
        return candidateSpacingsMeters.last ?? 1
    }

    // MARK: - Piso

    /// Grid on the horizontal plane through the cloud's lowest point,
    /// extended out to whole multiples of the spacing so the lines land on
    /// round coordinates rather than on wherever the scan happened to end.
    private static func floorGridNode(for box: PointCloudStatistics.BoundingBox, spacing: Float) -> SCNNode {
        let minX = (box.minimum.x / spacing).rounded(.down) * spacing
        let maxX = (box.maximum.x / spacing).rounded(.up) * spacing
        let minZ = (box.minimum.z / spacing).rounded(.down) * spacing
        let maxZ = (box.maximum.z / spacing).rounded(.up) * spacing
        let y = box.minimum.y

        var vertices: [SCNVector3] = []
        var x = minX
        while x <= maxX + spacing / 2 {
            vertices.append(SCNVector3(x, y, minZ))
            vertices.append(SCNVector3(x, y, maxZ))
            x += spacing
        }
        var z = minZ
        while z <= maxZ + spacing / 2 {
            vertices.append(SCNVector3(minX, y, z))
            vertices.append(SCNVector3(maxX, y, z))
            z += spacing
        }

        let node = SCNNode(geometry: lineGeometry(vertices: vertices, color: UIColor(white: 1, alpha: 0.16)))
        node.name = "\(nodeName).floor"
        return node
    }

    // MARK: - Caja delimitadora

    /// The twelve edges of the axis-aligned box, drawn brighter than the
    /// floor grid: this one is a measurement (the scan's real extent), not
    /// just a visual reference.
    private static func boundingBoxNode(for box: PointCloudStatistics.BoundingBox) -> SCNNode {
        let low = box.minimum
        let high = box.maximum
        let corners = [
            SIMD3<Float>(low.x, low.y, low.z), SIMD3<Float>(high.x, low.y, low.z),
            SIMD3<Float>(high.x, low.y, high.z), SIMD3<Float>(low.x, low.y, high.z),
            SIMD3<Float>(low.x, high.y, low.z), SIMD3<Float>(high.x, high.y, low.z),
            SIMD3<Float>(high.x, high.y, high.z), SIMD3<Float>(low.x, high.y, high.z)
        ]
        // Bottom ring, top ring, then the four verticals joining them.
        let edges = [
            (0, 1), (1, 2), (2, 3), (3, 0),
            (4, 5), (5, 6), (6, 7), (7, 4),
            (0, 4), (1, 5), (2, 6), (3, 7)
        ]

        var vertices: [SCNVector3] = []
        for (start, end) in edges {
            vertices.append(SCNVector3(corners[start].x, corners[start].y, corners[start].z))
            vertices.append(SCNVector3(corners[end].x, corners[end].y, corners[end].z))
        }

        let node = SCNNode(geometry: lineGeometry(vertices: vertices, color: UIColor(white: 1, alpha: 0.42)))
        node.name = "\(nodeName).box"
        return node
    }

    // MARK: - Acotación

    /// One figure per axis, placed at the middle of an edge of the box that
    /// runs along that axis, and billboarded so it stays readable from any
    /// orbit position.
    ///
    /// Always in metres: this is the project's internal unit, and the 3D
    /// inspector is an engineering view rather than a consumer one — the
    /// unit-converted figures live in the measurements list.
    private static func dimensionLabelNodes(for box: PointCloudStatistics.BoundingBox) -> [SCNNode] {
        let extent = box.extent
        let low = box.minimum
        let high = box.maximum
        // Offset the text off the edge it annotates so it doesn't z-fight
        // with the line itself.
        let clearance = max(extent.x, extent.y, extent.z) * 0.03

        let placements: [(value: Float, position: SIMD3<Float>)] = [
            (extent.x, SIMD3((low.x + high.x) / 2, low.y - clearance, high.z + clearance)),
            (extent.z, SIMD3(high.x + clearance, low.y - clearance, (low.z + high.z) / 2)),
            (extent.y, SIMD3(high.x + clearance, (low.y + high.y) / 2, high.z + clearance))
        ]

        return placements.compactMap { placement in
            // Below a centimetre there is nothing meaningful to annotate,
            // and the label would just collide with the others.
            guard placement.value >= 0.01 else { return nil }
            return labelNode(
                text: String(format: "%.2f m", placement.value),
                at: placement.position,
                referenceSize: max(extent.x, extent.y, extent.z)
            )
        }
    }

    private static func labelNode(text: String, at position: SIMD3<Float>, referenceSize: Float) -> SCNNode {
        let geometry = SCNText(string: text, extrusionDepth: 0)
        geometry.font = .monospacedDigitSystemFont(ofSize: 8, weight: .medium)
        geometry.flatness = 0.2
        geometry.firstMaterial?.diffuse.contents = UIColor(white: 1, alpha: 0.75)
        geometry.firstMaterial?.lightingModel = .constant
        geometry.firstMaterial?.isDoubleSided = true

        let node = SCNNode(geometry: geometry)
        // `SCNText` is laid out in points, which have nothing to do with the
        // scene's metres — scale it to a fixed fraction of the scan's size so
        // labels read the same on a desk-sized capture and a building.
        let scale = referenceSize * 0.012
        node.scale = SCNVector3(scale, scale, scale)
        // `SCNText` grows from its own origin rather than around a centre.
        let (minBound, maxBound) = geometry.boundingBox
        node.pivot = SCNMatrix4MakeTranslation((minBound.x + maxBound.x) / 2, (minBound.y + maxBound.y) / 2, 0)
        node.position = SCNVector3(position.x, position.y, position.z)
        node.constraints = [SCNBillboardConstraint()]
        node.name = "\(nodeName).label"
        return node
    }

    // MARK: - Utilidades

    /// One geometry holding many independent segments: `vertices` is read in
    /// consecutive pairs, so segment *n* runs from `vertices[2n]` to
    /// `vertices[2n+1]`. Far cheaper than a node per line.
    private static func lineGeometry(vertices: [SCNVector3], color: UIColor) -> SCNGeometry {
        let source = SCNGeometrySource(vertices: vertices)
        let indices = Array(UInt32(0)..<UInt32(vertices.count))
        let element = SCNGeometryElement(
            data: Data(bytes: indices, count: indices.count * MemoryLayout<UInt32>.size),
            primitiveType: .line,
            primitiveCount: vertices.count / 2,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )

        let geometry = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.lightingModel = .constant
        // The reference layer must never occlude the data it frames.
        material.writesToDepthBuffer = false
        geometry.materials = [material]
        return geometry
    }
}
