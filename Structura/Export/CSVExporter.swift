import Foundation

/// Raw SI values (meters), independent of the user's display unit — a CSV is
/// data for other tools (Excel, CAD), not a human-facing label.
enum CSVExporter {
    static func export(scan: ScanRecord, plan: FloorPlan) -> URL? {
        var rows = ["tipo,elemento,largo_m,alto_m,confianza,fuera_de_escuadra"]

        func append(_ segments: [FloorPlan.Segment], label: String) {
            for (index, segment) in segments.enumerated() {
                let height = segment.category == .wall ? String(format: "%.2f", segment.heightMeters) : ""
                rows.append([
                    label,
                    "\(label) \(index + 1)",
                    String(format: "%.2f", segment.lengthMeters),
                    height,
                    confidenceLabel(segment),
                    segment.isOutOfSquare ? "si" : "no"
                ].joined(separator: ","))
            }
        }

        append(plan.walls, label: "pared")
        append(plan.doors, label: "puerta")
        append(plan.windows, label: "ventana")
        append(plan.openings, label: "abertura")

        rows.append("")
        rows.append("totales,,,,,")
        rows.append("area_m2,,\(String(format: "%.2f", plan.floorAreaSquareMeters)),,,")
        rows.append("perimetro_m,,\(String(format: "%.2f", plan.perimeterMeters)),,,")
        rows.append("altura_m,,\(String(format: "%.2f", plan.wallHeightMeters)),,,")
        rows.append("volumen_m3,,\(String(format: "%.2f", plan.volumeCubicMeters)),,,")

        let csv = rows.joined(separator: "\n")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(ExportFileNaming.sanitized(scan.name))
            .appendingPathExtension("csv")
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private static func confidenceLabel(_ segment: FloorPlan.Segment) -> String {
        segment.isReliable ? "alta" : "baja"
    }
}

enum ExportFileNaming {
    static func sanitized(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = name.unicodeScalars.filter { allowed.contains($0) }
        let result = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? "Structura" : result
    }
}
