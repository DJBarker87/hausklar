import CoreLocation
import SwiftUI
import UniformTypeIdentifiers

struct FitnessActivityHistoryView: View {
    @StateObject private var viewModel = FitnessActivityHistoryViewModel()
    @State private var showingImporter = false
    @State private var showingFilters = false
    @State private var showingImportStatus = false
    @State private var showingManualActivity = false
    @State private var unownedToAdopt: SharedFitnessFITPayload?
    @State private var copiedStrengthActivityId: String?

    private var fitType: UTType { UTType(filenameExtension: "fit") ?? .data }

    var body: some View {
        List {
            if viewModel.errorMessage != nil && viewModel.activities.isEmpty {
                Section {
                    Label(
                        FitnessActivityPresentationPolicy.historyError(
                            hasActivities: !viewModel.activities.isEmpty
                        ),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.primary)
                    Button("Try again", systemImage: "arrow.clockwise") {
                        Task { await viewModel.load(refresh: true) }
                    }
                    .frame(minHeight: 44)
                    .disabled(viewModel.isLoading)
                }
            }
            Section("Activity history") {
                if viewModel.isLoading && viewModel.activities.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading activities…").foregroundStyle(.secondary)
                    }
                } else if viewModel.activities.isEmpty {
                    ContentUnavailableView {
                        Label(hasFilters ? "No matching activities" : "No activities yet", systemImage: "figure.run")
                    } description: {
                        Text(
                            hasFilters
                                ? "Change the filters to broaden the history."
                                : "Log a completed activity or import one from Garmin. A plan is never required.")
                    } actions: {
                        if hasFilters {
                            Button("Clear filters", systemImage: "line.3.horizontal.decrease.circle") {
                                viewModel.filter = FitnessActivityFilter()
                                Task { await viewModel.load() }
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            Button("Log activity", systemImage: "plus") {
                                showingManualActivity = true
                            }
                            .buttonStyle(.borderedProminent)
                            Button("Import FIT file", systemImage: "square.and.arrow.down") {
                                showingImporter = true
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                } else {
                    ForEach(viewModel.activities) { activity in
                        HStack(spacing: 10) {
                            NavigationLink {
                                FitnessActivityDetailView(activityId: activity.id)
                            } label: {
                                FitnessActivityCard(activity: activity)
                            }
                            if activity.sportKey == "strength" {
                                Button {
                                    copyStrengthWorkout(activity)
                                } label: {
                                    Image(systemName: copiedStrengthActivityId == activity.id ? "checkmark" : "doc.on.doc")
                                }
                                .buttonStyle(.bordered)
                                .accessibilityLabel(copiedStrengthActivityId == activity.id ? "Workout copied" : "Copy whole workout")
                            }
                        }
                        .accessibilityIdentifier("fitnessActivityCard-\(activity.id)")
                    }
                }
            }
        }
        .accessibilityIdentifier("fitnessActivityHistory")
        .navigationTitle("Activities")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showingManualActivity = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Log activity")
                Button {
                    showingFilters = true
                } label: {
                    Image(
                        systemName: hasFilters
                            ? "line.3.horizontal.decrease.circle.fill"
                            : "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Filter activities")
                .accessibilityValue(hasFilters ? "Filters applied" : "No filters applied")
                Menu {
                    Button("Import FIT file", systemImage: "square.and.arrow.down") {
                        showingImporter = true
                    }
                    if hasImportActivity {
                        Button("Import status", systemImage: "tray.full") {
                            showingImportStatus = true
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More activity actions")
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [fitType]) { result in
            if case .success(let url) = result { Task { await viewModel.importFIT(url) } }
            if case .failure(let error) = result { viewModel.errorMessage = error.localizedDescription }
        }
        .sheet(isPresented: $showingFilters) {
            FitnessActivityFilterSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $showingManualActivity) {
            FitnessManualActivitySheet(viewModel: viewModel)
        }
        .sheet(isPresented: $showingImportStatus) {
            FitnessFITImportStatusSheet(
                viewModel: viewModel,
                importAnother: {
                    showingImportStatus = false
                    Task { @MainActor in
                        do {
                            try await Task.sleep(nanoseconds: 300_000_000)
                        } catch is CancellationError {
                            return
                        } catch {
                            return
                        }
                        showingImporter = true
                    }
                },
                reviewUnowned: { item in
                    showingImportStatus = false
                    Task { @MainActor in
                        do {
                            try await Task.sleep(nanoseconds: 300_000_000)
                        } catch is CancellationError {
                            return
                        } catch {
                            return
                        }
                        unownedToAdopt = item
                    }
                }
            )
        }
        .confirmationDialog(
            "Import this unassigned FIT file into your private Fitness data?",
            isPresented: Binding(
                get: { unownedToAdopt != nil },
                set: { if !$0 { unownedToAdopt = nil } }
            ),
            presenting: unownedToAdopt
        ) { item in
            Button("Import into my Fitness") {
                Task {
                    await viewModel.adoptUnowned(item)
                    unownedToAdopt = nil
                }
            }
            Button("Cancel", role: .cancel) { unownedToAdopt = nil }
        } message: { item in
            Text("\(item.originalFilename) was shared while HausKlar was locked, so it was not attached to an account.")
        }
        .task { await viewModel.load() }
        .refreshable { await viewModel.load(refresh: true) }
    }

    private var hasFilters: Bool {
        let filter = viewModel.filter
        return filter.sportKey != nil || filter.dateFrom != nil || filter.dateTo != nil
            || filter.phaseId != nil || filter.workoutClassification != nil
            || filter.gearId != nil || filter.status != nil
    }

    private var hasImportActivity: Bool {
        !viewModel.unownedSharedImports.isEmpty
            || !viewModel.sharedImportRecoveryItems.isEmpty
            || !viewModel.pendingImports.isEmpty
    }

    private func copyStrengthWorkout(_ activity: FitnessActivitySummary) {
        Task {
            guard let text=await viewModel.strengthWorkoutExportText(activityId: activity.id) else { return }
            FitnessStrengthTextExport.copy(text)
            copiedStrengthActivityId=activity.id
            HapticManager.success()
        }
    }
}

private struct FitnessFITImportStatusSheet: View {
    @ObservedObject var viewModel: FitnessActivityHistoryViewModel
    @Environment(\.dismiss) private var dismiss
    let importAnother: () -> Void
    let reviewUnowned: (SharedFitnessFITPayload) -> Void

    var body: some View {
        NavigationStack {
            List {
                if viewModel.unownedSharedImports.isEmpty
                    && viewModel.sharedImportRecoveryItems.isEmpty
                    && viewModel.pendingImports.isEmpty
                {
                    ContentUnavailableView(
                        "No recent imports",
                        systemImage: "tray",
                        description: Text("Imported activities will appear in your history.")
                    )
                    Button("Import FIT file", systemImage: "square.and.arrow.down", action: importAnother)
                        .frame(minHeight: 44)
                }
                ForEach(viewModel.unownedSharedImports) { item in
                    Button {
                        reviewUnowned(item)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.originalFilename).foregroundStyle(.primary)
                                Text("Choose which account should receive this activity.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "person.example_35fbacff.circle.badge.questionmark")
                                .foregroundStyle(.orange)
                        }
                    }
                    .frame(minHeight: 44)
                }
                ForEach(viewModel.sharedImportRecoveryItems) { item in
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.originalFilename)
                            Text("This file couldn’t be imported. Share the original again.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                ForEach(viewModel.pendingImports) { item in
                    HStack(spacing: 12) {
                        Image(systemName: FitnessActivityPresentationPolicy.importIcon(item.status))
                            .foregroundStyle(item.status == .error ? Color.red : Color.accentColor)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.originalFilename).lineLimit(2)
                            Text(FitnessActivityPresentationPolicy.importLabel(item))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if item.status == .error && item.retryable {
                            Button("Retry") { Task { await viewModel.retry(item) } }
                                .frame(minWidth: 44, minHeight: 44)
                        } else if item.status == .complete && item.sourceRetained {
                            Button("Done") { Task { await viewModel.dismiss(item) } }
                                .frame(minWidth: 44, minHeight: 44)
                        }
                    }
                }
            }
            .navigationTitle("FIT imports")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Import", systemImage: "plus", action: importAnother)
                }
            }
        }
    }
}

private struct FitnessManualActivitySheet: View {
    @ObservedObject var viewModel: FitnessActivityHistoryViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var sportKey = "running"
    @State private var startedAt = Date()
    @State private var hours = "0"
    @State private var minutes = "30"
    @State private var distanceKm = "5"
    @State private var title = ""
    @State private var classification = ""
    @State private var rpe = ""
    @State private var notes = ""
    @State private var estimateEnergy = true

