/// Mirrors ARKit's `ARMeshClassification` (`ARMeshGeometry.h`) case-for-case
/// and raw-value-for-raw-value, without importing ARKit — this type is used
/// by `PointCloudExportPoint` and by exporters that have no reason to
/// depend on the framework, and by `VoxelAccumulator`/`ARPointCloudSession`
/// at the capture boundary. Keeping the raw values aligned means converting
/// a byte read directly from `ARMeshGeometry.classification` is just
/// `PointCloudMeshClassification(rawValue: byte) ?? .none` — no need to
/// touch ARKit's own enum type at all.
///
/// `PointCloudMeshClassificationTests` guards these raw values against
/// silently drifting from ARKit's own enum.
enum PointCloudMeshClassification: UInt8, CaseIterable {
    case none = 0
    case wall = 1
    case floor = 2
    case ceiling = 3
    case table = 4
    case seat = 5
    case window = 6
    case door = 7
}
