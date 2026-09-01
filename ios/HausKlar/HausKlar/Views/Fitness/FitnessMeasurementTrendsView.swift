import Charts
import SwiftUI

private struct FitnessMeasurementRenderedSeries: Identifiable {
    let source: FitnessMeasurementHistorySeriesDTO
    let linePoints: [FitnessMeasurementHistoryPointDTO]
    let pointMarks: [FitnessMeasurementHistoryPointDTO]

    var id: String { source.id }
}

/// Gesture bookkeeping deliberately lives outside SwiftUI observation. Pinch
/// events arrive faster than the display can draw; retaining the latest gesture
/// context here lets the chart apply at most one viewport update per frame
/// without invalidating the view merely to store a timestamp.
private final class FitnessMeasurementChartGestureState {
    var startingVisibleDays: Double?
    var anchorFraction: Double?
    var anchorDate: Date?
    var lastAppliedAt: TimeInterval = 0
    var didChange = false

    func reset() {
        startingVisibleDays = nil
        anchorFraction = nil
        anchorDate = nil
        lastAppliedAt = 0
        didChange = false
    }
}

struct FitnessMeasurementTrendsView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @StateObject private var viewModel = FitnessMeasurementTrendsViewModel()
    @StateObject private var photoViewModel = FitnessProgressPhotoViewModel()
    @StateObject private var syncStatus = FitnessSyncStatus.shared
    private let overview: Bool
    private let overviewHistory: FitnessMeasurementHistoryDTO?
    @State private var selectedDate: Date?
    @State private var selectedRange: FitnessMeasurementRange? = .threeMonths
    @State private var yAxisScale: FitnessMeasurementYAxisScale = .defaultScale
    @State private var visibleDays = 90.0
    @State private var scrollPosition = Date()
    @State private var chartGestureState = FitnessMeasurementChartGestureState()
    @State private var confirmingDisconnect = false
    @State private var photosRequested = false

    init(overview: Bool = false, history: FitnessMeasurementHistoryDTO? = nil) {
        self.overview = overview
        overviewHistory = history
        _selectedRange = State(initialValue: overview ? .month : .threeMonths)
        _visibleDays = State(initialValue: overview ? 30 : 90)
    }

    var body: some View {
        Group {
            if overview {
                VStack(spacing: 10) {
                    measurementContent
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        controlsCard
                        NavigationLink {
                            FitnessBodyMeasurementsView()
                        } label: {
                            Label("Add measurement", systemImage: "plus.circle.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        if let message = viewModel.noticeMessage {
                            Label(message, systemImage: "checkmark.circle.fill")
                                .font(.subheadline)
                                .foregroundStyle(.green)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                        }
                        if let error = viewModel.errorMessage {
                            VStack(alignment: .leading, spacing: 10) {
                                Label(error, systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Button("Try again", systemImage: "arrow.clockwise") {
                                    Task { await viewModel.loadHistory(refresh: true) }
                                }
                                .buttonStyle(.bordered)
                                .frame(minHeight: 44)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                        }
                        measurementContent
                    }
                    .frame(maxWidth: 980)
                    .padding(.horizontal, horizontalSizeClass == .regular ? 28 : 16)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
                }
                .background(Color(.systemGroupedBackground))
                .navigationTitle("Measurements")
                .navigationBarTitleDisplayMode(.inline)
                .refreshable { await viewModel.loadHistory(refresh: true) }
            }
        }
        .task {
            if !overview { await viewModel.loadHistory(refresh: false) }
            resetViewport()
        }
        .onChange(of: viewModel.history) { _, _ in resetViewport() }
        .onChange(of: overviewHistory) { _, _ in resetViewport() }
        .onChange(of: selectedDate) { _, newValue in
            guard newValue != nil, !photosRequested else { return }
            photosRequested = true
            Task { await photoViewModel.load() }
        }
        .onChange(of: syncStatus.lastSyncedAt) { oldValue, newValue in
            guard !overview, let newValue, newValue != oldValue else { return }
            Task { await viewModel.loadHistory(refresh: true) }
        }
        .confirmationDialog(
            "Disconnect Withings?", isPresented: $confirmingDisconnect,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                Task { await viewModel.disconnectWithings() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Automatic updates will stop. Measurements already imported into HausKlar will be kept.")
        }
    }

    private var withingsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    withingsIdentity
                    Spacer(minLength: 12)
                    withingsActions
                }
                VStack(alignment: .leading, spacing: 12) {
                    withingsIdentity
                    withingsActions
                }
            }
            if let status = viewModel.withingsStatus, status.connected {
                Label("\(status.importedMeasurementCount) imported", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(withingsTint.opacity(0.18), lineWidth: 1)
        }
    }

    private var withingsIdentity: some View {
        HStack(spacing: 12) {
            Image(systemName: withingsIcon)
                .font(.title2)
                .foregroundStyle(withingsTint)
                .frame(width: 44, height: 44)
                .background(withingsTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text("Withings").font(.headline)
                Text(withingsStatusText).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var withingsActions: some View {
        let status = viewModel.withingsStatus
        if status?.connected == true {
            HStack(spacing: 8) {
                Button {
                    Task { await viewModel.syncWithingsNow() }
                } label: {
                    if viewModel.isSyncingWithings {
                        ProgressView().frame(minWidth: 64)
                    } else {
                        Label("Sync now", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
                .disabled(!networkMonitor.isConnected || viewModel.isSyncingWithings)
                Menu {
                    Button("Disconnect Withings", systemImage: "link.badge.minus", role: .destructive) {
                        confirmingDisconnect = true
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Withings connection options")
            }
        } else if status?.configured == true {
            Button {
                Task { await viewModel.connectWithings() }
            } label: {
                if viewModel.isAuthorizing {
                    ProgressView().frame(minWidth: 90)
                } else {
                    Label("Connect", systemImage: "link")
                }
            }
            .buttonStyle(.borderedProminent)
            .frame(minHeight: 44)
            .disabled(!networkMonitor.isConnected || viewModel.isAuthorizing)
        }
    }

    private var controlsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Measurement")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            metricPicker
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metricPicker: some View {
        HStack(spacing: 3) {
            ForEach(FitnessMeasurementMetric.allCases) { metric in
                Button {
                    selectedDate = nil
                    Task { await viewModel.selectMetric(metric) }
                } label: {
                    Label(metric.compactTitle, systemImage: metric.symbol)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .padding(.horizontal, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(viewModel.metric == metric ? Color.primary : Color.secondary)
                .background(
                    viewModel.metric == metric ? Color(.secondarySystemGroupedBackground) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 9)
                )
                .accessibilityAddTraits(viewModel.metric == metric ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
    }

    private var displayModePicker: some View {
        Picker("Values", selection: $viewModel.displayMode) {
            ForEach(FitnessMeasurementDisplayMode.allCases) { mode in
                Text(mode.title.localized).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(minHeight: 44)
        .onChange(of: viewModel.displayMode) { _, _ in selectedDate = nil }
        .accessibilityLabel("Values")
        .accessibilityValue(viewModel.displayMode.title.localized)
        .accessibilityHint("Choose smoothed trend or unchanged raw measurements")
        .accessibilityIdentifier("fitnessMeasurementValues")
    }

    private var yAxisScalePicker: some View {
        Picker("Vertical scale", selection: $yAxisScale) {
            ForEach(FitnessMeasurementYAxisScale.allCases) { scale in
                Text(scale.title.localized).tag(scale)
            }
        }
        .pickerStyle(.segmented)
        .frame(minHeight: 44)
        .onChange(of: yAxisScale) { _, _ in selectedDate = nil }
        .accessibilityLabel("Vertical scale")
        .accessibilityValue(yAxisScale.title.localized)
        .accessibilityHint("Changes the space above and below the visible readings")
        .accessibilityIdentifier("fitnessMeasurementScale")
    }

    @ViewBuilder
    private var measurementContent: some View {
        if viewModel.isLoading && displayedHistory == nil {
            VStack(alignment: .leading, spacing: 10) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.tertiarySystemFill)).frame(width: 150, height: 42)
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(.tertiarySystemFill)).frame(maxWidth: .infinity, minHeight: 300)
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(.tertiarySystemFill)).frame(width: 220, height: 16)
            }
            .accessibilityLabel("Loading measurements")
        } else if let history = displayedHistory, history.sampleCount > 0 {
            chartCard(history)
            if viewModel.metric == .weight, selectedDate != nil {
                selectedWeighInPhotos(history)
            }
            Text(chartExplanation(history))
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if viewModel.errorMessage == nil {
            ContentUnavailableView {
                Label("No \(viewModel.metric.title.lowercased()) readings", systemImage: viewModel.metric.symbol)
            } description: {
                Text("Connect Withings, import from Health, or add a body measurement manually. New readings will appear automatically.")
            } actions: {
                NavigationLink("Add or review measurements") { FitnessBodyMeasurementsView() }
                    .buttonStyle(.bordered)
            }
            .frame(minHeight: 300)
        }
    }

    private var displayedHistory: FitnessMeasurementHistoryDTO? {
        overviewHistory ?? viewModel.history
    }

    @ViewBuilder
    private func selectedWeighInPhotos(_ history: FitnessMeasurementHistoryDTO) -> some View {
        let photos = photosForSelectedWeighIn(history)
        VStack(alignment: .leading, spacing: 10) {
            Label("Progress photo", systemImage: "camera.example_5f7f1d8c")
                .font(.headline)
            if !photosRequested || (photoViewModel.isLoading && photoViewModel.photos.isEmpty) {
                ProgressView("Looking for a photo from this date…")
                    .frame(maxWidth: .infinity, minHeight: 90)
            } else if let error = photoViewModel.errorMessage, photoViewModel.photos.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.orange)
                    Button("Try again", systemImage: "arrow.clockwise") {
                        Task { await photoViewModel.load(refresh: true) }
                    }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
                }
            } else if photos.isEmpty {
                Label("No progress photo from this date.", systemImage: "photo")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 10) {
                        ForEach(photos) { photo in
                            NavigationLink {
                                FitnessProgressPhotoDetailView(viewModel: photoViewModel, photo: photo)
                            } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    ProtectedFitnessImage(
                                        url: photoViewModel.thumbnailURLs[photo.id], maxPixelSize: 640
                                    )
                                    .frame(width: 190, height: 238)
                                    .clipped()
                                    Text(photo.pose.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(
                                        FitnessDatabase.date(photo.capturedAt)?.formatted(date: .abbreviated, time: .shortened)
                                            ?? photo.capturedAt
                                    )
                                    .font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(width: 190, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        }
    }

    private func photosForSelectedWeighIn(
        _ history: FitnessMeasurementHistoryDTO
    ) -> [FitnessProgressPhotoDTO] {
        guard selectedDate != nil, let date = focusedDate(history) else { return [] }
        return photoViewModel.photos
            .filter { photo in
                guard let captured = FitnessDatabase.date(photo.capturedAt) else { return false }
                return Calendar.current.isDate(captured, inSameDayAs: date)
            }
            .sorted { left, right in
                let leftIsFront = left.pose == .front
                let rightIsFront = right.pose == .front
                if leftIsFront != rightIsFront { return leftIsFront }
                return left.capturedAt < right.capturedAt
            }
    }

    private func summaryGrid(_ history: FitnessMeasurementHistoryDTO) -> some View {
        LazyVGrid(columns: summaryColumns, spacing: 10) {
            ForEach(history.series) { series in
                measurementSummaryCard(series, history: history)
            }
            VStack(alignment: .leading, spacing: 5) {
                Label("Readings", systemImage: "number")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("\(history.sampleCount)")
                    .font(.title2.weight(.bold).monospacedDigit())
            }
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func measurementSummaryCard(
        _ series: FitnessMeasurementHistorySeriesDTO, history: FitnessMeasurementHistoryDTO
    ) -> some View {
        let latest = series.points.last
        let change = visibleChange(series)
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Circle().fill(seriesColor(series.key)).frame(width: 8, height: 8)
                Text(history.series.count == 1 ? "Latest" : series.label)
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            Text(latest.map { "\(format($0.value(for: viewModel.displayMode))) \(series.unit)" } ?? "—")
                .font(.title2.weight(.bold).monospacedDigit())
            if let change {
                Text("\(change >= 0 ? "+" : "")\(format(change)) \(series.unit) in view")
                    .font(.caption).foregroundStyle(change == 0 ? Color.secondary : seriesColor(series.key))
            } else {
                Text("One reading in view").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func chartCard(_ history: FitnessMeasurementHistoryDTO) -> some View {
        let focusDate = focusedDate(history)
        let focusPoint = focusDate.flatMap { date in
            history.series.first.flatMap { nearestPoint(in: $0, to: date) }
        }
        let domain = yDomain(history)
        let pointSize = adaptivePointSize(visiblePointCount(history))
        let chartTint = seriesColor(history.series.first?.key ?? "weight")
        let renderedSeries = chartSeries(history)
        let xDomain = chartXDomain(history)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                chartReadout(history, at: focusDate)
                Spacer(minLength: 8)
                if !overview {
                    Button {
                        resetViewport()
                        HapticManager.selection()
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("Reset chart view")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)
            chartPresentationControls
            if viewModel.metric == .weight && viewModel.displayMode == .trend {
                HStack(spacing: 14) {
                    chartKey("Smoothed trend", color: chartTint, line: true)
                    chartKey("Actual weigh-ins", color: chartTint.opacity(0.5))
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            Chart {
                ForEach(renderedSeries) { rendered in
                    ForEach(rendered.linePoints) { point in
                        if let date = point.measuredAt {
                            LineMark(
                                x: .value("Date", date),
                                y: .value(
                                    rendered.source.label,
                                    point.value(for: viewModel.displayMode)
                                ),
                                series: .value("Series", rendered.source.key)
                            )
                            .foregroundStyle(seriesColor(rendered.source.key))
                            .lineStyle(
                                StrokeStyle(
                                    lineWidth: viewModel.displayMode == .trend ? 3.5 : 2.25,
                                    lineCap: .round, lineJoin: .round
                                )
                            )
                            .interpolationMethod(viewModel.displayMode == .trend ? .catmullRom : .linear)
                        }
                    }
                    if viewModel.displayMode == .raw
                        || (viewModel.metric == .weight && viewModel.displayMode == .trend)
                    {
                        ForEach(rendered.pointMarks) { point in
                            if let date = point.measuredAt {
                                PointMark(
                                    x: .value("Date", date),
                                    y: .value(rendered.source.label, point.rawValue)
                                )
                                .foregroundStyle(
                                    viewModel.metric == .weight && viewModel.displayMode == .trend
                                        ? seriesColor(rendered.source.key).opacity(0.5)
                                        : seriesColor(rendered.source.key)
                                )
                                .symbolSize(pointSize)
                            }
                        }
                    }
                }
                if let focusDate, selectedDate != nil {
                    RuleMark(x: .value("Selected date", focusDate))
                        .foregroundStyle(.secondary.opacity(0.65))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    if let focusPoint {
                        let focusValue =
                            viewModel.metric == .weight && viewModel.displayMode == .trend
                            ? focusPoint.rawValue : focusPoint.value(for: viewModel.displayMode)
                        RuleMark(y: .value("Selected value", focusValue))
                            .foregroundStyle(.secondary.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .annotation(position: .trailing, alignment: .center, spacing: 4) {
                                Text(format(focusValue))
                                    .font(.caption2.weight(.bold).monospacedDigit())
                                    .foregroundStyle(Color(.systemBackground))
                                    .padding(.horizontal, 5).padding(.vertical, 3)
                                    .background(chartTint, in: RoundedRectangle(cornerRadius: 4))
                            }
                        PointMark(
                            x: .value("Selected date halo", focusDate),
                            y: .value("Selected value halo", focusValue)
                        )
                        .foregroundStyle(chartTint.opacity(0.2))
                        .symbolSize(190)
                        PointMark(
                            x: .value("Selected date", focusDate),
                            y: .value("Selected value", focusValue)
                        )
                        .foregroundStyle(chartTint)
                        .symbolSize(82)
                    }
                }
            }
            .chartLegend(.hidden)
            .chartYScale(domain: domain)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 6)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Color.secondary.opacity(0.18))
                    AxisValueLabel().font(.caption2).foregroundStyle(.secondary)
                }
            }
            .chartXAxis {
                if viewModel.metric == .weight && viewModel.displayMode == .trend {
                    if visibleDays <= 14 {
                        AxisMarks(position: .top, values: .stride(by: .day, count: 2)) { _ in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                                .foregroundStyle(Color.secondary.opacity(0.14))
                            AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                                .font(.caption.weight(.semibold)).foregroundStyle(.primary)
                        }
                    } else {
                        AxisMarks(position: .top, values: .stride(by: .month)) { _ in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                                .foregroundStyle(Color.secondary.opacity(0.14))
                            AxisValueLabel(format: .dateTime.month(.abbreviated))
                                .font(.caption.weight(.semibold)).foregroundStyle(.primary)
                        }
                    }
                } else {
                    AxisMarks(values: .automatic(desiredCount: horizontalSizeClass == .regular ? 6 : 3)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(Color.secondary.opacity(0.1))
                        AxisValueLabel().font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .chartPlotStyle { plotArea in
                plotArea.background(Color(.systemBackground))
            }
            .chartScrollableAxes(.horizontal)
            .chartXScale(domain: xDomain)
            .chartXVisibleDomain(length: visibleDays * 86_400)
            .chartScrollPosition(x: $scrollPosition)
            .chartXSelection(value: $selectedDate)
            .frame(height: horizontalSizeClass == .regular ? (overview ? 460 : 500) : (overview ? 380 : 400))
            .padding(.leading, 4)
            .simultaneousGesture(
                MagnifyGesture(minimumScaleDelta: 0.01)
                    .onChanged { value in
                        updateChartMagnification(value, force: false)
                    }
                    .onEnded { value in
                        finishChartMagnification(value)
                    }
            )
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    chartGestureState.reset()
                    resetViewport()
                    HapticManager.selection()
                }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "\(history.title) \(viewModel.displayMode.title.localized.lowercased()) chart, "
                    + (overview ? "\(Int(visibleDays)) day range" : "\(yAxisScale.title.localized.lowercased()) vertical scale")
            )
            .accessibilityValue(chartAccessibility(history))
            .accessibilityHint(
                overview
                    ? "Pinch to zoom, drag to move through time, or use the graph options above"
                    : "Pinch to zoom, drag to move through time, or use the graph options above to change values and scale"
            )
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        }
    }

    private var chartPresentationControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Graph options")
                .font(.subheadline.weight(.semibold))

            VStack(alignment: .leading, spacing: 4) {
                Text("Values")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                displayModePicker
            }

            if !overview {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Vertical scale")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    yAxisScalePicker
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Time range")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 2) {
                    ForEach(availableRanges) { range in
                        Button(rangeButtonTitle(range)) { apply(range) }
                            .font(.caption.weight(.bold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(selectedRange == range ? metricTint : Color.secondary)
                            .background(
                                selectedRange == range ? metricTint.opacity(0.12) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .contentShape(Rectangle())
                            .accessibilityLabel(rangeAccessibilityTitle(range).localized)
                            .accessibilityHint("Changes the visible time range")
                            .accessibilityAddTraits(selectedRange == range ? .isSelected : [])
                    }
                }
                .padding(3)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 11))
                .accessibilityIdentifier("fitnessMeasurementTimeRange")
            }

            if !overview {
                HStack(spacing: 10) {
                    Button {
                        zoom(by: 1.8)
                    } label: {
                        Label("Zoom out", systemImage: "minus.magnifyingglass")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .disabled(visibleDays >= maximumVisibleDays - 0.01)
                    .accessibilityHint("Shows more time")

                    Button {
                        zoom(by: 0.55)
                    } label: {
                        Label("Zoom in", systemImage: "plus.magnifyingglass")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .disabled(visibleDays <= 7.01)
                    .accessibilityHint("Shows less time in more detail")
                }
                .accessibilityIdentifier("fitnessMeasurementZoomControls")
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var availableRanges: [FitnessMeasurementRange] {
        overview ? [.week, .month, .year] : FitnessMeasurementRange.allCases
    }

    private func rangeButtonTitle(_ range: FitnessMeasurementRange) -> String {
        guard overview else { return range.compactTitle }
        switch range {
        case .week: return "7 Days"
        case .month: return "1 Month"
        case .year: return "365 Days"
        case .threeMonths: return "90 Days"
        }
    }

    private func rangeAccessibilityTitle(_ range: FitnessMeasurementRange) -> String {
        overview ? rangeButtonTitle(range) : range.title
    }

    private func chartKey(_ title: String, color: Color, line: Bool = false) -> some View {
        HStack(spacing: 5) {
            if line {
                Capsule().fill(color).frame(width: 18, height: 3)
            } else {
                Circle().fill(color).frame(width: 8, height: 8)
            }
            Text(title)
        }
    }

    @ViewBuilder
    private func chartReadout(_ history: FitnessMeasurementHistoryDTO, at date: Date?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(readoutDateLabel(date))
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 20) {
                    chartReadoutValues(history, at: date)
                }
                VStack(alignment: .leading, spacing: 7) {
                    chartReadoutValues(history, at: date)
                }
            }
            Text("\(visiblePointCount(history).formatted()) in view · \(history.sampleCount.formatted()) total")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func chartReadoutValues(_ history: FitnessMeasurementHistoryDTO, at date: Date?) -> some View {
        ForEach(history.series) { series in
            if let point = displayPoint(in: series, at: date) {
                VStack(alignment: .leading, spacing: 2) {
                    if history.series.count > 1 {
                        HStack(spacing: 5) {
                            Circle().fill(seriesColor(series.key)).frame(width: 7, height: 7)
                            Text(series.label)
                        }
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(
                            format(
                                viewModel.metric == .weight && viewModel.displayMode == .trend
                                    ? point.rawValue : point.value(for: viewModel.displayMode)
                            )
                        )
                        .font(.title.weight(.bold).monospacedDigit())
                        .foregroundStyle(seriesColor(series.key))
                        Text(series.unit).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    if viewModel.metric == .weight && viewModel.displayMode == .trend {
                        Text("Smoothed \(format(point.trendValue)) \(series.unit)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func readoutDateLabel(_ date: Date?) -> String {
        guard let date else { return viewModel.metric.title }
        let prefix = selectedDate == nil ? "Latest · " : ""
        return prefix + date.formatted(date: .abbreviated, time: .omitted)
    }

    private func visiblePoints(
        in series: FitnessMeasurementHistorySeriesDTO
    ) -> [FitnessMeasurementHistoryPointDTO] {
        FitnessMeasurementChartRenderingPolicy.visiblePoints(
            from: series.points,
            viewportStart: scrollPosition,
            visibleDays: visibleDays
        )
    }

    private func displayPoint(
        in series: FitnessMeasurementHistorySeriesDTO, at date: Date?
    ) -> FitnessMeasurementHistoryPointDTO? {
        let candidates = visiblePoints(in: series)
        guard let date else { return candidates.last ?? series.points.last }
        return FitnessMeasurementChartRenderingPolicy.nearestPoint(
            in: candidates.isEmpty ? series.points : candidates,
            to: date
        )
    }

    private func focusedDate(_ history: FitnessMeasurementHistoryDTO) -> Date? {
        let visible = history.series.flatMap { visiblePoints(in: $0) }
        let visibleDates = visible.compactMap(\.measuredAt)
        guard let selectedDate else {
            return visibleDates.max() ?? dateBounds(history)?.last
        }
        let candidates = visible.isEmpty
            ? history.series.flatMap(\.points).compactMap(\.measuredAt)
            : visibleDates
        return candidates.min {
            abs($0.timeIntervalSince(selectedDate)) < abs($1.timeIntervalSince(selectedDate))
        }
    }

    private func visiblePointCount(_ history: FitnessMeasurementHistoryDTO) -> Int {
        history.series.map { visiblePoints(in: $0).count }.max() ?? 0
    }

    private func adaptivePointSize(_ visibleCount: Int) -> CGFloat {
        switch visibleCount {
        case 421...: 12
        case 181...: 22
        case 81...: 38
        default: 64
        }
    }

    private func selectionRow(_ history: FitnessMeasurementHistoryDTO, at date: Date) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { selectionValues(history, at: date) }
            VStack(alignment: .leading, spacing: 5) { selectionValues(history, at: date) }
        }
        .font(.subheadline.weight(.semibold).monospacedDigit())
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func selectionValues(_ history: FitnessMeasurementHistoryDTO, at date: Date) -> some View {
        ForEach(history.series) { series in
            if let point = nearestPoint(in: series, to: date) {
                HStack(spacing: 5) {
                    Circle().fill(seriesColor(series.key)).frame(width: 7, height: 7)
                    if viewModel.metric == .weight && viewModel.displayMode == .trend {
                        Text("Actual \(format(point.rawValue)) \(series.unit) · smoothed \(format(point.trendValue)) \(series.unit)")
                    } else {
                        Text("\(series.label): \(format(point.value(for: viewModel.displayMode))) \(series.unit)")
                    }
                }
            }
        }
    }

    private var summaryColumns: [GridItem] {
        let minimum: CGFloat = horizontalSizeClass == .regular ? 220 : 145
        return [GridItem(.adaptive(minimum: minimum), spacing: 10)]
    }

    private var metricTint: Color {
        switch viewModel.metric {
        case .weight: .indigo
        case .bodyFat: .teal
        case .bloodPressure: .red
        }
    }

    private func seriesColor(_ key: String) -> Color {
        switch key {
        case "systolic": .red
        case "diastolic": .blue
        case "body_fat": .teal
        default: .indigo
        }
    }

    private var withingsStatusText: String {
        guard let status = viewModel.withingsStatus else { return "Checking connection…" }
        if !status.configured {
            return "Server setup required"
        }
        switch status.status {
        case "connected": return status.webhookStatus == "active" ? "Connected · automatic updates" : "Connected · scheduled updates"
        case "reauth_required": return "Reconnect to resume updates"
        case "provider_down": return "Withings is temporarily unavailable"
        case "disconnected": return "Disconnected · history retained"
        default: return "Connect your scale and blood pressure monitor"
        }
    }

    private var withingsIcon: String {
        guard let status = viewModel.withingsStatus else { return "waveform.path.ecg" }
        if status.connected { return "checkmark.circle.fill" }
        if status.status == "provider_down" || status.status == "reauth_required" {
            return "exclamationmark.triangle.fill"
        }
        return "waveform.path.ecg"
    }

    private var withingsTint: Color {
        guard let status = viewModel.withingsStatus else { return .secondary }
        if status.connected { return .green }
        if status.status == "provider_down" || status.status == "reauth_required" { return .orange }
        return .blue
    }

    private func chartSeries(
        _ history: FitnessMeasurementHistoryDTO
    ) -> [FitnessMeasurementRenderedSeries] {
        history.series.map { series in
            FitnessMeasurementRenderedSeries(
                source: series,
                linePoints: FitnessMeasurementChartRenderingPolicy.linePoints(
                    from: series.points,
                    viewportStart: scrollPosition,
                    visibleDays: visibleDays
                ),
                pointMarks: FitnessMeasurementChartRenderingPolicy.pointMarks(
                    from: series.points,
                    viewportStart: scrollPosition,
                    visibleDays: visibleDays
                )
            )
        }
    }

    private func dateBounds(
        _ history: FitnessMeasurementHistoryDTO?
    ) -> (first: Date, last: Date)? {
        guard let history else { return nil }
        let firstDates = history.series.compactMap { $0.points.first?.measuredAt }
        let lastDates = history.series.compactMap { $0.points.last?.measuredAt }
        guard let first = firstDates.min(), let last = lastDates.max() else { return nil }
        return (first, last)
    }

    private func chartXDomain(_ history: FitnessMeasurementHistoryDTO) -> ClosedRange<Date> {
        let day = 86_400.0
        guard let bounds = dateBounds(history) else {
            let now = Date()
            return now.addingTimeInterval(-visibleDays * day)...now.addingTimeInterval(day)
        }
        let lower = bounds.first.addingTimeInterval(-day)
        let spanDays = max(7, ceil(bounds.last.timeIntervalSince(bounds.first) / day) + 2)
        let upper = max(
            bounds.last.addingTimeInterval(day),
            lower.addingTimeInterval(spanDays * day)
        )
        return lower...upper
    }

    private var maximumVisibleDays: Double {
        guard let bounds = dateBounds(displayedHistory) else { return 365 }
        return max(7, ceil(bounds.last.timeIntervalSince(bounds.first) / 86_400) + 2)
    }

    private var viewportCenter: Date {
        scrollPosition.addingTimeInterval(visibleDays * 86_400 / 2)
    }

    private func scrollStart(centeredOn center: Date, visibleDays: Double) -> Date {
        scrollStart(
            anchoredOn: center,
            anchorFraction: 0.5,
            visibleDays: visibleDays
        )
    }

    private func scrollStart(
        anchoredOn anchorDate: Date,
        anchorFraction: Double,
        visibleDays: Double
    ) -> Date {
        let fraction = min(max(anchorFraction, 0), 1)
        let proposed = anchorDate.addingTimeInterval(-visibleDays * 86_400 * fraction)
        guard let bounds = dateBounds(displayedHistory) else { return proposed }
        let earliest = bounds.first.addingTimeInterval(-86_400)
        let latest = bounds.last.addingTimeInterval(86_400 - visibleDays * 86_400)
        return min(max(proposed, earliest), max(earliest, latest))
    }

    private func updateChartMagnification(
        _ value: MagnifyGesture.Value,
        force: Bool
    ) {
        if chartGestureState.startingVisibleDays == nil {
            let anchorFraction = min(max(Double(value.startAnchor.x), 0), 1)
            chartGestureState.startingVisibleDays = visibleDays
            chartGestureState.anchorFraction = anchorFraction
            chartGestureState.anchorDate = scrollPosition.addingTimeInterval(
                visibleDays * 86_400 * anchorFraction
            )
        }
        guard let startingVisibleDays = chartGestureState.startingVisibleDays,
              let anchorFraction = chartGestureState.anchorFraction,
              let anchorDate = chartGestureState.anchorDate else { return }
        let now = value.time.timeIntervalSinceReferenceDate
        guard force || now - chartGestureState.lastAppliedAt >= 1.0 / 60.0 else {
            return
        }
        let nextDays = FitnessMeasurementChartRenderingPolicy.visibleDaysAfterPinch(
            startingVisibleDays: startingVisibleDays,
            magnification: Double(value.magnification),
            maximumVisibleDays: maximumVisibleDays
        )
        chartGestureState.lastAppliedAt = now
        guard abs(nextDays - visibleDays) > 0.01 else { return }
        selectedRange = nil
        selectedDate = nil
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            visibleDays = nextDays
            scrollPosition = scrollStart(
                anchoredOn: anchorDate,
                anchorFraction: anchorFraction,
                visibleDays: nextDays
            )
        }
        chartGestureState.didChange = true
    }

    private func finishChartMagnification(_ value: MagnifyGesture.Value) {
        updateChartMagnification(value, force: true)
        let changed = chartGestureState.didChange
        chartGestureState.reset()
        selectedDate = nil
        if changed { HapticManager.selection() }
    }

    private func zoom(by factor: Double) {
        let center = viewportCenter
        let nextDays = min(maximumVisibleDays, max(7, visibleDays * factor))
        guard abs(nextDays - visibleDays) > 0.01 else { return }
        selectedRange = nil
        selectedDate = nil
        visibleDays = nextDays
        scrollPosition = scrollStart(centeredOn: center, visibleDays: nextDays)
        HapticManager.selection()
    }

    private func apply(_ range: FitnessMeasurementRange) {
        selectedRange = range
        selectedDate = nil
        visibleDays = range.visibleDays.map { min(maximumVisibleDays, max(7, $0)) } ?? maximumVisibleDays
        alignViewportToLatest()
        HapticManager.selection()
    }

    private func resetViewport() {
        guard dateBounds(displayedHistory) != nil else { return }
        let range = selectedRange ?? (overview ? .month : .threeMonths)
        selectedRange = range
        visibleDays = range.visibleDays.map { min(maximumVisibleDays, max(7, $0)) } ?? maximumVisibleDays
        alignViewportToLatest()
        selectedDate = nil
    }

    private func alignViewportToLatest() {
        guard let bounds = dateBounds(displayedHistory) else { return }
        scrollPosition = bounds.last.addingTimeInterval(-(visibleDays * 86_400))
    }

    private func visibleChange(_ series: FitnessMeasurementHistorySeriesDTO) -> Double? {
        let visible = visiblePoints(in: series)
        guard let first = visible.first, let last = visible.last, first.id != last.id else {
            return nil
        }
        return last.value(for: viewModel.displayMode) - first.value(for: viewModel.displayMode)
    }

    private func nearestPoint(
        in series: FitnessMeasurementHistorySeriesDTO, to date: Date
    ) -> FitnessMeasurementHistoryPointDTO? {
        FitnessMeasurementChartRenderingPolicy.nearestPoint(in: series.points, to: date)
    }

    private func yDomain(_ history: FitnessMeasurementHistoryDTO) -> ClosedRange<Double> {
        let domainStart = Calendar.autoupdatingCurrent.startOfDay(for: scrollPosition)
        let visible = history.series.flatMap {
            FitnessMeasurementChartRenderingPolicy.visiblePoints(
                from: $0.points,
                viewportStart: domainStart,
                visibleDays: visibleDays
            )
        }
        let source = visible.isEmpty ? history.series.flatMap(\.points) : visible
        let values = source.flatMap { point -> [Double] in
            if viewModel.metric == .weight && viewModel.displayMode == .trend {
                return [point.rawValue, point.trendValue]
            }
            return [point.value(for: viewModel.displayMode)]
        }
        return FitnessMeasurementChartDomainPolicy.domain(
            values: values,
            metric: history.metric,
            scale: yAxisScale
        )
    }

    private func format(_ value: Double) -> String {
        String(format: viewModel.metric == .bloodPressure ? "%.0f" : "%.1f", value)
    }

    private func chartExplanation(_ history: FitnessMeasurementHistoryDTO) -> String {
        if viewModel.displayMode == .raw {
            return "Raw shows each recorded value without changing it."
        }
        if viewModel.metric == .weight {
            return
                "The indigo line is the smoothed \(history.smoothingHalfLifeDays.formatted())-day trend. Dots are actual weigh-ins; tap the graph for an exact reading."
        }
        return
            "Smoothed reduces day-to-day noise using a time-aware exponential average with a \(history.smoothingHalfLifeDays.formatted())-day half-life."
    }

    private func chartAccessibility(_ history: FitnessMeasurementHistoryDTO) -> String {
        let latest = history.series.compactMap { series -> String? in
            guard let point = series.points.last else { return nil }
            return "\(series.label) \(format(point.value(for: viewModel.displayMode))) \(series.unit)"
        }
        return "\(history.sampleCount) readings. " + latest.joined(separator: ", ")
    }
}