    private var sports: [FitnessRegisteredSport] {
        let registered = viewModel.registeredSports.filter { $0.key != "strength" }
        if !registered.isEmpty { return registered }
        return [
            .init(key: "running", displayName: "Running", distanceMeaningful: true),
            .init(key: "walking", displayName: "Walking", distanceMeaningful: true),
            .init(key: "cycling", displayName: "Cycling", distanceMeaningful: true),
            .init(key: "hiking", displayName: "Hiking", distanceMeaningful: true),
            .init(key: "other", displayName: "Other activity", distanceMeaningful: false),
        ]
    }

    private var selectedSport: FitnessRegisteredSport {
        sports.first { $0.key == sportKey } ?? sports[0]
    }

    private var durationS: Double {
        Double(Int(hours) ?? 0) * 3_600 + Double(Int(minutes) ?? 0) * 60
    }

    private var distanceM: Double? {
        let clean = distanceKm.replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let value = Double(clean), value >= 0 else { return nil }
        return value * 1_000
    }

    private var met: Double {
        FitnessManualActivityCalculator.met(
            sportKey: sportKey, durationS: durationS, distanceM: distanceM
        )
    }

    private var estimatedEnergy: Double? {
        guard estimateEnergy else { return nil }
        return FitnessManualActivityCalculator.energyKcal(
            sportKey: sportKey, durationS: durationS, distanceM: distanceM,
            weightKg: viewModel.manualActivityDefaults?.latestWeightKg
        )
    }

