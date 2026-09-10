import SwiftUI
import RoomPlan

struct ResultView: View {
    let scan: ScanRecord
    let store: ScanStore

    @AppStorage("unitSystem") private var unitSystemRaw = UnitSystem.metric.rawValue
    @EnvironmentObject private var purchases: PurchaseManager
    @State private var mode: Mode = .dollhouse
    @State private var shareURL: URL?
    @State private var isPresentingShare = false
    @State private var isPresentingPaywall = false
    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var isPresentingProScan = false
    @Namespace private var modeSelection

    private enum Mode: String, CaseIterable {
        case dollhouse = "3D"
        case plan = "Plano"
        case heatmap = "Color real"
        #if DEBUG
        case experimentalPlan = "Plano (exp.)"
        #endif
    }

    /// Heatmap only shows up once a Pro Scan pass actually produced a point
    /// cloud for this scan — nothing to view otherwise. The experimental
    /// plan (F4 of the architecture audit) rides the same PLY, but is
    /// compiled only into `#if DEBUG` builds — see
    /// `PointCloudFloorPlanDebugView`'s doc comment for why it's not offered
    /// to real users yet.
    private var availableModes: [Mode] {
        var modes: [Mode] = [.dollhouse, .plan]
        if store.plyURL(for: currentScan) != nil {
            modes.append(.heatmap)
            #if DEBUG
            modes.append(.experimentalPlan)
            #endif
        }
        return modes
    }

    private var unitSystem: UnitSystem {
        UnitSystem(rawValue: unitSystemRaw) ?? .metric
    }

    private var plan: FloorPlan? {
        store.capturedStructure(for: scan).map { FloorPlan(structure: $0) }
    }

    /// `scan` is a value-type snapshot from when this view was pushed; reading
    /// the name back from the store keeps it live after a rename instead of
    /// showing stale text until the view is popped and re-pushed.
    private var currentScan: ScanRecord {
        store.scans.first { $0.id == scan.id } ?? scan
    }

