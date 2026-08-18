import Foundation

struct ScanRecord: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    let createdAt: Date
    var usdzFileName: String
    var thumbnailFileName: String?
    var roomFileName: String
}