    private var pace: String? {
        guard let distanceM, distanceM > 0, durationS > 0 else { return nil }
        let seconds = durationS / (distanceM / 1_000)
        return "\(Int(seconds/60)):\(String(format: "%02d",Int(seconds.rounded()) % 60))/km"
    }

    private var valid: Bool {
        durationS > 0 && durationS <= 604_800
            && (distanceKm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || distanceM != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Activity", selection: $sportKey) {
                        ForEach(sports) { Text($0.displayName).tag($0.key) }
                    }
                    DatePicker(
                        "Started", selection: $startedAt,
                        in: ...Date(), displayedComponents: [.date, .hourAndMinute]
                    )
                }

                Section("Time and distance") {
                    HStack(spacing: 16) {
                        TextField("Hours", text: $hours)
                            .keyboardType(.numberPad)
                            .accessibilityLabel("Hours")
                        Text("hours").foregroundStyle(.secondary)
                        TextField("Minutes", text: $minutes)
                            .keyboardType(.numberPad)
                            .accessibilityLabel("Minutes")
                        Text("minutes").foregroundStyle(.secondary)
                    }
                    TextField("Distance in kilometres", text: $distanceKm)
                        .keyboardType(.decimalPad)
                }

                Section {
                    LazyVGrid(
                        columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10
                    ) {
                        manualMetric(
                            "Distance", distanceM.map { String(format: "%.2f km", $0 / 1_000) } ?? "—",
                            icon: "point.topleft.down.to.point.bottomright.curvepath")
                        manualMetric("Time", FitnessDisplay.duration(durationS), icon: "timer")
                        manualMetric(
                            pace == nil ? "Intensity" : "Pace", pace ?? String(format: "%.1f MET", met),
                            icon: "gauge.with.dots.needle.50percent")
                        manualMetric("Calories", estimatedEnergy.map { "≈ \(Int($0)) kcal" } ?? "—", icon: "flame")
                    }
                    .padding(.vertical, 4)
                    Toggle("Estimate calories from my latest weight", isOn: $estimateEnergy)
                } footer: {
                    if let weight = viewModel.manualActivityDefaults?.latestWeightKg {
                        Text(
                            "Uses \(weight,format:.number.precision(.fractionLength(1))) kg and a standard activity-intensity estimate. Garmin sensor data will be more precise."
                        )
                    } else {
                        Text("No canonical weight is available yet. The activity will still save without a calorie figure.")
                    }
                }

