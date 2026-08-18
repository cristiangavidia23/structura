import UIKit
import CoreGraphics

enum PDFExporter {
    /// US Letter at 72pt/inch — matches what AirPrint and most home printers expect by default.
    private static let pageSize = CGSize(width: 612, height: 792)
    private static let margin: CGFloat = 40

    static func export(scan: ScanRecord, plan: FloorPlan, unitSystem: UnitSystem) -> URL? {
        guard plan.bounds.width > 0, plan.bounds.height > 0 else { return nil }

        let pageRect = CGRect(origin: .zero, size: pageSize)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(ExportFileNaming.sanitized(scan.name))
            .appendingPathExtension("pdf")

        do {
            try renderer.writePDF(to: url) { context in
                context.beginPage()
                draw(scan: scan, plan: plan, unitSystem: unitSystem, in: context.cgContext, pageRect: pageRect)
            }
            return url
        } catch {
            return nil
        }
    }

    private static func draw(scan: ScanRecord, plan: FloorPlan, unitSystem: UnitSystem, in ctx: CGContext, pageRect: CGRect) {
        drawText(
            scan.name,
            at: CGPoint(x: margin, y: margin),
            font: .systemFont(ofSize: 18, weight: .semibold)
        )
        drawText(
            "Structura · \(scan.createdAt.formatted(date: .long, time: .omitted))",
            at: CGPoint(x: margin, y: margin + 24),
            font: .systemFont(ofSize: 11),
            color: .darkGray
        )

        let footerHeight: CGFloat = 56
        let planArea = CGRect(
            x: margin,
            y: margin + 56,
            width: pageRect.width - margin * 2,
            height: pageRect.height - margin - footerHeight - (margin + 56)
        )

        let scale = min(planArea.width / plan.bounds.width, planArea.height / plan.bounds.height) * 0.88
        let originX = planArea.midX - plan.bounds.midX * scale
        let originY = planArea.midY - plan.bounds.midY * scale

        func point(_ p: CGPoint) -> CGPoint {
            CGPoint(x: originX + p.x * scale, y: originY + p.y * scale)
        }

        for segment in plan.segments {
            ctx.setLineWidth(segment.category == .wall ? 2 : 1.3)
            ctx.setStrokeColor(strokeColor(for: segment).cgColor)
            if segment.category == .opening || !segment.isReliable {
                ctx.setLineDash(phase: 0, lengths: [4, 3])
            } else {
                ctx.setLineDash(phase: 0, lengths: [])
            }
            ctx.beginPath()
            ctx.move(to: point(segment.start))
            ctx.addLine(to: point(segment.end))
            ctx.strokePath()
        }
        ctx.setLineDash(phase: 0, lengths: [])

        for wall in plan.walls {
            let text = unitSystem.formatLength(meters: wall.lengthMeters)
            drawText(
                wall.isReliable ? text : "~\(text)",
                at: point(wall.midpoint),
                font: .monospacedDigitSystemFont(ofSize: 9, weight: .medium),
                color: wall.isReliable ? .black : .gray,
                centered: true,
                plate: true
            )
        }

        let summary = [
            "Área \(unitSystem.formatArea(squareMeters: plan.floorAreaSquareMeters))",
            "Perímetro \(unitSystem.formatLength(meters: plan.perimeterMeters))",
            "Altura \(unitSystem.formatLength(meters: plan.wallHeightMeters))",
            "Volumen \(unitSystem.formatVolume(cubicMeters: plan.volumeCubicMeters))"
        ].joined(separator: "   ·   ")
        drawText(
            summary,
            at: CGPoint(x: margin, y: pageRect.height - footerHeight),
            font: .systemFont(ofSize: 10, weight: .medium),
            color: .darkGray
        )

        drawText(
            "Medidas obtenidas por escaneo LiDAR (RoomPlan). Los valores marcados con ~ son aproximados.",
            at: CGPoint(x: margin, y: pageRect.height - footerHeight + 20),
            font: .systemFont(ofSize: 8),
            color: .gray
        )
    }

    private static func strokeColor(for segment: FloorPlan.Segment) -> UIColor {
        switch segment.category {
        case .wall: return segment.isReliable ? .black : UIColor.black.withAlphaComponent(0.4)
        case .door: return UIColor(Theme.accent)
        case .window: return UIColor(Theme.accent).withAlphaComponent(0.65)
        case .opening: return UIColor.black.withAlphaComponent(0.35)
        }
    }

    /// `UIGraphicsPDFRenderer`'s draw closure runs with the PDF context already
    /// current, so `NSString` drawing works directly — no manual CGContext text APIs needed.
    private static func drawText(
        _ text: String,
        at point: CGPoint,
        font: UIFont,
        color: UIColor = .black,
        centered: Bool = false,
        plate: Bool = false
    ) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attributes)
        let origin = centered
            ? CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
            : point

        if plate {
            let plateRect = CGRect(origin: origin, size: size).insetBy(dx: -3, dy: -1)
            UIColor.white.withAlphaComponent(0.85).setFill()
            UIBezierPath(roundedRect: plateRect, cornerRadius: 3).fill()
        }

        (text as NSString).draw(at: origin, withAttributes: attributes)
    }
}
