import Charts
import SwiftUI

struct FitnessProgressView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = FitnessProgressViewModel()
    @StateObject private var goalViewModel = FitnessTrainingViewModel()
    @State private var showingHistory = false
    @State private var showingStrength = false
    @State private var showingMeasurements = false
    @State private var showingGoalChooser = false
    @State private var runningSelections: [String: Date] = [:]

    var body: some View {
        List {
            if viewModel.isLoading && viewModel.weeklyReview == nil && viewModel.activities.isEmpty {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading your week…").foregroundStyle(.secondary)
                    }
                }
            }
            if let error = viewModel.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Button("Try again", systemImage: "arrow.clockwise") { Task { await viewModel.loadHome(refresh: true) } }
                        .disabled(viewModel.isLoading)
                }
            }
            if let review = viewModel.weeklyReview {
                weeklyReview(review)
                goalProgress(review)
            }
            weightProgress
            activityTrend
            performanceProgress
            Section("Recent activity") {
                if viewModel.activities.isEmpty {
                    Text("Completed activities will appear here.").foregroundStyle(.secondary)
                }
                ForEach(viewModel.activities.prefix(4)) { activity in
                    NavigationLink {
                        FitnessActivityDetailView(activityId: activity.id)
                    } label: {
                        activityRow(activity)
                    }
                }
                NavigationLink {
                    FitnessActivityHistoryView()
                } label: {
                    Label("View all activity", systemImage: "clock.arrow.circlepath")
                }
            }
            Section("Explore progress") {
                NavigationLink {
                    FitnessStrengthProgressDetailView()
                } label: {
                    Label("Strength", systemImage: "dumbbell")
                }
                NavigationLink {
                    FitnessMeasurementTrendsView()
                } label: {
                    Label("Body trends", systemImage: "chart.xyaxis.line")
                }
                NavigationLink {
                    FitnessRecoveryView()
                } label: {
                    Label("Recovery", systemImage: "moon.stars")
                }
            }
            Section("More") {
                NavigationLink {
                    FitnessProgressPhotosView()
                } label: {
                    Label("Progress photos", systemImage: "person.example_35fbacff.rectangle.stack")
                }
                NavigationLink {
                    FitnessExportView()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                NavigationLink {
                    FitnessInsightsQuestionsView()
                } label: {
                    Label("Insights", systemImage: "questionmark.bubble")
                }
            }
        }
        .navigationTitle("Review")
        .navigationDestination(isPresented: $showingHistory) { FitnessActivityHistoryView() }
        .navigationDestination(isPresented: $showingStrength) { FitnessStrengthProgressDetailView() }
        .navigationDestination(isPresented: $showingMeasurements) { FitnessBodyMeasurementsView() }
        .sheet(isPresented: $showingGoalChooser, onDismiss: { Task { await viewModel.loadHome(refresh: true) } }) {
            FitnessGoalTemplateSheet(viewModel: goalViewModel)
        }
        .task { await viewModel.loadHome() }
        .refreshable { await viewModel.loadHome(refresh: true) }
    }

    private func weeklyReview(_ review: FitnessWeeklyReview) -> some View {
        Section("This week") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), alignment: .leading)], alignment: .leading, spacing: 12) {
                total("Sessions", Double(review.totals.completedSessions), unit: nil)
                total("Active days", Double(review.totals.activeDays), unit: nil)
                if let minutes = review.totals.durationMinutes { total("Minutes", Double(minutes), unit: nil) }
                if let distance = review.totals.distanceKm { total("Distance", distance, unit: "km") }
                if let volume = review.totals.strengthVolumeKg { total("Strength", volume, unit: "kg") }
            }
            VStack(alignment: .leading, spacing: 3) {
                Label(review.highlight.title, systemImage: "sparkles")
                    .font(.headline)
                Text(review.highlight.detail).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(review.opportunity.title).font(.headline)
                Text(review.opportunity.detail).foregroundStyle(.secondary)
                Button(review.opportunity.actionLabel) { follow(review.opportunity) }
                    .buttonStyle(.borderedProminent).frame(minHeight: 44)
            }
        }
    }

    @ViewBuilder private func goalProgress(_ review: FitnessWeeklyReview) -> some View {
        Section("Your goal") {
            if let goal = review.goal {
                Text(goal.goalName).font(.headline)
                Text(goal.progressText).foregroundStyle(.secondary)
                if let percent = goal.progressPercent {
                    ProgressView(value: Double(percent), total: 100)
                        .accessibilityLabel("Progress toward \(goal.goalName)")
                        .accessibilityValue("\(percent) percent")
                }
            } else {
                Text("Choose a goal to make this view personal to you.").foregroundStyle(.secondary)
                Button("Choose a goal") { chooseGoal() }
            }
        }
    }

    @ViewBuilder private var activityTrend: some View {
        if let kind = trendKind, kind != .weight {
            Section(kind.title) {
                Chart(trendPoints) { point in
                    if let value = point.value {
                        BarMark(
                            x: .value("Week", point.start, unit: .weekOfYear),
                            y: .value(kind.title, value)
                        )
                        .foregroundStyle(Color.accentColor.gradient)
                        .cornerRadius(4)
                    }
                }
                .frame(height: 150)
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(kind.title) over four weeks")
                .accessibilityValue(trendAccessibility)
                Text(trendSummary).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var weightProgress: some View {
        Section("Weight progress") {
            if viewModel.isLoading && viewModel.weights.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading weight trend…").foregroundStyle(.secondary)
                }
            } else {
                FitnessMeasurementTrendsView(overview: true, history: overviewWeightHistory)
                NavigationLink {
                    FitnessMeasurementTrendsView()
                } label: {
                    Label("View all weight and body trends", systemImage: "chart.xyaxis.line")
                }
            }
        }
    }

    private var overviewWeightHistory: FitnessMeasurementHistoryDTO {
        FitnessMeasurementHistoryBuilder.make(
            metric: .weight,
            bodyMeasurements: viewModel.weights,
            recoveryObservations: []
        )
    }

    @ViewBuilder private var performanceProgress: some View {
        if viewModel.progressChartsLoading {
            Section("Performance progress") {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading run and working-set trends…")
                        .foregroundStyle(.secondary)
                }
            }
        } else if let error = viewModel.progressChartsError {
            Section("Performance progress") {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button("Try again", systemImage: "arrow.clockwise") {
                    Task { await viewModel.loadProgressCharts(refresh: true) }
                }
                .disabled(viewModel.progressChartsLoading)
            }
        } else {
            runningProgress
            strengthProgress
        }
    }

    private var runningProgress: some View {
        Section("Running progress") {
            Text("Best-effort records are used when available; otherwise HausKlar shows an average-pace estimate.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if viewModel.progressCharts.running.isEmpty {
                Text("Complete a 5K or 10K run to start these trends.")
                    .foregroundStyle(.secondary)
            }
            ForEach(viewModel.progressCharts.running) { series in
                runningProgressCard(series)
            }
        }
    }

    private func runningProgressCard(_ series: FitnessRunningProgressSeriesDTO) -> some View {
        let points = series.points.sorted { $0.startedAt < $1.startedAt }
        let selected = selectedRunningPoint(series.key, points: points)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(series.label) time")
                        .font(.headline)
                    Text(points.last?.source.title ?? "No result yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let latest = points.last {
                    Text(runDuration(latest.durationS))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.orange)
                }
            }

            if points.isEmpty {
                Label("Complete a \(series.label) run to start this trend.", systemImage: "figure.run")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
            } else {
                Chart(points) { point in
                    LineMark(
                        x: .value("Date", point.startedAt),
                        y: .value("Estimated time", point.durationS)
                    )
                    .foregroundStyle(Color.orange)
                    .interpolationMethod(.monotone)
                    PointMark(
                        x: .value("Date", point.startedAt),
                        y: .value("Estimated time", point.durationS)
                    )
                    .foregroundStyle(point.source == .bestEffort ? Color.orange : Color.secondary)
                    .symbolSize(point.source == .bestEffort ? 42 : 28)
                    if selected?.id == point.id {
                        RuleMark(x: .value("Selected date", point.startedAt))
                            .foregroundStyle(Color.orange.opacity(0.45))
                        PointMark(
                            x: .value("Selected date", point.startedAt),
                            y: .value("Selected time", point.durationS)
                        )
                        .foregroundStyle(Color.orange)
                        .symbolSize(90)
                    }
                }
                .chartYScale(domain: runningDomain(points))
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine().foregroundStyle(Color.secondary.opacity(0.16))
                        AxisValueLabel {
                            if let seconds = value.as(Double.self) {
                                Text(runDuration(seconds)).font(.caption2)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) {
                        AxisGridLine().foregroundStyle(Color.secondary.opacity(0.08))
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day()).font(.caption2)
                    }
                }
                .chartXSelection(value: runningSelection(series.key))
                .frame(height: 150)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(series.label) running progress")
                .accessibilityValue(runningAccessibility(points))
                if let selected {
                    Text(
                        "\(selected.startedAt.formatted(date:.abbreviated,time:.omitted)) · \(runPace(selected,series:series))/km · \(runDuration(selected.durationS)) total"
                    )
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.primary)
                    .accessibilityLabel("Selected run")
                } else {
                    Text("Tap or drag across a point to see its pace.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(runningSummary(points))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var strengthProgress: some View {
        Section("Working-set progress") {
            Text("Top recorded working set per session. Warm-ups are excluded, and each chart keeps one exercise and setup comparable.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if viewModel.progressCharts.strength.isEmpty {
                Text("Complete working sets to start your strength trends.")
                    .foregroundStyle(.secondary)
            }
            ForEach(viewModel.progressCharts.strength) { series in
                strengthProgressCard(series)
            }
        }
    }

    private func strengthProgressCard(_ series: FitnessStrengthProgressChartSeriesDTO) -> some View {
        let points = series.points.sorted { $0.performedAt < $1.performedAt }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(series.label)
                        .font(.headline)
                    Text(strengthSeriesDetail(series))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let latest = points.last {
                    Text(strengthSet(latest))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.indigo)
                }
            }

            if points.isEmpty {
                Label("Complete a \(series.label.lowercased()) working set to start this trend.", systemImage: "dumbbell")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
            } else {
                Chart(points) { point in
                    LineMark(
                        x: .value("Date", point.performedAt),
                        y: .value("Load", point.loadKg)
                    )
                    .foregroundStyle(Color.indigo)
                    .interpolationMethod(.monotone)
                    PointMark(
                        x: .value("Date", point.performedAt),
                        y: .value("Load", point.loadKg)
                    )
                    .foregroundStyle(Color.indigo)
                    .symbolSize(34)
                }
                .chartYScale(domain: strengthDomain(points))
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine().foregroundStyle(Color.secondary.opacity(0.16))
                        AxisValueLabel {
                            if let load = value.as(Double.self) {
                                Text("\(load.formatted(.number.precision(.fractionLength(0...1)))) kg")
                                    .font(.caption2)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) {
                        AxisGridLine().foregroundStyle(Color.secondary.opacity(0.08))
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day()).font(.caption2)
                    }
                }
                .frame(height: 150)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(series.label) working-set progress")
                .accessibilityValue(strengthAccessibility(points))
                Text(strengthSummary(points))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func runDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remaining = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, remaining) }
        return String(format: "%d:%02d", minutes, remaining)
    }

    private func runPace(
        _ point: FitnessRunningProgressPointDTO,
        series: FitnessRunningProgressSeriesDTO
    ) -> String {
        let kilometres = Double(series.distanceM) / 1_000
        return runDuration(kilometres > 0 ? point.durationS / kilometres : point.durationS)
    }

    private func runningSelection(_ key: String) -> Binding<Date?> {
        Binding(
            get: { runningSelections[key] },
            set: { value in
                if let value { runningSelections[key] = value } else { runningSelections.removeValue(forKey: key) }
            }
        )
    }

    private func selectedRunningPoint(
        _ key: String, points: [FitnessRunningProgressPointDTO]
    ) -> FitnessRunningProgressPointDTO? {
        guard let date = runningSelections[key] else { return nil }
        return points.min {
            abs($0.startedAt.timeIntervalSince(date)) < abs($1.startedAt.timeIntervalSince(date))
        }
    }

    private func runningDomain(_ points: [FitnessRunningProgressPointDTO]) -> ClosedRange<Double> {
        let values = points.map(\.durationS)
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        let padding = max((high - low) * 0.2, 30)
        return max(0, low - padding)...(high + padding)
    }

    private func runningSummary(_ points: [FitnessRunningProgressPointDTO]) -> String {
        guard let latest = points.last else { return "No result yet." }
        let latestText = runDuration(latest.durationS)
        guard let first = points.first, first.id != latest.id else {
            return "Latest: \(latestText) · \(latest.source.title)."
        }
        let change = latest.durationS - first.durationS
        if abs(change) < 0.5 { return "Latest: \(latestText) · unchanged · \(latest.source.title)." }
        return "Latest: \(latestText) · \(runDuration(abs(change))) \(change < 0 ? "faster" : "slower") · \(latest.source.title)."
    }

    private func runningAccessibility(_ points: [FitnessRunningProgressPointDTO]) -> String {
        points.map {
            "\($0.startedAt.formatted(date:.abbreviated,time:.omitted)), \(runDuration($0.durationS)), \($0.source.title)"
        }.joined(separator: ", ")
    }

    private func strengthSeriesDetail(_ series: FitnessStrengthProgressChartSeriesDTO) -> String {
        let parts = [series.exerciseName, series.setupName].compactMap { $0 }
        return parts.isEmpty ? "No matching working sets yet" : parts.joined(separator: " · ")
    }

    private func strengthSet(_ point: FitnessStrengthProgressChartPointDTO) -> String {
        let load = point.loadKg.formatted(.number.precision(.fractionLength(0...1)))
        return point.repetitions.map { "\(load) kg × \($0)" } ?? "\(load) kg"
    }

    private func strengthDomain(_ points: [FitnessStrengthProgressChartPointDTO]) -> ClosedRange<Double> {
        let values = points.map(\.loadKg)
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        let padding = max((high - low) * 0.2, 2.5)
        return max(0, low - padding)...(high + padding)
    }

    private func strengthSummary(_ points: [FitnessStrengthProgressChartPointDTO]) -> String {
        guard let latest = points.last else { return "No working sets yet." }
        let count = "\(latest.workingSetCount) working set\(latest.workingSetCount == 1 ? "" : "s") logged"
        guard let first = points.first, first.id != latest.id else { return "Latest: \(strengthSet(latest)) · \(count)." }
        let change = latest.loadKg - first.loadKg
        if abs(change) < 0.05 { return "Latest: \(strengthSet(latest)) · load unchanged · \(count)." }
        let difference = abs(change).formatted(.number.precision(.fractionLength(0...1)))
        return "Latest: \(strengthSet(latest)) · \(difference) kg \(change > 0 ? "higher" : "lower") · \(count)."
    }

    private func strengthAccessibility(_ points: [FitnessStrengthProgressChartPointDTO]) -> String {
        points.map {
            "\($0.performedAt.formatted(date:.abbreviated,time:.omitted)), \(strengthSet($0))"
        }.joined(separator: ", ")
    }

    private struct TrendPoint: Identifiable {
        let start: Date
        let value: Double?
        var id: Date { start }
    }

    private var selectedGoalEntity: FitnessGoal? {
        guard let id = viewModel.weeklyReview?.goal?.goalId else { return nil }
        return viewModel.goals.first { $0.id == id }
    }

    private var trendKind: FitnessGoalTrendKind? {
        selectedGoalEntity.map { FitnessGoalTrendKind.resolve(metric: $0.metric) }
    }

    private var trendPoints: [TrendPoint] {
        guard let kind = trendKind else { return [] }
        let current = FitnessProgressLoadPolicy.currentMonday(for: viewModel.trendReferenceDate)
        return (-3...0).compactMap { offset in
            guard let start = Calendar.current.date(byAdding: .weekOfYear, value: offset, to: current),
                let end = Calendar.current.date(byAdding: .day, value: 7, to: start)
            else { return nil }
            let activities = viewModel.activities.filter { $0.startedAt >= start && $0.startedAt < end }
            let value: Double?
            switch kind {
            case .sessions:
                value = Double(activities.count)
            case .activeDays:
                value = Double(Set(activities.map { Calendar.current.startOfDay(for: $0.startedAt) }).count)
            case .runningDistance:
                value = activities.filter { $0.sportKey == "running" }.compactMap(\.distanceM).reduce(0, +) / 1_000
            case .strengthSessions:
                value = Double(activities.filter { $0.sportKey == "strength" }.count)
            case .weight:
                value =
                    viewModel.weights.filter { $0.measuredAt >= start && $0.measuredAt < end }
                    .max(by: { $0.measuredAt < $1.measuredAt })?.weightKg
            }
            return TrendPoint(start: start, value: value)
        }
    }

    private var trendAccessibility: String {
        let unit = trendKind?.unit ?? ""
        return trendPoints.map {
            "Week of \($0.start.formatted(date:.abbreviated,time:.omitted)): "
                + ($0.value.map { "\($0.formatted(.number.precision(.fractionLength(0...1)))) \(unit)" } ?? "no reading")
        }
        .joined(separator: ", ")
    }

    private var trendSummary: String {
        guard let kind = trendKind, let first = trendPoints.first?.value, let last = trendPoints.last?.value else {
            return "Keep recording this goal to build a four-week trend."
        }
        let formattedFirst = first.formatted(.number.precision(.fractionLength(0...1)))
        let formattedLast = last.formatted(.number.precision(.fractionLength(0...1)))
        if kind == .weight { return "Three weeks ago: \(formattedFirst) kg · this week: \(formattedLast) kg." }
        let difference = abs(last - first).formatted(.number.precision(.fractionLength(0...1)))
        if last > first { return "This week is \(difference) \(kind.unit) above three weeks ago." }
        if last < first { return "This week is \(difference) \(kind.unit) below three weeks ago." }
        return "This week matches three weeks ago at \(formattedLast) \(kind.unit)."
    }

    private func total(_ label: String, _ value: Double, unit: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.formatted(.number.precision(.fractionLength(0...1))) + (unit.map { " \($0)" } ?? ""))
                .font(.title2.bold()).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func activityRow(_ activity: FitnessActivitySummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(activity.title)
            Text(activityDetail(activity)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func activityDetail(_ activity: FitnessActivitySummary) -> String {
        let duration = activity.movingDurationS ?? activity.timerDurationS ?? activity.durationS
        var parts = [
            activity.startedAt.formatted(date: .abbreviated, time: .shortened),
            FitnessDisplay.humanKey(activity.sportKey),
        ]
        if let distance = activity.distanceM { parts.append(String(format: "%.1f km", distance / 1_000)) }
        if activity.sportKey.contains("run"),
            let pace = FitnessDisplay.averagePaceSecondsPerKilometre(
                summaryMetrics: activity.primaryMetrics ?? [], distanceMetres: activity.distanceM,
                durationSeconds: duration
            )
        {
            parts.append(FitnessDisplay.streamValue(pace, metric: "pace_s_per_km", unit: "s/km"))
        }
        if let duration { parts.append("\(Int((duration/60).rounded())) min") }
        if let energy = activity.energyKcal {
            parts.append("\(activity.energyEstimationMethod == nil ? "" : "≈ ")\(Int(energy.rounded())) kcal")
        }
        if let plan = activity.plannedSessionTitle { parts.append("Matched to \(plan)") }
        return parts.joined(separator: " · ")
    }

    private func follow(_ opportunity: FitnessWeeklyReviewOpportunity) {
        HapticManager.selection()
        switch opportunity.destination {
        case .today: appState.selectedFitnessDestination = .overview
        case .plan: appState.selectedFitnessDestination = .plan
        case .goals: chooseGoal()
        case .activities: showingHistory = true
        case .strength: showingStrength = true
        case .measurements: showingMeasurements = true
        }
    }

    private func chooseGoal() {
        Task {
            await goalViewModel.loadManage()
            showingGoalChooser = true
        }
    }
}

private struct FitnessStrengthProgressDetailView: View {
    @StateObject private var viewModel = FitnessProgressViewModel()

    var body: some View {
        List {
            if viewModel.isLoading && viewModel.strength.isEmpty {
                HStack {
                    ProgressView()
                    Text("Loading strength…").foregroundStyle(.secondary)
                }
            }
            Section("Recent workouts") {
                if viewModel.strength.isEmpty { Text("Finished workouts will appear here.").foregroundStyle(.secondary) }
                ForEach(viewModel.strength, id: \.sessionId) { session in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.title)
                        Text(
                            "\(session.workingSets) working sets · \(Int(session.volumeKg)) kg total · \(session.endedAt.formatted(date:.abbreviated,time:.omitted))"
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Exercise progress") {
                if viewModel.exerciseSeries.isEmpty {
                    Text("Repeat an exercise to see how it changes over time.").foregroundStyle(.secondary)
                }
                ForEach(viewModel.exerciseSeries.prefix(12)) { series in
                    DisclosureGroup {
                        ForEach(series.points.suffix(6)) { point in
                            LabeledContent(point.performedAt.formatted(date: .abbreviated, time: .omitted), value: strengthPoint(point))
                        }
                    } label: {
                        Text(series.exerciseName)
                    }
                }
            }
            Section("Training balance") {
                if viewModel.muscleExposure.isEmpty {
                    Text("Training balance appears after completed strength workouts.").foregroundStyle(.secondary)
                }
                ForEach(viewModel.muscleExposure.prefix(12)) { item in
                    LabeledContent(human(item.muscleGroupKey), value: "\(item.directWorkingSets) working sets")
                }
            }
        }
        .navigationTitle("Strength progress")
        .task { await viewModel.loadStrengthDetails() }
        .refreshable { await viewModel.loadStrengthDetails() }
    }

    private func strengthPoint(_ point: FitnessStrengthProgressPoint) -> String {
        var values: [String] = []
        if let load = point.normalizedLoadKg { values.append("\(load.formatted()) kg") }
        if let reps = point.recordReps { values.append("\(reps) reps") }
        return values.isEmpty ? "Workout recorded" : values.joined(separator: " × ")
    }

    private func human(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

private struct FitnessInsightsQuestionsView: View {
    @StateObject private var viewModel = FitnessAnalysisViewModel(preferredSurface: "progress")
    @State private var selected: FitnessInsightQuestion?

    var body: some View {
        List {
            Section("Ask about your progress") {
                ForEach(FitnessInsightQuestion.allCases) { question in
                    Button {
                        selected = question
                        Task { await run(question) }
                    } label: {
                        Label(question.rawValue, systemImage: question.symbol)
                            .foregroundStyle(.primary).frame(minHeight: 44)
                    }
                }
            }
            if viewModel.isLoading || viewModel.isQuerying {
                Section {
                    HStack {
                        ProgressView()
                        Text("Looking at your records…").foregroundStyle(.secondary)
                    }
                }
            }
            if let error = viewModel.errorMessage {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            }
            if let selected, let result = viewModel.result {
                Section(selected.rawValue) { FitnessAnalysisResultView(result: result, showsTechnicalDetails: false) }
            }
            Section {
                NavigationLink {
                    FitnessExploreView()
                } label: {
                    Label("Advanced", systemImage: "slider.horizontal.3")
                }
            } footer: {
                Text("Build and save your own charts")
            }
        }
        .navigationTitle("Insights")
        .onDisappear { viewModel.cancelQuery() }
    }

    private func run(_ question: FitnessInsightQuestion) async {
        if viewModel.registry == nil { await viewModel.load() }
        guard let preset = question.preferredPreset(in: viewModel.presets) else {
            viewModel.errorMessage = "There is not enough recorded data for that question yet."
            return
        }
        viewModel.apply(preset)
        await viewModel.query()
    }
}