                Section("Optional details") {
                    TextField(selectedSport.displayName, text: $title)
                    if sportKey == "running" {
                        Picker("Run type", selection: $classification) {
                            Text("Not set").tag("")
                            ForEach(
                                [
                                    "recovery", "easy", "steady", "long", "tempo", "threshold", "interval", "hill", "race", "time_trial",
                                    "progression", "mixed",
                                ], id: \.self
                            ) {
                                Text($0.replacingOccurrences(of: "_", with: " ").capitalized).tag($0)
                            }
                        }
                    }
                    Picker("Effort", selection: $rpe) {
                        Text("Not set").tag("")
                        ForEach(1...10, id: \.self) { Text("\($0) / 10").tag(String($0)) }
                    }
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(2...6)
                }

                if let error = viewModel.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Log activity")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .interactiveDismissDisabled(viewModel.isSavingManualActivity)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(viewModel.isSavingManualActivity)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            let payload = FitnessManualActivityPayload(
                                id: UUID().uuidString, sportKey: sportKey,
                                title: nonEmpty(title),
                                startedAtUtc: startedAt, localTimezone: TimeZone.current.identifier,
                                durationS: durationS, distanceM: distanceM,
                                sessionRpe: Double(rpe),
                                workoutClassification: nonEmpty(classification),
                                notes: nonEmpty(notes),
                                estimateEnergy: estimateEnergy
                            )
                            if await viewModel.logManualActivity(
                                payload: payload, sportName: selectedSport.displayName
                            ) {
                                dismiss()
                            }
                        }
                    } label: {
                        if viewModel.isSavingManualActivity {
                            ProgressView()
                        } else {
                            Text("Save")
                        }
                    }
                    .disabled(!valid || viewModel.isSavingManualActivity)
                }
            }
            .task {
                viewModel.errorMessage = nil
                await viewModel.loadManualActivityDefaults()
            }
        }
        .presentationDetents([.large])
    }

    private func manualMetric(_ label: String, _ value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(label, systemImage: icon)
                .font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private func nonEmpty(_ value: String) -> String? {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}

private struct FitnessActivityCard: View {
    let activity: FitnessActivitySummary
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: FitnessDisplay.sportIcon(activity.sportKey))
                            .foregroundStyle(.tint)
                        Text(activity.title)
                            .font(.headline)
                        Spacer(minLength: 0)
                        if activity.status == "processing" {
                            ProgressView().controlSize(.small)
                        }
                    }
                    Text(FitnessDisplay.date(activity.startedAtUtc))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

                if hasRoute, !dynamicTypeSize.isAccessibilitySize {
                    FitnessActivityRoutePreview(coordinates: activity.routeCoordinates)
                        .frame(width: 88, height: 72)
                        .accessibilityHidden(true)
                        .accessibilityIdentifier("fitnessActivityCardRoute-\(activity.id)")
                }
            }
            if isRun {
                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    alignment: .leading,
                    spacing: 10
                ) {
                    ForEach(runStats) { stat in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(stat.value)
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                            Text(stat.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
                .accessibilityIdentifier("fitnessActivityCardRunStats-\(activity.id)")
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { cardMetrics }
                    VStack(alignment: .leading, spacing: 6) { cardMetrics }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if activity.importError != nil {
                Label("This activity needs attention.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.primary)
            }
            if let plan = activity.plannedSessionTitle {
                Label("Matched to \(plan)", systemImage: "calendar.badge.checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 4)
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(activity.title)
        .accessibilityValue(cardAccessibilityValue)
    }

    private var isRun: Bool {
        FitnessActivityPresentationPolicy.isRun(activity.sportKey)
    }

    private var hasRoute: Bool {
        isRun && activity.routeCoordinates.count > 1
    }

    private var runDuration: Double? {
        activity.movingDurationS ?? activity.timerDurationS ?? activity.durationS
    }

    private var runStats: [FitnessActivityPrimaryStat] {
        let averageHeartRate = activity.primaryMetrics?.first {
            ["heart_rate.average_bpm", "average_heart_rate_bpm"].contains($0.metricKey)
        }?.valueNumber
        let averagePace = FitnessDisplay.averagePaceSecondsPerKilometre(
            summaryMetrics: activity.primaryMetrics ?? [],
            distanceMetres: activity.distanceM,
            durationSeconds: runDuration
        )
        return [
            activity.distanceM.map {
                FitnessActivityPrimaryStat(label: "Distance", value: FitnessDisplay.distance($0))
            },
            runDuration.map {
                FitnessActivityPrimaryStat(
                    label: activity.movingDurationS == nil ? "Timer time" : "Moving time",
                    value: FitnessDisplay.duration($0)
                )
            },
            averagePace.map {
                FitnessActivityPrimaryStat(
                    label: "Average pace",
                    value: FitnessDisplay.streamValue($0, metric: "pace_s_per_km", unit: "s/km")
                )
            },
            averageHeartRate.map {
                FitnessActivityPrimaryStat(
                    label: "Average heart rate",
                    value: "\(Int($0.rounded())) bpm"
                )
            },
        ].compactMap { $0 }
    }

    @ViewBuilder private var cardMetrics: some View {
        if let strength = activity.strengthSummary {
            Label("\(strength.exerciseCount) exercises", systemImage: "dumbbell")
            Label("\(strength.setCount) sets", systemImage: "list.number")
            if strength.failureSetCount > 0 {
                Label("\(strength.failureSetCount) to failure", systemImage: "flag.checkered")
            }
        }
        if let distance = activity.distanceM {
            Label(
                FitnessDisplay.distance(distance),
                systemImage: "point.topleft.down.to.point.bottomright.curvepath"
            )
        }
        if let duration = activity.durationS {
            Label(FitnessDisplay.duration(duration), systemImage: "timer")
        }
        if let energy = activity.energyKcal {
            Label(
                "\(activity.energyEstimationMethod == nil ? "" : "≈ ")\(Int(energy.rounded())) kcal",
                systemImage: "flame"
            )
        }
        if let classification = activity.workoutClassification {
            Text(classification.replacingOccurrences(of: "_", with: " ").capitalized)
        }
    }

    private var cardAccessibilityValue: String {
        var values = [FitnessDisplay.date(activity.startedAtUtc)]
        if hasRoute {
            values.append("Route recorded")
        }
        if isRun {
            values.append(contentsOf: runStats.map { "\($0.label) \($0.value)" })
        } else {
            if let strength = activity.strengthSummary {
                values.append("\(strength.exerciseCount) exercises")
                values.append("\(strength.setCount) sets")
            }
            if let distance = activity.distanceM {
                values.append(FitnessDisplay.distance(distance))
            }
            if let duration = activity.durationS {
                values.append(FitnessDisplay.duration(duration))
            }
        }
        if !isRun, let energy = activity.energyKcal {
            values.append("\(activity.energyEstimationMethod == nil ? "" : "estimated ")\(Int(energy.rounded())) calories")
        }
        if let classification = activity.workoutClassification {
            values.append(classification.replacingOccurrences(of: "_", with: " ").capitalized)
        }
        if let plan = activity.plannedSessionTitle {
            values.append("Matched to \(plan)")
        }
        if activity.importError != nil {
            values.append("Needs attention")
        }
        return values.joined(separator: ", ")
    }
}

private struct FitnessActivityRoutePreview: View {
    private let projection: FitnessLocalRouteProjection

    init(coordinates: [CLLocationCoordinate2D]) {
        projection = FitnessLocalRouteProjection(
            samples: coordinates.compactMap { FitnessLocalRouteSample(coordinate: $0) }
        )
    }

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            let points = projection.canvasPoints(in: size, padding: 10)
            guard points.count > 1 else { return }
            var route = Path()
            route.move(to: points[0])
            for point in points.dropFirst() {
                route.addLine(to: point)
            }
            context.stroke(
                route,
                with: .color(Color(.systemBackground)),
                style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
            )
            context.stroke(
                route,
                with: .color(Color.accentColor),
                style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
            )
            context.fill(
                Path(ellipseIn: CGRect(x: points[0].x - 4, y: points[0].y - 4, width: 8, height: 8)),
                with: .color(.green)
            )
            if let last = points.last {
                context.fill(
                    Path(ellipseIn: CGRect(x: last.x - 4, y: last.y - 4, width: 8, height: 8)),
                    with: .color(Color.primary)
                )
            }
        }
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.accentColor.opacity(0.16), lineWidth: 1)
        }
    }
}

