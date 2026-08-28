import XCTest

/// Guards `PointCloudMeshClassification`'s raw values against silently
/// drifting from ARKit's own `ARMeshClassification` (`ARMeshGeometry.h`,
/// verified against the installed iOS 26.5 SDK: None=0, Wall=1, Floor=2,
/// Ceiling=3, Table=4, Seat=5, Window=6, Door=7).
final class PointCloudMeshClassificationTests: XCTestCase {
    func testRawValuesMatchARMeshClassification() {
        XCTAssertEqual(PointCloudMeshClassification.none.rawValue, 0)
        XCTAssertEqual(PointCloudMeshClassification.wall.rawValue, 1)
        XCTAssertEqual(PointCloudMeshClassification.floor.rawValue, 2)
        XCTAssertEqual(PointCloudMeshClassification.ceiling.rawValue, 3)
        XCTAssertEqual(PointCloudMeshClassification.table.rawValue, 4)
        XCTAssertEqual(PointCloudMeshClassification.seat.rawValue, 5)
        XCTAssertEqual(PointCloudMeshClassification.window.rawValue, 6)
        XCTAssertEqual(PointCloudMeshClassification.door.rawValue, 7)
    }

    func testAllCasesCoverTheFullByteRangeArkitPublishes() {
        XCTAssertEqual(PointCloudMeshClassification.allCases.count, 8)
    }
}