    var body: some View {
        ZStack {
            Theme.paper.ignoresSafeArea()
            GraphPaperBackground().ignoresSafeArea()

            VStack(spacing: 0) {
                modeSelector

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let plan, !plan.walls.isEmpty, mode == .dollhouse || mode == .plan {
                    VStack(spacing: 0) {
                        if mode == .plan, let caveat = caveat(for: plan) {
                            Text(caveat)
                                .font(.caption)
                                .foregroundStyle(Theme.ink.opacity(0.6))
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, 20)
                                .padding(.top, 12)
                                .transition(.opacity)
                        }

                        NavigationLink {
                            MeasurementsView(plan: plan, unitSystem: unitSystem)
                        } label: {
                            HStack(spacing: 8) {
                                summary(for: plan)
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Theme.ink.opacity(0.35))
                                    .accessibilityHidden(true)
                            }
                            .padding(.trailing, 20)
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            "Área \(unitSystem.formatArea(squareMeters: plan.floorAreaSquareMeters)), "
                                + "altura \(unitSystem.formatLength(meters: plan.wallHeightMeters)), "
                                + "volumen \(unitSystem.formatVolume(cubicMeters: plan.volumeCubicMeters))"
                        )
                        .accessibilityHint("Toca para ver el detalle de medidas")
                    }
                    .background(Theme.cardBackground)
                }
            }
        }
        .navigationTitle(currentScan.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    renameText = currentScan.name
                    isRenaming = true
                } label: {
                    Image(systemName: "pencil")
                }
                .accessibilityLabel("Renombrar")
            }
            if let plan {
                ToolbarItem(placement: .topBarTrailing) {
                    exportMenu(for: plan)
                }
            }
        }
        .animation(.smooth(duration: 0.85), value: mode)
        .sheet(isPresented: $isPresentingShare) {
            if let shareURL {
                ActivityView(items: [shareURL])
            }
        }
        .sheet(isPresented: $isPresentingPaywall) {
            PaywallView(backgroundPlan: plan)
        }
        .fullScreenCover(isPresented: $isPresentingProScan) {
            ProScanCaptureView(record: currentScan, store: store) {}
        }
        .alert("Renombrar escaneo", isPresented: $isRenaming) {
            TextField("Nombre", text: $renameText)
            Button("Cancelar", role: .cancel) {}
            Button("Guardar") {
                store.rename(currentScan, to: renameText)
            }
        }
    }

    /// The view switcher, as its own full-width bar under the navigation bar
    /// rather than a segmented `Picker` in the toolbar's `.principal` slot.
    /// Two reasons: that slot is where the scan's name belongs (the picker was
    /// displacing it, so the name was never visible), and a fixed-width
    /// segmented control silently truncates its labels once a fourth mode
    /// exists ("Color real" → "Color…"). Dividing the full width by the number
    /// of modes scales to however many there are.
    private var modeSelector: some View {
        HStack(spacing: 0) {
            ForEach(availableModes, id: \.self) { candidate in
                let isSelected = candidate == mode
                Button {
                    mode = candidate
                } label: {
                    VStack(spacing: 0) {
                        Text(candidate.rawValue)
                            .font(.footnote.weight(isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? Theme.ink : Theme.ink.opacity(0.45))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)

                        // Slides between tabs rather than cross-fading in
                        // place, so the selected mode stays traceable when
                        // the content below is also animating.
                        if isSelected {
                            Capsule()
                                .fill(Theme.accent)
                                .frame(height: 2)
                                .matchedGeometryEffect(id: "selectedMode", in: modeSelection)
                        } else {
                            Color.clear.frame(height: 2)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.horizontal, 12)
        .background(alignment: .bottom) {
            Rectangle()
                .fill(Theme.ink.opacity(0.12))
                .frame(height: 1)
        }
        // Overrides the slower content transition the whole body carries: a
        // tab underline that takes 0.85 s to travel reads as lag, not polish.
        .animation(.snappy(duration: 0.28), value: mode)
    }

    private func exportMenu(for plan: FloorPlan) -> some View {
        Menu {
            Button {
                exportOrPaywall { share(PDFExporter.export(scan: currentScan, plan: plan, unitSystem: unitSystem)) }
            } label: {
                Label("Plano acotado (PDF)", systemImage: "doc.richtext")
            }
            Button {
                exportOrPaywall { share(store.usdzURL(for: scan)) }
            } label: {
                Label("Modelo 3D (USDZ)", systemImage: "cube")
            }
            Button {
                exportOrPaywall { share(CSVExporter.export(scan: currentScan, plan: plan)) }
            } label: {
                Label("Medidas (CSV)", systemImage: "tablecells")
            }

            if let plyURL = store.plyURL(for: currentScan) {
                Button {
                    exportOrPaywall { share(plyURL) }
                } label: {
                    Label("Nube de puntos (PLY)", systemImage: "aqi.medium")
                }
            }
            if let lasURL = store.lasURL(for: currentScan) {
                Button {
                    exportOrPaywall { share(lasURL) }
                } label: {
                    Label("Nube de puntos (LAS)", systemImage: "aqi.medium")
                }
            }
            if ProScanCoordinator.isSupported {
                Button {
                    exportOrPaywall { isPresentingProScan = true }
                } label: {
                    Label(
                        store.plyURL(for: currentScan) == nil ? "Mejorar con Pro Scan" : "Repetir Pro Scan",
                        systemImage: "wand.and.stars"
                    )
                }
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .accessibilityLabel("Exportar")
    }

    /// Every export format is premium — v1's free tier lets you scan, not export.
    private func exportOrPaywall(_ export: () -> Void) {
        guard purchases.isPremium else {
            isPresentingPaywall = true
            return
        }
        export()
    }

    private func share(_ url: URL?) {
        guard let url else { return }
        shareURL = url
        isPresentingShare = true
    }

    // `#if DEBUG` can't split an `if`/`else if` chain inside a `@ViewBuilder`
    // (the parser rejects an `else` reintroduced after an `#endif`) — this
    // branches out to its own top-level `if` instead, falling through to
    // `nonExperimentalContent` for every other case.
    @ViewBuilder
    private var content: some View {
        #if DEBUG
        if mode == .experimentalPlan, let plyURL = store.plyURL(for: currentScan) {
            PointCloudFloorPlanDebugView(plyURL: plyURL, reference: plan)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                .id(mode)
        } else {
            nonExperimentalContent
        }
        #else
        nonExperimentalContent
        #endif
    }

    @ViewBuilder
    private var nonExperimentalContent: some View {
        if mode == .heatmap, let plyURL = store.plyURL(for: currentScan) {
            HeatmapTabView(plyURL: plyURL, quality: currentScan.pointCloudQuality, unitSystem: unitSystem)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                .id(mode)
        } else if let plan, !plan.walls.isEmpty {
            Group {
                switch mode {
                case .dollhouse:
                    DollhouseSceneView(plan: plan)
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                case .plan:
                    FloorPlanView(plan: plan, unitSystem: unitSystem)
                        .padding(8)
                        .transition(.opacity.combined(with: .scale(scale: 1.03)))
                case .heatmap:
                    EmptyView()
                #if DEBUG
                case .experimentalPlan:
                    // Unreachable: `content` routes `.experimentalPlan` to
                    // `PointCloudFloorPlanDebugView` before ever reaching
                    // this fallback. Only here so the switch stays
                    // exhaustive against `Mode`'s full DEBUG case set.
                    EmptyView()
                #endif
                }
            }
            .id(mode)
        } else if plan != nil {
            emptyGeometryState
        } else {
            Text("No se pudo cargar la geometría del escaneo.")
                .font(.subheadline)
                .foregroundStyle(Theme.ink.opacity(0.6))
        }
    }

    /// The geometry loaded but has no walls — a scan that ended almost
    /// immediately, or one done from too far to detect any surface. Distinct
    /// from a load failure: here the file is fine, the capture just didn't
    /// pick up a room.
    private var emptyGeometryState: some View {
        VStack(spacing: 10) {
            Image(systemName: "viewfinder")
                .font(.system(size: 30))
                .foregroundStyle(Theme.ink.opacity(0.3))
            Text("No se detectaron paredes en este escaneo")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.ink)
            Text("Puede pasar si el escaneo terminó muy pronto. Intenta escanear de nuevo, moviéndote más despacio y apuntando a las paredes.")
                .font(.caption)
                .foregroundStyle(Theme.ink.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    /// Surfaces what the drawing itself cannot: which numbers are inferred, and
    /// where the room is genuinely out of square rather than just noisy.
    private func caveat(for plan: FloorPlan) -> String? {
        var notes: [String] = []

        let approximate = plan.unreliableWalls.count
        if approximate > 0 {
            notes.append(approximate == 1
                ? "1 pared no se escaneó completa (medida aproximada)"
                : "\(approximate) paredes no se escanearon completas (medidas aproximadas)")
        }

        let outOfSquare = plan.outOfSquareWalls.count
        if outOfSquare > 0 {
            notes.append(outOfSquare == 1
                ? "1 pared está fuera de escuadra"
                : "\(outOfSquare) paredes están fuera de escuadra")
        }

        return notes.isEmpty ? nil : notes.joined(separator: " · ")
    }

    private func summary(for plan: FloorPlan) -> some View {
        HStack(spacing: 24) {
            metric(title: "Área", value: unitSystem.formatArea(squareMeters: plan.floorAreaSquareMeters))
            metric(title: "Altura", value: unitSystem.formatLength(meters: plan.wallHeightMeters))
            metric(title: "Volumen", value: unitSystem.formatVolume(cubicMeters: plan.volumeCubicMeters))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private func metric(title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Theme.ink.opacity(0.55))
            Text(value)
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
        }
    }
}

/// Loads the Pro Scan point cloud from its exported PLY lazily, once, when
/// this tab first appears — the file can hold hundreds of thousands of
/// points, not something to parse on every mode switch. Also hosts the
/// tap-to-measure tool and the post-capture QA panel (coverage, tracking
/// quality, drift risk).
private struct HeatmapTabView: View {
    let plyURL: URL
    /// Persisted from the export that produced this file (`ScanRecord
    /// .pointCloudQuality`) — `nil` for scans exported before Fase 5, or if
    /// the metadata step failed independently of the point cloud itself.
    let quality: PointCloudQualitySummary?
    let unitSystem: UnitSystem

    @State private var points: [PointCloudExportPoint]?
    @State private var isLoading = true
    @State private var coverage: ScanCoverageEstimator.Report?
    @StateObject private var measurement = MeasurementSession()
    @State private var isPresentingCalibrationInput = false
    @State private var calibrationReferenceText = ""

    // Inspector 3D
    @State private var statistics: PointCloudStatistics.Report?
    @State private var showsReferenceGrid = false
    @State private var pointSizeMultiplier: Float = 1
    @State private var isShowingStatistics = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                Group {
                    if let points, !points.isEmpty {
                        PointCloudSceneView(
                            points: points,
                            measurement: measurement,
                            statistics: statistics,
                            showsReferenceGrid: showsReferenceGrid,
                            pointSizeMultiplier: pointSizeMultiplier
                        )
                    } else if isLoading {
                        ProgressView()
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "aqi.medium")
                                .font(.system(size: 30))
                                .foregroundStyle(Theme.ink.opacity(0.3))
                            Text("No se pudo cargar la nube de puntos")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Theme.ink)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let points, !points.isEmpty {
                    measurementOverlay
                        .padding(.top, 12)

                    inspectorControls
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(.leading, 16)
                        .padding(.bottom, 16)
                }
            }

            qaPanel
        }
        .task {
            // Off the main actor: a Pro Scan PLY can hold hundreds of
            // thousands of points, and parsing that inline would hitch the
            // tab switch.
            let url = plyURL
            let loaded = await Task.detached(priority: .userInitiated) {
                PLYPointCloudReader.read(from: url)
            }.value
            points = loaded
            isLoading = false

            guard let loaded else { return }
            // Both are whole-cloud passes, so they stay off the main actor
            // and run after the cloud is already on screen rather than
            // delaying it.
            coverage = await Task.detached(priority: .utility) {
                ScanCoverageEstimator.estimateCoverage(of: loaded, voxelSize: ProScanConfig.coverageVoxelSizeMeters)
            }.value
            statistics = await Task.detached(priority: .utility) {
                PointCloudStatistics.make(of: loaded)
            }.value
        }
        .alert("Calibrar con distancia conocida", isPresented: $isPresentingCalibrationInput) {
            TextField("Distancia real (m)", text: $calibrationReferenceText)
                .keyboardType(.decimalPad)
            Button("Cancelar", role: .cancel) {}
            Button("Calcular error") {
                let normalized = calibrationReferenceText.replacingOccurrences(of: ",", with: ".")
                if let reference = Float(normalized) {
                    measurement.calibrate(referenceMeters: reference)
                }
            }
        } message: {
            Text("Mide un objeto o distancia que ya conoces (por ejemplo, una puerta estándar o una cinta métrica) y escribe aquí su medida real en metros.")
        }
    }

    /// Floating 3D-inspector controls: reference grid, point size, and the
    /// scan's own statistics. Deliberately compact and bottom-anchored — the
    /// point cloud is the subject of this tab, so the controls stay out of
    /// the way of it and of the measurement banner at the top.
    @ViewBuilder
    private var inspectorControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isShowingStatistics, let statistics {
                statisticsPanel(statistics)
            }

            HStack(spacing: 6) {
                inspectorButton(
                    systemImage: "grid",
                    isActive: showsReferenceGrid,
                    accessibilityLabel: "Grilla y caja delimitadora"
                ) {
                    showsReferenceGrid.toggle()
                }

                inspectorButton(
                    systemImage: "chart.bar.doc.horizontal",
                    isActive: isShowingStatistics,
                    accessibilityLabel: "Estadísticas del escaneo"
                ) {
                    isShowingStatistics.toggle()
                }
                // Nothing to show, so nothing to toggle.
                .disabled(statistics == nil)
                .opacity(statistics == nil ? 0.4 : 1)

                pointSizeControl
            }
        }
    }

    private func inspectorButton(
        systemImage: String,
        isActive: Bool,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(isActive ? Theme.accent : .white.opacity(0.85))
                .frame(width: 34, height: 34)
                .background(.black.opacity(0.55), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    /// Multiplies the physically-derived point size rather than setting an
    /// absolute one, so the default (1x) stays tied to the cloud's real
    /// sample spacing and the user is adjusting legibility, not inventing a
    /// density the scan doesn't have.
    private var pointSizeControl: some View {
        HStack(spacing: 7) {
            Image(systemName: "circle.grid.3x3.fill")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
            Slider(value: $pointSizeMultiplier, in: 0.5...3)
                .frame(width: 104)
                .tint(Theme.accent)
                .accessibilityLabel("Tamaño de punto")
                .accessibilityValue(String(format: "%.1f×", pointSizeMultiplier))
        }
        .padding(.horizontal, 11)
        .frame(height: 34)
        .background(.black.opacity(0.55), in: Capsule())
    }

    private func statisticsPanel(_ statistics: PointCloudStatistics.Report) -> some View {
        let extent = statistics.boundingBox.extent
        return VStack(alignment: .leading, spacing: 3) {
            statisticsRow("Puntos", value: statistics.pointCount.formatted(.number))
            statisticsRow(
                "Densidad estricta",
                value: String(format: "%.0f pts/m³", statistics.strictDensityPerCubicMeter)
            )
            statisticsRow(
                "Densidad de caja",
                value: String(format: "%.0f pts/m³", statistics.densityPerCubicMeter)
            )
            statisticsRow(
                "Extensión",
                value: String(format: "%.2f × %.2f × %.2f m", extent.x, extent.y, extent.z)
            )
            statisticsRow(
                "Confianza media",
                value: String(format: "%.0f%%", statistics.meanObservedConfidence * 100)
            )
            // The mean above describes only the observed share, so the share
            // itself belongs next to it rather than buried in the export.
            statisticsRow(
                "Puntos con confianza real",
                value: String(format: "%.0f%%", statistics.observedConfidenceFraction * 100)
            )
        }
        .font(.caption2)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func statisticsRow(_ label: String, value: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .foregroundStyle(.white.opacity(0.6))
            Spacer(minLength: 8)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.white)
        }
        .frame(maxWidth: 230, alignment: .leading)
    }

    @ViewBuilder
    private var measurementOverlay: some View {
        VStack(spacing: 6) {
            if let distance = measurement.distanceMeters {
                HStack(spacing: 10) {
                    Label(
                        unitSystem.formatLength(meters: Double(distance)),
                        systemImage: measurement.bothPointsSnapped ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(measurement.bothPointsSnapped ? Color.green : Color.yellow)

                    Button("Calibrar") { isPresentingCalibrationInput = true }
                        .font(.caption.weight(.semibold))
                    Button("Limpiar") { measurement.clear() }
                        .font(.caption)
                }
                if let calibration = measurement.calibrationResult {
                    calibrationSummary(calibration)
                }
            } else {
                Text(
                    measurement.firstPoint == nil
                        ? "Toca dos puntos de la nube para medir la distancia entre ellos"
                        : "Toca un segundo punto para completar la medición"
                )
                .font(.caption)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .foregroundStyle(Theme.ink)
        .animation(.easeInOut, value: measurement.distanceMeters)
    }

    private func calibrationSummary(_ result: MeasurementCalibration.Result) -> some View {
        let percentageText = result.errorPercentage.map { String(format: "%.1f%%", $0) } ?? "—"
        return Text("Error: \(unitSystem.formatLength(meters: Double(result.absoluteErrorMeters))) (\(percentageText))")
            .font(.caption2)
            .foregroundStyle(Theme.ink.opacity(0.7))
    }

    @ViewBuilder
    private var qaPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let quality {
                qualityLine(quality)
                if ProScanConfig.isDriftRiskElevated(durationSeconds: quality.durationSeconds) {
                    Label("Escaneo largo — la deriva acumulada puede ser notable", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }
            if let coverage {
                Text("Cobertura estimada: \(Int(coverage.coverageRatio * 100))% del volumen del escaneo")
                    .font(.caption2)
                    .foregroundStyle(Theme.ink.opacity(0.55))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardBackground)
        .accessibilityElement(children: .combine)
    }

    private func qualityLine(_ quality: PointCloudQualitySummary) -> some View {
        Text("\(quality.pointCount.formatted()) puntos · confianza media \(Int(quality.meanConfidence * 100))% · tracking: \(quality.trackingQuality) · \(quality.durationSeconds)s")
            .font(.caption2)
            .foregroundStyle(Theme.ink.opacity(0.55))
    }
}