private struct FitnessActivityFilterSheet: View {
    @ObservedObject var viewModel: FitnessActivityHistoryViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var hasStart = false
    @State private var hasEnd = false
    @State private var start = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var end = Date()

    private let classifications = [
        "", "recovery", "easy", "steady", "long", "tempo", "threshold", "interval", "hill", "race", "time_trial", "progression", "mixed",
        "unclassified",
    ]

    var body: some View {
        NavigationStack {
            Form {
                Picker("Sport", selection: optionalBinding(\.sportKey)) {
                    Text("All sports").tag("")
                    ForEach(FitnessActivityPresentationPolicy.uniqueSports(viewModel.registeredSports)) { sport in
                        Text(sport.displayName).tag(sport.key)
                    }
                }
                Picker("Classification", selection: optionalBinding(\.workoutClassification)) {
                    Text("All classifications").tag("")
                    ForEach(classifications.dropFirst(), id: \.self) {
                        Text($0.replacingOccurrences(of: "_", with: " ").capitalized).tag($0)
                    }
                }
                Picker("Gear", selection: optionalBinding(\.gearId)) {
                    Text("All gear").tag("")
                    ForEach(viewModel.gear) { Text($0.name).tag($0.id) }
                }
                Toggle("Starting date", isOn: $hasStart)
                if hasStart { DatePicker("From", selection: $start, displayedComponents: .date) }
                Toggle("Ending date", isOn: $hasEnd)
                if hasEnd { DatePicker("To", selection: $end, displayedComponents: .date) }
            }
            .navigationTitle("Activity filters")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") {
                        viewModel.filter = FitnessActivityFilter()
                        hasStart = false
                        hasEnd = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        viewModel.filter.dateFrom = hasStart ? FitnessDisplay.day(start) : nil
                        viewModel.filter.dateTo = hasEnd ? FitnessDisplay.day(end) : nil
                        dismiss()
                        Task { await viewModel.load(refresh: true) }
                    }
                }
            }
            .onAppear {
                hasStart = viewModel.filter.dateFrom != nil
                hasEnd = viewModel.filter.dateTo != nil
            }
        }
    }

    private func optionalBinding(_ keyPath: WritableKeyPath<FitnessActivityFilter, String?>) -> Binding<String> {
        Binding(
            get: { viewModel.filter[keyPath: keyPath] ?? "" },
            set: { viewModel.filter[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }
}
