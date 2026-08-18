import Foundation

enum UnitSystem: String, CaseIterable, Identifiable {
    case metric
    case imperial

    var id: String { rawValue }

    var label: String {
        switch self {
        case .metric: return "Métrico"
        case .imperial: return "Imperial"
        }
    }

    func formatLength(meters: Double) -> String {
        switch self {
        case .metric:
            return String(format: "%.2f m", meters)
        case .imperial:
            let totalInches = meters * 39.3700787
            let feet = Int(totalInches / 12)
            let inches = Int((totalInches.truncatingRemainder(dividingBy: 12)).rounded())
            return inches == 12 ? "\(feet + 1)'" : "\(feet)' \(inches)\""
        }
    }

    func formatArea(squareMeters: Double) -> String {
        switch self {
        case .metric:
            return String(format: "%.2f m²", squareMeters)
        case .imperial:
            return String(format: "%.1f ft²", squareMeters * 10.7639104)
        }
    }

    func formatVolume(cubicMeters: Double) -> String {
        switch self {
        case .metric:
            return String(format: "%.2f m³", cubicMeters)
        case .imperial:
            return String(format: "%.1f ft³", cubicMeters * 35.3146667)
        }
    }
}
