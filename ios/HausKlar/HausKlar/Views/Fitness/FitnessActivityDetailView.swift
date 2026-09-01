import Charts
import SwiftUI

struct FitnessActivityDetailView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var viewModel: FitnessActivityDetailViewModel
    @State private var showingContext = false
    @State private var showingActivityInfo = false
    @State private var selectedStreamMetric: String?
    @State private var selectedIntervalGroup = "source_lap"

    init(activityId: String) {
        _viewModel = StateObject(wrappedValue: FitnessActivityDetailViewModel(activityId: activityId))
    }

    var body: some View {
        Group {
            if let detail = viewModel.detail {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if !isRun(detail) {
                            activityIdentity(detail)
                        }
                        askCoachAction(detail)
                        ForEach(FitnessActivityPresentationPolicy.primarySections) { section in
                            primarySection(section, detail: detail)
                        }
                    }
                    .padding()
                }
                .accessibilityIdentifier("fitnessActivityDetail")
                .background(Color(.systemGroupedBackground))
            } else if viewModel.isLoading {
                ProgressView("Loading activity…")
            } else {
                ContentUnavailableView {
                    Label("Activity unavailable", systemImage: "figure.run")
                } description: {
                    Text("The activity couldn’t be opened. Try again.")
                } actions: {
                    Button("Try again", systemImage: "arrow.clockwise") {
                        Task { await viewModel.load(refresh: true) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle(viewModel.detail?.activity.title ?? "Activity")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button("Edit activity", systemImage: "square.and.pencil") { showingContext = true }
                    Button("Activity information", systemImage: "info.circle") {
                        showingActivityInfo = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .accessibilityLabel("More activity actions")
                .accessibilityIdentifier("fitnessActivityMoreActions")
                .disabled(viewModel.detail == nil || viewModel.isLoading)
            }
        }
        .sheet(isPresented: $showingContext) {
            if let detail = viewModel.detail {
                FitnessActivityContextSheet(viewModel: viewModel, detail: detail)
            }
        }
        .sheet(isPresented: $showingActivityInfo) {
            if let detail = viewModel.detail {
                FitnessActivityInformationSheet(viewModel: viewModel, detail: detail)
            }
        }
        .task { await viewModel.load() }
        .refreshable { await viewModel.load(refresh: true) }
    }

    private func isRun(_ detail: FitnessActivityDetail) -> Bool {
        FitnessActivityPresentationPolicy.isRun(detail.activity.sportKey)
    }

    private func askCoachAction(_ detail: FitnessActivityDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                let staged = appState.stageFitnessCoachDraft(
                    FitnessActivityCoachHandoff.prompt(title: detail.activity.title),
                    contextIds: [detail.activity.id]
                )
                guard staged != nil else { return }
                HapticManager.selection()
                appState.openFitness(destination: .coach)
            } label: {
                Label(
                    "Ask Coach about this activity",
                    systemImage: "bubble.left.and.text.bubble.right.fill"
                )
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint(
                "Opens an editable Coach message with this activity and nearby training as context."
            )
            Text("Coach will consider this activity alongside the sessions around it. You review the message before sending.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("fitnessActivityAskCoach")
    }

    private func activityIdentity(_ detail: FitnessActivityDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(FitnessDisplay.date(detail.activity.startedAtUtc), systemImage: "calendar")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    activityType(detail)
                }
                VStack(alignment: .leading, spacing: 6) {
                    activityType(detail)
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func activityType(_ detail: FitnessActivityDetail) -> some View {
        Label(
            FitnessDisplay.humanKey(detail.activity.sportKey),
            systemImage: FitnessDisplay.sportIcon(detail.activity.sportKey)
        )
        if let classification = detail.activity.workoutClassification {
            Text(classification.replacingOccurrences(of: "_", with: " ").capitalized)
        }
    }

    private func headlineMetrics(_ detail: FitnessActivityDetail) -> some View {
        let stats = primaryStats(detail)
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Activity summary").font(.headline)
                if isRun(detail) {
                    Text(
                        "\(FitnessDisplay.date(detail.activity.startedAtUtc)) · "
                            + FitnessDisplay.humanKey(detail.activity.sportKey)
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            if isRun(detail) {
                LazyVGrid(columns: primaryStatColumns, alignment: .leading, spacing: 14) {
                    ForEach(Array(stats.prefix(3))) { stat in
                        primaryStat(stat, prominent: true)
                    }
                }
                if stats.count > 3 {
                    Divider()
                    LazyVGrid(columns: primaryStatColumns, alignment: .leading, spacing: 14) {
                        ForEach(Array(stats.dropFirst(3))) { stat in
                            primaryStat(stat, prominent: false)
                        }
                    }
                }
            } else {
                LazyVGrid(columns: primaryStatColumns, alignment: .leading, spacing: 14) {
                    ForEach(stats) { stat in
                        primaryStat(stat, prominent: false)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fitnessActivityHeadlineMetrics")
    }

    private func primaryStat(
        _ stat: FitnessActivityPrimaryStat,
        prominent: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(stat.label).font(.caption2).foregroundStyle(.secondary)
            Text(stat.value)
                .font(prominent ? .title3.weight(.bold) : .headline)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            if let detail = stat.detail {
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(stat.label)
        .accessibilityValue(
            [stat.value, stat.detail].compactMap { $0 }.joined(separator: ", ")
        )
    }

    @ViewBuilder
    private func primarySection(
        _ section: FitnessActivityPrimarySection,
        detail: FitnessActivityDetail
    ) -> some View {
        switch section {
        case .route: route(detail)
        case .headlineMetrics: headlineMetrics(detail)
        case .splits: intervals(detail)
        case .charts: streams(detail)
        case .moreStats: metrics(detail)
        case .context: context(detail)
        case .insights: findings(detail)
        }
    }

    private func primaryStats(_ detail: FitnessActivityDetail) -> [FitnessActivityPrimaryStat] {
        let duration = detail.activity.movingDurationS ?? detail.activity.timerDurationS ?? detail.activity.durationS
        let recordedSpeed = summaryNumber(detail, key: "speed.average_mps")
        let averageSpeed =
            recordedSpeed
            ?? {
                guard let distance = detail.activity.distanceM, let duration, distance > 0, duration > 0 else { return nil }
                return distance / duration
            }()
        let averageHeartRate = summaryNumber(detail, key: "heart_rate.average_bpm")
        let elevationGain = summaryNumber(detail, key: "elevation.gain_m")
        let averagePace = FitnessDisplay.averagePaceSecondsPerKilometre(
            summaryMetrics: detail.summaryMetrics,
            distanceMetres: detail.activity.distanceM,
            durationSeconds: duration
        )
        let stats: [FitnessActivityPrimaryStat] = [
            .init(label: "Distance", value: detail.activity.distanceM.map(FitnessDisplay.distance) ?? "—"),
            .init(
                label: detail.activity.movingDurationS == nil ? "Timer time" : "Moving time",
                value: duration.map(FitnessDisplay.duration) ?? "—",
                detail: detail.activity.elapsedDurationS.map { "\(FitnessDisplay.duration($0)) elapsed" }),
            .init(
                label: detail.activity.sportKey.contains("run") ? "Average pace" : "Average speed",
                value: detail.activity.sportKey.contains("run")
                    ? FitnessDisplay.streamValue(averagePace, metric: "pace_s_per_km", unit: "s/km")
                    : FitnessDisplay.streamValue(averageSpeed, metric: "speed_mps", unit: "m/s")),
            .init(label: "Average heart rate", value: averageHeartRate.map { "\(Int($0.rounded())) bpm" } ?? "—"),
            .init(label: "Elevation gain", value: elevationGain.map { "\(Int($0.rounded())) m" } ?? "—"),
            .init(
                label: "Energy",
                value: detail.activity.energyKcal.map {
                    "\(detail.activity.energyEstimationMethod == nil ? "" : "≈ ")\(Int($0.rounded())) kcal"
                } ?? "—",
                detail: detail.activity.energyEstimationWeightKg.map {
                    "Estimated from \(String(format:"%.1f",$0)) kg"
                }
            ),
        ]
        return isRun(detail) ? stats.filter { $0.value != "—" } : stats
    }

    private func summaryNumber(_ detail: FitnessActivityDetail, key: String) -> Double? {
        detail.summaryMetrics.first { $0.metricKey == key }?.valueNumber
    }

    @ViewBuilder
    private func route(_ detail: FitnessActivityDetail) -> some View {
        let samples = routeSamples(detail)
        if samples.count > 1 {
            FitnessLocalRouteView(
                samples: samples,
                selectedOffsetMs: $viewModel.selectedOffsetMs
            )
        } else if isRun(detail) {
            VStack(alignment: .leading, spacing: 5) {
                Label("No route recorded", systemImage: "map")
                    .font(.headline)
                Text("This run has no recorded route.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
            .padding()
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 16)
            )
            .accessibilityIdentifier("fitnessActivityRouteUnavailable")
        }
    }

    private func routeSamples(_ detail: FitnessActivityDetail) -> [FitnessLocalRouteSample] {
        let routeStream = viewModel.routeStream ?? viewModel.stream
        if let latitudes = routeStream?.series["latitude_deg"],
            let longitudes = routeStream?.series["longitude_deg"]
        {
            let count = min(latitudes.count, longitudes.count)
            let indices = FitnessActivityPresentationPolicy.routeSampleIndices(
                count: count, maximum: 2_000
            )
            let recorded = indices.compactMap { index -> FitnessLocalRouteSample? in
                guard let latitude = latitudes[index], let longitude = longitudes[index] else { return nil }
                let offset =
                    routeStream?.offsetMs.indices.contains(index) == true
                    ? routeStream?.offsetMs[index] : nil
                return FitnessLocalRouteSample(
                    latitude: latitude, longitude: longitude, offsetMs: offset
                )
            }
            if recorded.count > 1 { return recorded }
        }
        let coordinates = detail.activity.routeCoordinates
        let chartOffsets = viewModel.stream?.offsetMs ?? []
        return coordinates.enumerated().compactMap { index, coordinate in
            let offset: Int?
            if let first = chartOffsets.first, let last = chartOffsets.last, coordinates.count > 1 {
                let fraction = Double(index) / Double(coordinates.count - 1)
                offset = first + Int((Double(last - first) * fraction).rounded())
            } else {
                offset = nil
            }
            return FitnessLocalRouteSample(coordinate: coordinate, offsetMs: offset)
        }
    }

    @ViewBuilder
    private func metrics(_ detail: FitnessActivityDetail) -> some View {
        if !detail.summaryMetrics.isEmpty {
            DisclosureGroup("More stats") {
                LazyVGrid(columns: detailMetricColumns, spacing: 10) {
                    ForEach(Array(detail.summaryMetrics.enumerated()), id: \.offset) { _, metric in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(metric.label ?? FitnessDisplay.summaryMetricTitle(metric.metricKey))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(FitnessDisplay.summaryMetricValue(metric))
                                .font(.headline).monospacedDigit()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(
                            Color(.systemBackground),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.top, 10)
            }
            .padding()
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 16)
            )
        }
    }

    private var primaryStatColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 10), count: dynamicTypeSize.isAccessibilitySize ? 1 : 3)
    }

    private var detailMetricColumns: [GridItem] {
        Array(repeating: GridItem(.flexible()), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
    }

    @ViewBuilder
    private func streams(_ detail: FitnessActivityDetail) -> some View {
        if let stream = viewModel.stream,
            !stream.offsetMs.isEmpty,
            !recordedChartMetrics(stream).isEmpty
        {
            let metrics = recordedChartMetrics(stream)
            let activeMetric = selectedStreamMetric.flatMap { metrics.contains($0) ? $0 : nil } ?? metrics.first
            let runCharts = FitnessActivityPresentationPolicy.runChartGroups(metrics)
            VStack(alignment: .leading, spacing: 14) {
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 10) {
                            chartHeading
                            clockPicker
                        }
                    } else {
                        HStack {
                            chartHeading
                            Spacer()
                            clockPicker.frame(maxWidth: 180)
                        }
                    }
                }
                if isRun(detail) {
                    ForEach(runCharts.primary, id: \.self) { metric in
                        FitnessMetricChart(
                            metric: metric, stream: stream,
                            selectedOffsetMs: $viewModel.selectedOffsetMs
                        )
                    }
                    if !runCharts.additional.isEmpty {
                        DisclosureGroup("More graphs") {
                            VStack(spacing: 12) {
                                ForEach(runCharts.additional, id: \.self) { metric in
                                    FitnessMetricChart(
                                        metric: metric, stream: stream,
                                        selectedOffsetMs: $viewModel.selectedOffsetMs
                                    )
                                }
                            }
                            .padding(.top, 10)
                        }
                    }
                } else if !metrics.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(metrics, id: \.self) { metric in
                                Button {
                                    selectedStreamMetric = metric
                                    HapticManager.selection()
                                } label: {
                                    Text(FitnessDisplay.metric(metric))
                                        .font(.subheadline.weight(.semibold))
                                        .padding(.horizontal, 12).frame(minHeight: 44)
                                        .background(activeMetric == metric ? Color.accentColor : Color(.tertiarySystemFill), in: Capsule())
                                        .foregroundStyle(activeMetric == metric ? Color.white : Color.primary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(activeMetric == metric ? .isSelected : [])
                            }
                        }
                    }
                    if let activeMetric {
                        FitnessMetricChart(
                            metric: activeMetric, stream: stream,
                            selectedOffsetMs: $viewModel.selectedOffsetMs
                        )
                    }
                }
                if isRun(detail) {
                    DisclosureGroup("Reading at selected point") {
                        selectedPoint(stream: stream, metrics: metrics)
                            .padding(.top, 10)
                    }
                } else {
                    selectedPoint(stream: stream, metrics: metrics)
                }
                let totalOffset = Int(
                    ((viewModel.selectedClock == "timer" ? detail.activity.timerDurationS : detail.activity.elapsedDurationS) ?? detail
                        .activity.durationS ?? 0) * 1_000)
                VStack(alignment: .leading, spacing: 8) {
                    Label("Inspect a closer range", systemImage: "selection.pin.in.out")
                        .font(.subheadline.weight(.semibold))
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { rangeButtons(totalOffset: totalOffset) }
                        VStack(alignment: .leading, spacing: 8) { rangeButtons(totalOffset: totalOffset) }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            .accessibilityIdentifier("fitnessActivityCharts")
        } else if viewModel.isLoadingStream || !viewModel.didAttemptStreamLoad {
            ProgressView("Preparing charts…")
                .frame(maxWidth: .infinity, minHeight: 180)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        } else if isRun(detail) {
            VStack(alignment: .leading, spacing: 5) {
                Label("No graphs recorded", systemImage: "chart.xyaxis.line")
                    .font(.headline)
                Text("This run has no recorded pace, heart-rate or elevation stream.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
            .padding()
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 16)
            )
            .accessibilityIdentifier("fitnessActivityChartsUnavailable")
        }
    }

    private func recordedChartMetrics(_ stream: FitnessActivityStream) -> [String] {
        FitnessDisplay.orderedStreamMetrics(Array(stream.series.keys)).filter { metric in
            stream.series[metric]?.contains { $0?.isFinite == true } == true
        }
    }

    private var chartHeading: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Performance graphs").font(.headline)
            Text("Laps, graphs and route share the same selected position.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var clockPicker: some View {
        Picker(
            "Time",
            selection: Binding(
                get: { viewModel.selectedClock },
                set: { value in Task { await viewModel.changeClock(value) } }
            )
        ) {
            Text("Moving").tag("timer")
            Text("Elapsed").tag("elapsed")
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder private func rangeButtons(totalOffset: Int) -> some View {
        Button("Overview") { Task { await viewModel.loadOverview() } }
            .frame(minHeight: 44)
        Button("First half") {
            Task { await viewModel.loadRange(fromOffsetMs: 0, toOffsetMs: totalOffset / 2) }
        }
        .frame(minHeight: 44)
        Button("Second half") {
            Task {
                await viewModel.loadRange(
                    fromOffsetMs: totalOffset / 2, toOffsetMs: totalOffset
                )
            }
        }
        .frame(minHeight: 44)
    }

    private func selectedPoint(stream: FitnessActivityStream, metrics: [String]) -> some View {
        let index = selectedStreamIndex(stream)
        let offset = index.flatMap { stream.offsetMs.indices.contains($0) ? stream.offsetMs[$0] : nil }
        let distance = selectedDistance(stream, index: index)
        return VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    selectedPositionTitle
                    Spacer()
                    selectedPositionValue(offset: offset, distance: distance)
                }
                VStack(alignment: .leading, spacing: 6) {
                    selectedPositionTitle
                    selectedPositionValue(offset: offset, distance: distance)
                }
            }
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible()),
                    count: dynamicTypeSize.isAccessibilitySize ? 1 : 2
                ),
                spacing: 8
            ) {
                ForEach(metrics, id: \.self) { metric in
                    let value = selectedMetricValue(stream, metric: metric, index: index)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(FitnessDisplay.metric(metric)).font(.caption2).foregroundStyle(.secondary)
                        Text(FitnessDisplay.streamValue(value, metric: metric, unit: stream.units[metric]))
                            .font(.subheadline.weight(.semibold)).monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .padding(12)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var selectedPositionTitle: some View {
        Label("Selected position", systemImage: "scope")
            .font(.subheadline.weight(.semibold))
    }

    private func selectedPositionValue(offset: Int?, distance: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(offset.map { FitnessDisplay.duration(Double($0) / 1_000) } ?? "—")
                .font(.title3.weight(.bold)).monospacedDigit()
            if let distance {
                Text(FitnessDisplay.distance(distance))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func selectedDistance(_ stream: FitnessActivityStream, index: Int?) -> Double? {
        guard let index, let values = stream.distanceM, values.indices.contains(index) else { return nil }
        return values[index]
    }

    private func selectedMetricValue(
        _ stream: FitnessActivityStream, metric: String, index: Int?
    ) -> Double? {
        guard let index, let values = stream.series[metric], values.indices.contains(index) else { return nil }
        return values[index]
    }

    private func selectedStreamIndex(_ stream: FitnessActivityStream) -> Int? {
        guard !stream.offsetMs.isEmpty else { return nil }
        guard let selected = viewModel.selectedOffsetMs else { return 0 }
        return stream.offsetMs.indices.min { abs(stream.offsetMs[$0] - selected) < abs(stream.offsetMs[$1] - selected) }
    }

    @ViewBuilder
    private func intervals(_ detail: FitnessActivityDetail) -> some View {
        let groups = intervalGroups(detail.intervals)
        if let active = groups.first(where: { $0.id == selectedIntervalGroup }) ?? groups.first {
            let paces = active.rows.compactMap(intervalPace)
            let fastest = paces.min()
            let slowest = paces.max()
            let compactRunSplits = isRun(detail) && !dynamicTypeSize.isAccessibilitySize
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(active.id == "source_lap" ? "Recorded laps" : "Splits")
                        .font(.headline)
                    Text("Tap a row to line up the route and graphs.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(groups) { group in
                            Button {
                                selectedIntervalGroup = group.id
                                HapticManager.selection()
                            } label: {
                                HStack(spacing: 6) {
                                    Text(group.label)
                                    Text("\(group.rows.count)")
                                        .font(.caption2.weight(.bold)).monospacedDigit()
                                        .padding(.horizontal, 6).padding(.vertical, 3)
                                        .background(Color(.systemBackground).opacity(0.8), in: Capsule())
                                }
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 12).frame(minHeight: 44)
                                .background(
                                    active.id == group.id ? Color.accentColor.opacity(0.16) : Color(.tertiarySystemFill), in: Capsule()
                                )
                                .foregroundStyle(active.id == group.id ? Color.accentColor : Color.primary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(active.id == group.id ? .isSelected : [])
                        }
                    }
                }
                if !dynamicTypeSize.isAccessibilitySize {
                    if compactRunSplits {
                        runSplitColumnHeadings(groupID: active.id)
                    } else {
                        intervalColumnHeadings(first: active.id == "source_lap" ? "Lap" : "Split")
                    }
                }
                VStack(spacing: compactRunSplits ? 0 : 8) {
                    ForEach(Array(active.rows.enumerated()), id: \.element.id) { index, interval in
                        let pace = intervalPace(interval)
                        let elevation = FitnessActivityIntervalPresentation.elevation(interval)
                        let heartRate = FitnessActivityIntervalPresentation.averageHeartRate(interval)
                        let maximumHeartRate = FitnessActivityIntervalPresentation.maximumHeartRate(interval)
                        let power = FitnessActivityIntervalPresentation.averagePower(interval)
                        let elapsedDuration = intervalElapsedDuration(interval)
                        let timerDuration = intervalTimerDuration(interval)
                        Button {
                            viewModel.selectedOffsetMs = interval.startOffsetMs
                            HapticManager.selection()
                        } label: {
                            if compactRunSplits {
                                compactRunSplitRow(
                                    position: index + 1,
                                    pace: pace,
                                    elevation: elevation,
                                    heartRate: heartRate,
                                    power: power,
                                    fastest: fastest,
                                    slowest: slowest,
                                    selected: viewModel.selectedOffsetMs == interval.startOffsetMs
                                )
                            } else {
                                detailedIntervalRow(
                                    interval,
                                    pace: pace,
                                    heartRate: heartRate,
                                    maximumHeartRate: maximumHeartRate,
                                    power: power,
                                    elapsedDuration: elapsedDuration,
                                    timerDuration: timerDuration,
                                    fastest: fastest,
                                    slowest: slowest,
                                    selected: viewModel.selectedOffsetMs == interval.startOffsetMs
                                )
                            }
                        }
                        .buttonStyle(.plain)
                        .frame(minHeight: 44)
                        .accessibilityLabel(interval.label ?? "Section \(interval.sequence + 1)")
                        .accessibilityValue(
                            intervalAccessibilityValue(
                                interval,
                                pace: pace,
                                elevation: elevation,
                                heartRate: heartRate,
                                maximumHeartRate: maximumHeartRate,
                                power: power
                            )
                        )
                        .accessibilityHint("Moves the activity graphs and route marker to this section")
                        .accessibilityAddTraits(
                            viewModel.selectedOffsetMs == interval.startOffsetMs ? .isSelected : []
                        )
                    }
                }
            }
            .padding()
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16))
            .accessibilityIdentifier("fitnessActivitySplits")
        } else if isRun(detail) {
            VStack(alignment: .leading, spacing: 5) {
                Label("No laps recorded", systemImage: "list.number")
                    .font(.headline)
                Text("This run has no recorded laps or distance splits.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
            .padding()
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16))
            .accessibilityIdentifier("fitnessActivityLapsUnavailable")
        }
    }

    private func intervalColumnHeadings(first: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(first).frame(maxWidth: .infinity, alignment: .leading)
            Text("Time").frame(width: 68, alignment: .trailing)
            Text("Pace").frame(width: 70, alignment: .trailing)
            Text("Avg HR").frame(width: 62, alignment: .trailing)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .accessibilityHidden(true)
    }

    private func runSplitColumnHeadings(groupID: String) -> some View {
        let first =
            switch groupID {
            case "kilometre": "Km"
            case "mile": "Mi"
            case "source_lap": "Lap"
            default: "Step"
            }
        return VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(first).frame(width: 32, alignment: .leading)
                Text("Pace").frame(maxWidth: .infinity, alignment: .leading)
                Text("Elev").frame(width: 38, alignment: .trailing)
                Text("HR").frame(width: 34, alignment: .trailing)
                Text("W").frame(width: 42, alignment: .trailing)
            }
            Divider()
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .accessibilityHidden(true)
    }

    private func compactRunSplitRow(
        position: Int,
        pace: Double?,
        elevation: Double?,
        heartRate: Double?,
        power: Double?,
        fastest: Double?,
        slowest: Double?,
        selected: Bool
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Text("\(position)")
                    .frame(width: 32, alignment: .leading)
                HStack(spacing: 7) {
                    Text(pace.map(FitnessDisplay.duration) ?? "—")
                        .frame(width: 46, alignment: .leading)
                    GeometryReader { proxy in
                        if pace != nil {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.accentColor)
                                .frame(
                                    width: max(
                                        4,
                                        proxy.size.width
                                            * paceBarFraction(
                                                pace, fastest: fastest, slowest: slowest
                                            )
                                    )
                                )
                        }
                    }
                    .frame(height: 18)
                    .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(elevation.map { "\(Int($0.rounded()))" } ?? "—")
                    .frame(width: 38, alignment: .trailing)
                Text(heartRate.map { "\(Int($0.rounded()))" } ?? "—")
                    .frame(width: 34, alignment: .trailing)
                Text(power.map { "\(Int($0.rounded()))" } ?? "—")
                    .frame(width: 42, alignment: .trailing)
            }
            .font(.subheadline)
            .fontWeight(.medium)
            .monospacedDigit()
            .padding(.horizontal, 4)
            .padding(.vertical, 7)
            Divider()
        }
        .background(selected ? Color.accentColor.opacity(0.09) : Color.clear)
        .contentShape(Rectangle())
    }

    private func detailedIntervalRow(
        _ interval: FitnessActivityInterval,
        pace: Double?,
        heartRate: Double?,
        maximumHeartRate: Double?,
        power: Double?,
        elapsedDuration: Double,
        timerDuration: Double,
        fastest: Double?,
        slowest: Double?,
        selected: Bool
    ) -> some View {
        let movingTime =
            abs(elapsedDuration - timerDuration) >= 1
            ? "\(FitnessDisplay.duration(timerDuration)) moving" : nil
        return VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    intervalIdentity(interval)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    intervalValue(
                        FitnessDisplay.duration(elapsedDuration),
                        label: "Elapsed time",
                        detail: movingTime
                    )
                    .frame(width: 68, alignment: .trailing)
                    intervalValue(
                        pace.map {
                            FitnessDisplay.streamValue(
                                $0, metric: "pace_s_per_km", unit: "s/km"
                            )
                        } ?? "—",
                        label: "Pace"
                    )
                    .frame(width: 70, alignment: .trailing)
                    intervalValue(
                        heartRate.map { "\(Int($0.rounded())) bpm" } ?? "—",
                        label: "Average heart rate",
                        detail: maximumHeartRate.map {
                            "\(Int($0.rounded())) max"
                        }
                    )
                    .frame(width: 62, alignment: .trailing)
                }
                VStack(alignment: .leading, spacing: 10) {
                    intervalIdentity(interval)
                    LazyVGrid(
                        columns: [GridItem(.flexible()), GridItem(.flexible())],
                        alignment: .leading,
                        spacing: 8
                    ) {
                        intervalValue(
                            FitnessDisplay.duration(elapsedDuration),
                            label: "Elapsed time",
                            detail: movingTime
                        )
                        intervalValue(
                            pace.map {
                                FitnessDisplay.streamValue(
                                    $0, metric: "pace_s_per_km", unit: "s/km"
                                )
                            } ?? "—",
                            label: "Pace"
                        )
                        intervalValue(
                            heartRate.map { "\(Int($0.rounded())) bpm" } ?? "—",
                            label: "Average heart rate",
                            detail: maximumHeartRate.map {
                                "\(Int($0.rounded())) max"
                            }
                        )
                        if let power {
                            intervalValue(
                                "\(Int(power.rounded())) W", label: "Average power"
                            )
                        }
                    }
                }
            }
            if pace != nil {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(.tertiarySystemFill))
                        Capsule().fill(Color.accentColor.opacity(0.38))
                            .frame(
                                width: proxy.size.width
                                    * paceBarFraction(
                                        pace, fastest: fastest, slowest: slowest
                                    )
                            )
                    }
                }
                .frame(height: 5)
                .accessibilityHidden(true)
            }
            if let power, !dynamicTypeSize.isAccessibilitySize {
                Label("\(Int(power.rounded())) W average power", systemImage: "bolt.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 1.5)
        }
        .contentShape(Rectangle())
    }

    private func intervalValue(
        _ value: String,
        label: String,
        detail: String? = nil
    ) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            if dynamicTypeSize.isAccessibilitySize {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue([value, detail].compactMap { $0 }.joined(separator: ", "))
    }

    private func intervalIdentity(_ interval: FitnessActivityInterval) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(interval.label ?? "#\(interval.sequence + 1)")
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            if let distance = intervalDistance(interval) {
                Text(FitnessDisplay.distance(distance))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func intervalGroups(_ intervals: [FitnessActivityInterval]) -> [FitnessActivityIntervalGroup] {
        let definitions: [String: (label: String, kinds: Set<String>)] = [
            "source_lap": ("Laps", Set(["source_lap"])),
            "kilometre": ("Kilometres", Set(["kilometre_split"])),
            "mile": ("Miles", Set(["mile_split"])),
            "interval": (
                "Workout",
                Set([
                    "work_interval", "recovery_interval", "warmup", "cooldown",
                    "plan_step", "planned_step",
                ])
            ),
        ]
        return FitnessActivityPresentationPolicy.intervalGroupOrder.compactMap { id in
            guard let definition = definitions[id] else { return nil }
            let label = definition.label
            let kinds = definition.kinds
            let rows = intervals.filter { kinds.contains($0.intervalKind) }
            return rows.isEmpty ? nil : FitnessActivityIntervalGroup(id: id, label: label, rows: rows)
        }
    }

    private func intervalDistance(_ interval: FitnessActivityInterval) -> Double? {
        FitnessActivityIntervalPresentation.distance(interval)
    }

    private func intervalPace(_ interval: FitnessActivityInterval) -> Double? {
        FitnessActivityIntervalPresentation.pace(interval)
    }

    private func intervalElapsedDuration(_ interval: FitnessActivityInterval) -> Double {
        FitnessActivityIntervalPresentation.elapsedDuration(interval)
    }

    private func intervalTimerDuration(_ interval: FitnessActivityInterval) -> Double {
        FitnessActivityIntervalPresentation.timerDuration(interval)
    }

    private func intervalDetail(_ interval: FitnessActivityInterval) -> String {
        let elapsed = intervalElapsedDuration(interval)
        let timer = intervalTimerDuration(interval)
        let distance = intervalDistance(interval).map(FitnessDisplay.distance)
        var values = [distance, "\(FitnessDisplay.duration(elapsed)) elapsed"].compactMap { $0 }
        if abs(elapsed - timer) >= 1 {
            values.append("\(FitnessDisplay.duration(timer)) moving")
        }
        return values.joined(separator: " · ")
    }

    private func intervalAccessibilityValue(
        _ interval: FitnessActivityInterval,
        pace: Double?,
        elevation: Double?,
        heartRate: Double?,
        maximumHeartRate: Double?,
        power: Double?
    ) -> String {
        [
            intervalDetail(interval),
            pace.map {
                "Pace \(FitnessDisplay.streamValue($0,metric:"pace_s_per_km",unit:"s/km"))"
            },
            elevation.map { "Elevation change \(Int($0.rounded())) metres" },
            heartRate.map {
                let maximum =
                    maximumHeartRate.map {
                        ", maximum \(Int($0.rounded()))"
                    } ?? ""
                return "Average heart rate \(Int($0.rounded()))\(maximum) beats per minute"
            },
            power.map { "Average power \(Int($0.rounded())) watts" },
        ].compactMap { $0 }.joined(separator: ", ")
    }

    private func paceBarFraction(_ pace: Double?, fastest: Double?, slowest: Double?) -> Double {
        guard let pace, let fastest, let slowest else { return 0 }
        guard slowest > fastest else { return 0.76 }
        return 0.36 + (slowest - pace) / (slowest - fastest) * 0.6
    }

    private func context(_ detail: FitnessActivityDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Session notes").font(.headline)
            if let notes = detail.notes, !notes.isEmpty { Label(notes, systemImage: "note.text") }
            if let rpe = detail.sessionRpe {
                Label("Session effort \(rpe.formatted())/10", systemImage: "gauge.with.dots.needle.50percent")
            }
            if let planned = detail.plannedSession { Label("Plan: \(planned.title)", systemImage: "calendar.badge.checkmark") }
            ForEach(detail.gear ?? []) { item in Label(item.name, systemImage: "shoe.2") }
            ForEach(detail.goalLinks ?? []) { link in
                Label(goalName(link.goalId), systemImage: link.role == "planned" ? "target" : "scope")
            }
            ForEach(detail.checkins ?? []) { checkin in
                let value = checkin.readiness15.map(String.init) ?? "not recorded"
                Label("\(FitnessDisplay.humanKey(checkin.timing)) readiness: \(value)", systemImage: "heart.text.square")
            }
            ForEach(detail.bodyIssues ?? []) { issue in
                Label("\(FitnessDisplay.humanKey(issue.bodyLocationKey)) · \(issue.severity010)/10", systemImage: "bandage")
            }
            if detail.notes?.isEmpty != false && detail.sessionRpe == nil && detail.plannedSession == nil
                && (detail.gear ?? []).isEmpty && (detail.checkins ?? []).isEmpty
                && (detail.bodyIssues ?? []).isEmpty && (detail.goalLinks ?? []).isEmpty
            {
                Text("Add notes, effort or gear to remember how this session felt.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func goalName(_ id: String) -> String {
        viewModel.availableGoals.first(where: { $0.id == id })?.title ?? "Goal"
    }

    private func comparisonSummary(_ activity: FitnessActivitySummary) -> String {
        [
            FitnessDisplay.date(activity.startedAtUtc),
            activity.distanceM.map(FitnessDisplay.distance),
        ].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private func automaticRunComparison(_ detail: FitnessActivityDetail) -> some View {
        if isRun(detail) {
            if let previous = viewModel.comparisons.first(where: {
                $0.isPreviousSimilarDistance == true && $0.automaticComparison != nil
            }), let comparison = previous.automaticComparison {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("\(comparison.distanceLabel) progress", systemImage: "clock.arrow.circlepath")
                            .font(.headline)
                        Text(automaticPaceChange(comparison))
                            .font(.title3.weight(.bold))
                        Text("Compared automatically with \(previous.activity.title) on \(FitnessDisplay.date(previous.activity.startedAtUtc)).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: detailMetricColumns, spacing: 10) {
                        comparisonStat(
                            "This run",
                            pace: comparison.currentPaceSPerKm,
                            duration: comparison.currentDurationS
                        )
                        comparisonStat(
                            "Previous",
                            pace: comparison.previousPaceSPerKm,
                            duration: comparison.previousDurationS
                        )
                    }
                    if abs(comparison.distanceDeltaM) > 10 {
                        Text(
                            "Distances differed by \(FitnessDisplay.distance(abs(comparison.distanceDeltaM))); pace is the fairer comparison."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(
                    Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16)
                )
                .accessibilityIdentifier("fitnessAutomaticRunComparison")
            } else if viewModel.isLoadingComparisons {
                ProgressView("Finding the previous similar run…")
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Label("No similar-distance run yet", systemImage: "clock.arrow.circlepath")
                        .font(.headline)
                    Text("The next run near this distance will compare with this one automatically.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(
                    Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16)
                )
            }
        }
    }

    private func automaticPaceChange(_ comparison: FitnessAutomaticRunComparison) -> String {
        let improvement = comparison.paceImprovementSPerKm
        guard abs(improvement) >= 0.5 else { return "About the same pace" }
        let value = FitnessDisplay.streamValue(
            abs(improvement), metric: "pace_s_per_km", unit: "s/km"
        )
        return "\(value) \(improvement > 0 ? "faster" : "slower")"
    }

    private func comparisonStat(
        _ label: String,
        pace: Double,
        duration: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(FitnessDisplay.streamValue(pace, metric: "pace_s_per_km", unit: "s/km"))
                .font(.headline)
                .monospacedDigit()
            Text(FitnessDisplay.duration(duration))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func findings(_ detail: FitnessActivityDetail) -> some View {
        automaticRunComparison(detail)
        let analysisFindings = FitnessActivityPresentationPolicy.uniqueAnalysisFindings(
            viewModel.analysis?.findings ?? []
        )
        if !analysisFindings.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Highlights").font(.headline)
                ForEach(Array(analysisFindings.enumerated()), id: \.offset) { _, finding in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(finding.title).font(.subheadline.weight(.semibold))
                        Text(finding.summary).foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        if let load = viewModel.analysis?.trainingLoad {
            FitnessRunningLoadPanel(load: load)
        }
        let records = FitnessActivityPresentationPolicy.uniqueRecords(
            (viewModel.analysis?.records ?? []) + (viewModel.analysis?.achievements ?? [])
        )
        if !records.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Records and achievements").font(.headline)
                ForEach(records) { record in
                    Label("\(record.label): \(record.value)", systemImage: record.isPersonalBest == true ? "trophy.fill" : "medal")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }
        if !viewModel.comparisons.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Compare more runs").font(.headline)
                Text("Choose runs to compare their pace, heart rate and elevation.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(viewModel.comparisons) { comparison in
                    Button {
                        viewModel.toggleComparison(comparison.id)
                    } label: {
                        HStack(alignment: .top) {
                            Image(systemName: viewModel.selectedComparisonIds.contains(comparison.id) ? "checkmark.circle.fill" : "circle")
                            VStack(alignment: .leading) {
                                Text(comparison.activity.title).font(.subheadline.weight(.semibold))
                                Text(comparisonSummary(comparison.activity))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .accessibilityValue(
                        viewModel.selectedComparisonIds.contains(comparison.id)
                            ? "Selected" : "Not selected"
                    )
                }
                if !viewModel.selectedComparisonIds.isEmpty {
                    Button {
                        Task { await viewModel.loadComparisonOverlay() }
                    } label: {
                        if viewModel.isLoadingComparisonOverlay {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Label("Compare selected runs", systemImage: "chart.xyaxis.line")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isLoadingComparisonOverlay)
                }
                if let overlay = viewModel.comparisonOverlay {
                    FitnessRunComparisonOverlayView(overlay: overlay)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }
        if let adherence = viewModel.adherence {
            FitnessAdherencePanel(adherence: adherence)
        }
        let quality = FitnessActivityPresentationPolicy.uniqueQualityFindings(
            viewModel.analysis?.dataQuality ?? detail.dataQuality ?? []
        )
        if !quality.isEmpty {
            FitnessQualityPanel(findings: quality)
        }
    }
}

enum FitnessActivityCoachHandoff {
    static func prompt(title: String) -> String {
        let activity = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = activity.isEmpty ? "this activity" : "“\(activity)”"
        return "Review \(name) in the context of the activities around it. What went well, what should I learn, and what should I do next?"
    }
}

struct FitnessActivityPrimaryStat: Identifiable {
    var id: String { label }
    let label: String
    let value: String
    var detail: String? = nil
}

private struct FitnessActivityIntervalGroup: Identifiable {
    let id: String
    let label: String
    let rows: [FitnessActivityInterval]
}

private struct FitnessRunningLoadPanel: View {
    let load: FitnessRunningTrainingLoad

    var body: some View {
        DisclosureGroup("Running load") {
            VStack(alignment: .leading, spacing: 10) {
                if let week = load.windows["7d"] {
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            loadValue("7-day distance", FitnessDisplay.distance(week.distanceM))
                            loadValue("Sessions", String(week.sessionCount))
                            loadValue("Hard", String(week.hardSessionCount))
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            loadValue("7-day distance", FitnessDisplay.distance(week.distanceM))
                            loadValue("Sessions", String(week.sessionCount))
                            loadValue("Hard", String(week.hardSessionCount))
                        }
                    }
                }
                if let change = load.volumeChangePct {
                    Label(
                        "7-day distance \(abs(change).formatted(.number.precision(.fractionLength(0...1))))% \(change >= 0 ? "higher" : "lower") than the previous 7 days",
                        systemImage: load.suddenVolumeChange ? "exclamationmark.triangle" : "arrow.left.and.right"
                    )
                    .foregroundStyle(load.suddenVolumeChange ? .orange : .secondary)
                }
                if let week = load.windows["7d"], let rpeLoad = week.sessionRpeLoad {
                    Text("Effort load: \(rpeLoad.formatted(.number.precision(.fractionLength(0...1))))")
                }
                if !load.consecutiveHardDays.isEmpty {
                    Text(
                        "Hard sessions occurred on consecutive days \(load.consecutiveHardDays.count) time\(load.consecutiveHardDays.count == 1 ? "" : "s")."
                    )
                }
                Text(load.explanation).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func loadValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.subheadline.weight(.semibold))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FitnessRunComparisonOverlayView: View {
    let overlay: FitnessActivityComparisonOverlay

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(overlay.metrics, id: \.self) { metric in
                let points = chartPoints(metric: metric)
                if !points.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(FitnessDisplay.metric(metric)).font(.subheadline.weight(.semibold))
                        Chart(points) { point in
                            LineMark(
                                x: .value("Distance", point.distanceM),
                                y: .value(FitnessDisplay.metric(metric), point.value)
                            )
                            .foregroundStyle(by: .value("Activity", point.title))
                        }
                        .chartXAxisLabel("Distance (km)")
                        .frame(height: 180)
                    }
                }
            }
            if overlay.activities.isEmpty {
                Text("These runs don’t have enough detail to compare.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Compared over their shared distance.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 6)
    }

    private func chartPoints(metric: String) -> [FitnessComparisonChartPoint] {
        overlay.activities.flatMap { activity -> [FitnessComparisonChartPoint] in
            guard let values = activity.series[metric] else { return [] }
            return values.indices.compactMap { index in
                guard overlay.distanceM.indices.contains(index), let value = values[index] else { return nil }
                return FitnessComparisonChartPoint(
                    id: "\(activity.activityId):\(metric):\(index)",
                    title: activity.title,
                    distanceM: overlay.distanceM[index] / 1_000,
                    value: value
                )
            }
        }
    }
}

private struct FitnessComparisonChartPoint: Identifiable {
    let id: String
    let title: String
    let distanceM: Double
    let value: Double
}

private struct FitnessMetricChart: View {
    let metric: String
    let stream: FitnessActivityStream
    @Binding var selectedOffsetMs: Int?
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var points: [FitnessChartPoint] {
        guard let values = stream.series[metric] else { return [] }
        return values.indices.compactMap { index in
            guard stream.offsetMs.indices.contains(index), let value = values[index] else { return nil }
            return FitnessChartPoint(offsetMs: stream.offsetMs[index], value: value)
        }
    }

    private var chartColor: Color {
        switch metric {
        case "heart_rate_bpm": .red
        case "altitude_m": .green
        case "cadence_spm": .purple
        case "power_w": .orange
        default: .accentColor
        }
    }

    private func plottedValue(_ value: Double) -> Double {
        metric == "pace_s_per_km" ? -value : value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    chartTitle
                    Spacer()
                    selectedReading
                }
                VStack(alignment: .leading, spacing: 4) {
                    chartTitle
                    selectedReading
                }
            }
            let minimum = points.map { plottedValue($0.value) }.min() ?? 0
            Chart {
                ForEach(points) { point in
                    AreaMark(
                        x: .value("Time", point.offsetMs),
                        yStart: .value("Visible minimum", minimum),
                        yEnd: .value("Value", plottedValue(point.value))
                    )
                    .foregroundStyle(
                        LinearGradient(colors: [chartColor.opacity(0.24), chartColor.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    LineMark(
                        x: .value("Time", point.offsetMs),
                        y: .value("Value", plottedValue(point.value))
                    )
                    .foregroundStyle(chartColor)
                    .lineStyle(
                        StrokeStyle(
                            lineWidth: colorSchemeContrast == .increased ? 3 : 2,
                            lineCap: .round, lineJoin: .round
                        ))
                }
                if let selectedOffsetMs {
                    RuleMark(x: .value("Selected time", selectedOffsetMs))
                        .foregroundStyle(.orange)
                        .lineStyle(
                            StrokeStyle(
                                lineWidth: colorSchemeContrast == .increased ? 4 : 2
                            ))
                }
            }
            .chartXSelection(value: $selectedOffsetMs)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel {
                        if let milliseconds = value.as(Int.self) {
                            Text(FitnessDisplay.duration(Double(milliseconds) / 1_000))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel {
                        if let plotted = value.as(Double.self) {
                            Text(
                                FitnessDisplay.streamValue(
                                    metric == "pace_s_per_km" ? -plotted : plotted,
                                    metric: metric,
                                    unit: stream.units[metric]
                                )
                            )
                        }
                    }
                }
            }
            .chartPlotStyle { plot in
                plot.background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
            }
            .frame(height: 190)
            .accessibilityLabel("\(FitnessDisplay.metric(metric)) chart")
            .accessibilityValue(chartAccessibilityValue)
            .accessibilityHint("Swipe up or down to move the selected position.")
            .accessibilityAdjustableAction(moveSelection)
            ViewThatFits(in: .horizontal) {
                HStack {
                    chartStat(lowerStatLabel, points.map(\.value).min())
                    Spacer()
                    chartStat(upperStatLabel, points.map(\.value).max(), trailing: true)
                }
                VStack(alignment: .leading, spacing: 8) {
                    chartStat(lowerStatLabel, points.map(\.value).min())
                    chartStat(upperStatLabel, points.map(\.value).max())
                }
            }
        }
        .padding(12)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14))
        .transaction { transaction in
            if reduceMotion { transaction.animation = nil }
        }
    }

    private var chartTitle: some View {
        Text(FitnessDisplay.metric(metric)).font(.subheadline.weight(.semibold))
    }

    private var lowerStatLabel: String {
        metric == "pace_s_per_km" ? "Fastest" : "Minimum"
    }

    private var upperStatLabel: String {
        metric == "pace_s_per_km" ? "Slowest" : "Maximum"
    }

    @ViewBuilder private var selectedReading: some View {
        if let selectedOffsetMs,
            let value = stream.value(metric: metric, nearest: selectedOffsetMs)
        {
            VStack(alignment: .leading, spacing: 1) {
                Text(FitnessDisplay.streamValue(value, metric: metric, unit: stream.units[metric]))
                    .font(.subheadline.weight(.bold)).monospacedDigit()
                Text("At \(FitnessDisplay.duration(Double(selectedOffsetMs)/1_000))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var chartAccessibilityValue: String {
        var values = [FitnessDisplay.chartSummary(points, unit: stream.units[metric])]
        if let selectedOffsetMs,
            let selected = stream.value(metric: metric, nearest: selectedOffsetMs)
        {
            values.append(
                "Selected \(FitnessDisplay.streamValue(selected,metric:metric,unit:stream.units[metric])) at \(FitnessDisplay.duration(Double(selectedOffsetMs)/1_000))"
            )
        }
        return values.joined(separator: ". ")
    }

    private func moveSelection(_ direction: AccessibilityAdjustmentDirection) {
        guard !points.isEmpty else { return }
        let current: Int
        if let selectedOffsetMs {
            current =
                points.indices.min {
                    abs(points[$0].offsetMs - selectedOffsetMs)
                        < abs(points[$1].offsetMs - selectedOffsetMs)
                } ?? 0
        } else {
            current = 0
        }
        switch direction {
        case .increment:
            selectedOffsetMs = points[min(points.count - 1, current + 1)].offsetMs
        case .decrement:
            selectedOffsetMs = points[max(0, current - 1)].offsetMs
        @unknown default:
            return
        }
    }

    private func chartStat(_ label: String, _ value: Double?, trailing: Bool = false) -> some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(FitnessDisplay.streamValue(value, metric: metric, unit: stream.units[metric]))
                .font(.caption.weight(.semibold)).monospacedDigit()
        }
    }
}

struct FitnessChartPoint: Identifiable {
    var id: Int { offsetMs }
    let offsetMs: Int
    let value: Double
}

private struct FitnessQualityPanel: View {
    let findings: [FitnessDataQualityFinding]
    var body: some View {
        DisclosureGroup("Data notes") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(findings) { finding in
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(FitnessDisplay.qualityFindingTitle(finding.key))
                                .font(.subheadline.weight(.semibold))
                            Text(FitnessActivityPresentationPolicy.qualityMessage(finding))
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(
                            systemName: finding.severity == "error"
                                ? "exclamationmark.octagon.fill"
                                : "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                    }
                }
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct FitnessAdherencePanel: View {
    let adherence: FitnessPlanAdherence
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Plan execution").font(.headline)
            if let explanation = adherence.explanation { Text(explanation).foregroundStyle(.secondary) }
            ForEach(adherence.steps ?? []) { step in
                VStack(alignment: .leading) {
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            Text(step.label)
                            Spacer()
                            Text(FitnessDisplay.humanKey(step.state))
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(step.label)
                            Text(FitnessDisplay.humanKey(step.state))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("Planned \(step.planned) · Actual \(step.actual)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct FitnessActivityInformationSheet: View {
    @ObservedObject var viewModel: FitnessActivityDetailViewModel
    @Environment(\.dismiss) private var dismiss
    let detail: FitnessActivityDetail
    @State private var confirmingRebuild = false

    var body: some View {
        NavigationStack {
            List {
                Section("Recorded with") {
                    let sources = FitnessActivityPresentationPolicy.uniqueSources(detail.sources)
                    if sources.isEmpty {
                        Text("No device information is available.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(sources) { source in
                        LabeledContent(source.label, value: source.detail ?? "Activity file")
                    }
                }
                if detail.sources.contains(where: \.hasRetainedFitFile) {
                    Section {
                        Button("Rebuild route and charts", systemImage: "arrow.clockwise") {
                            confirmingRebuild = true
                        }
                        .frame(minHeight: 44)
                        .disabled(viewModel.isLoading)
                    } footer: {
                        Text("Use this if the route, splits or charts look incomplete.")
                    }
                }
                if viewModel.errorMessage != nil {
                    Section {
                        Label(
                            FitnessActivityPresentationPolicy.actionError,
                            systemImage: "exclamationmark.triangle.fill"
                        )
                    }
                }
            }
            .navigationTitle("Activity information")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        ZStack {
                            Color.clear
                            Text("Done")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .confirmationDialog(
                "Rebuild this activity?",
                isPresented: $confirmingRebuild,
                titleVisibility: .visible
            ) {
                Button("Rebuild") { Task { await viewModel.reanalyse() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This recreates the route, splits and charts from the original file. Your notes, gear and goals stay unchanged.")
            }
        }
    }
}

private struct FitnessActivityContextSheet: View {
    @ObservedObject var viewModel: FitnessActivityDetailViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var notes: String
    @State private var rpe: Double
    @State private var hasRPE: Bool
    @State private var classification: String
    @State private var gearIds: Set<String>
    @State private var goalIds: Set<String>
    private let plannedGoalIds: Set<String>

    private let classifications = [
        "unclassified", "recovery", "easy", "steady", "long", "tempo", "threshold", "interval", "hill", "race", "time_trial", "progression",
        "mixed",
    ]

    init(viewModel: FitnessActivityDetailViewModel, detail: FitnessActivityDetail) {
        self.viewModel = viewModel
        _title = State(initialValue: detail.activity.title)
        _notes = State(initialValue: detail.notes ?? "")
        _rpe = State(initialValue: detail.sessionRpe ?? 5)
        _hasRPE = State(initialValue: detail.sessionRpe != nil)
        _classification = State(initialValue: detail.activity.workoutClassification ?? "unclassified")
        _gearIds = State(initialValue: Set((detail.gear ?? []).map(\.id)))
        _goalIds = State(initialValue: Set((detail.goalLinks ?? []).filter(\.isEditable).map(\.goalId)))
        plannedGoalIds = Set((detail.goalLinks ?? []).filter { $0.role == "planned" }.map(\.goalId))
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                TextField("Notes", text: $notes, axis: .vertical)
                Picker("Classification", selection: $classification) {
                    ForEach(classifications, id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ").capitalized).tag($0) }
                }
                Toggle("Record post-session effort", isOn: $hasRPE)
                if hasRPE {
                    Slider(value: $rpe, in: 0...10, step: 0.5)
                        .accessibilityLabel("Session effort")
                        .accessibilityValue("\(rpe.formatted()) out of 10")
                    Text("Session effort: \(rpe.formatted())/10")
                }
                Section("Actual gear") {
                    ForEach(viewModel.availableGear.filter { $0.active != false }) { item in
                        Button {
                            if gearIds.contains(item.id) { gearIds.remove(item.id) } else { gearIds.insert(item.id) }
                        } label: {
                            HStack {
                                Text(item.name).foregroundStyle(.primary)
                                Spacer()
                                if gearIds.contains(item.id) { Image(systemName: "checkmark") }
                            }
                        }
                        .frame(minHeight: 44)
                    }
                }
                Section("Goals") {
                    if viewModel.availableGoals.isEmpty {
                        Text("No goals available").foregroundStyle(.secondary)
                    }
                    ForEach(viewModel.availableGoals) { goal in
                        let inherited = plannedGoalIds.contains(goal.id)
                        Button {
                            guard !inherited else { return }
                            if goalIds.contains(goal.id) { goalIds.remove(goal.id) } else { goalIds.insert(goal.id) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(goal.title).foregroundStyle(.primary)
                                    if inherited { Text("Inherited from plan").font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                Image(systemName: inherited || goalIds.contains(goal.id) ? "checkmark.circle.fill" : "circle")
                            }
                        }
                        .disabled(inherited)
                        .frame(minHeight: 44)
                    }
                    Text("Goals inherited from the plan stay selected.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if viewModel.errorMessage != nil {
                    Section {
                        Label(
                            FitnessActivityPresentationPolicy.actionError,
                            systemImage: "exclamationmark.triangle.fill"
                        )
                    }
                }
                Section {
                    Text("Notes and effort describe how the session felt afterward.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Edit activity")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            let contextSaved = await viewModel.updateContext(
                                title: title, notes: notes.isEmpty ? nil : notes,
                                sessionRPE: hasRPE ? rpe : nil,
                                classification: classification, gearIds: Array(gearIds)
                            )
                            if contextSaved, await viewModel.saveGoalLinks(goalIds) { dismiss() }
                        }
                    }
                    .disabled(
                        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || viewModel.isLoading
                    )
                }
            }
        }
    }
}
