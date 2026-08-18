import SwiftUI

struct MeasurementsView: View {
    let plan: FloorPlan
    let unitSystem: UnitSystem

    var body: some View {
        List {
            Section("Totales") {
                row(label: "Área", value: unitSystem.formatArea(squareMeters: plan.floorAreaSquareMeters))
                row(label: "Perímetro", value: unitSystem.formatLength(meters: plan.perimeterMeters))
                row(label: "Altura", value: unitSystem.formatLength(meters: plan.wallHeightMeters))
                row(label: "Volumen", value: unitSystem.formatVolume(cubicMeters: plan.volumeCubicMeters))
            }

            group(title: "Paredes", segments: plan.walls, singular: "Pared")
            group(title: "Puertas", segments: plan.doors, singular: "Puerta")
            group(title: "Ventanas", segments: plan.windows, singular: "Ventana")
            group(title: "Aberturas", segments: plan.openings, singular: "Abertura")
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.paper)
        .navigationTitle("Medidas")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func group(title: String, segments: [FloorPlan.Segment], singular: String) -> some View {
        if !segments.isEmpty {
            Section("\(title) (\(segments.count))") {
                ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                    row(
                        label: "\(singular) \(index + 1)",
                        value: dimensions(of: segment),
                        isApproximate: !segment.isReliable,
                        note: segment.isOutOfSquare ? "Fuera de escuadra" : nil
                    )
                }
            }
        }
    }

    private func dimensions(of segment: FloorPlan.Segment) -> String {
        let length = unitSystem.formatLength(meters: segment.lengthMeters)
        guard segment.category != .wall else { return length }
        return "\(length) × \(unitSystem.formatLength(meters: segment.heightMeters))"
    }

    private func row(
        label: String,
        value: String,
        isApproximate: Bool = false,
        note: String? = nil
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .foregroundStyle(Theme.ink)
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                }
            }
            Spacer()
            Text(isApproximate ? "~\(value)" : value)
                .font(.body)
                .monospacedDigit()
                .foregroundStyle(Theme.ink.opacity(isApproximate ? 0.55 : 0.85))
        }
        .listRowBackground(Theme.cardBackground)
    }
}
